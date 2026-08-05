import Foundation

/// Drives the live "strikethrough, then gone" treatment for self-corrections
/// in the streaming transcript. On each partial, the raw text is resolved
/// (SelfCorrectionResolver, live mode) and word-diffed against itself; words
/// the resolution removed are first published wrapped in strike markers so
/// the UI can render them struck through, and collapse out of the text after
/// a short hold. Each correction animates exactly once — runs are keyed by
/// their position, which is stable because partials grow at the end.
///
/// Display-only: output goes to `displayTranscription` and never touches the
/// raw transcript, which the finish pipeline resolves independently.
@MainActor
final class LiveCorrectionAnimator {
    /// Marks a struck span in display text: strikeStart + words + strikeEnd.
    /// Interlinear-annotation characters — invisible, and never produced by
    /// speech engines.
    static let strikeStart = "\u{FFF9}"
    static let strikeEnd = "\u{FFFB}"

    /// Called when a hold expires and the display should be rebuilt so the
    /// struck words collapse out — there may be no new partial to trigger it.
    var onNeedsRefresh: (() -> Void)?

    private let holdDuration: TimeInterval = 0.85
    /// Run key → when its strike hold expires.
    private var animating: [String: Date] = [:]
    /// Runs whose hold has expired; their words render as removed.
    private var collapsed: Set<String> = []

    func reset() {
        animating.removeAll()
        collapsed.removeAll()
    }

    /// Transform one streaming partial into what the UI should show.
    func process(_ raw: String) -> String {
        guard SelfCorrectionResolver.containsCue(raw) else { return raw }
        let resolved = SelfCorrectionResolver.resolve(raw, mode: .live)
        guard resolved != raw else { return raw }

        let rawTokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        let resolvedTokens = resolved.split(whereSeparator: \.isWhitespace).map(String.init)
        let removed = Self.removedTokenIndices(raw: rawTokens, resolved: resolvedTokens)
        guard !removed.isEmpty else { return resolved }

        let now = Date()
        var struck: Set<Int> = []
        var hidden: Set<Int> = []
        var anyAnimating = false

        for run in runs(of: removed, in: rawTokens) {
            if collapsed.contains(run.key) {
                hidden.formUnion(run.indices)
            } else if let deadline = animating[run.key] {
                if now >= deadline {
                    animating.removeValue(forKey: run.key)
                    collapsed.insert(run.key)
                    hidden.formUnion(run.indices)
                } else {
                    struck.formUnion(run.indices)
                    anyAnimating = true
                }
            } else {
                animating[run.key] = now.addingTimeInterval(holdDuration)
                struck.formUnion(run.indices)
                anyAnimating = true
                scheduleRefresh()
            }
        }

        guard anyAnimating else { return resolved }

        // Annotated view of the raw text: collapsed runs omitted, animating
        // runs wrapped in strike markers, everything else as spoken.
        var parts: [String] = []
        var i = 0
        while i < rawTokens.count {
            if hidden.contains(i) {
                i += 1
            } else if struck.contains(i) {
                var span: [String] = []
                while i < rawTokens.count, struck.contains(i) {
                    span.append(rawTokens[i])
                    i += 1
                }
                parts.append(Self.strikeStart + span.joined(separator: " ") + Self.strikeEnd)
            } else {
                parts.append(rawTokens[i])
                i += 1
            }
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Internals

    private struct Run {
        let key: String
        let indices: [Int]
    }

    private func runs(of removed: [Int], in tokens: [String]) -> [Run] {
        var result: [Run] = []
        var current: [Int] = []
        for index in removed {
            if let last = current.last, index != last + 1 {
                result.append(makeRun(current, tokens: tokens))
                current = []
            }
            current.append(index)
        }
        if !current.isEmpty {
            result.append(makeRun(current, tokens: tokens))
        }
        return result
    }

    private func makeRun(_ indices: [Int], tokens: [String]) -> Run {
        let words = indices.map { tokens[$0] }.joined(separator: " ")
        return Run(key: "\(indices[0]):\(words)", indices: indices)
    }

    private func scheduleRefresh() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(880))
            self?.onNeedsRefresh?()
        }
    }

    /// Indices of raw tokens absent from the resolution (word-level LCS diff).
    private static func removedTokenIndices(raw: [String], resolved: [String]) -> [Int] {
        let n = raw.count, m = resolved.count
        guard n > 0 else { return [] }
        guard m > 0 else { return Array(0..<n) }
        // A dictation long enough to blow this budget just skips the strike
        // phase; correctness never depends on the animation.
        guard n * m <= 400_000 else { return [] }

        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = raw[i] == resolved[j]
                    ? lcs[i + 1][j + 1] + 1
                    : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var removed: [Int] = []
        var i = 0, j = 0
        while i < n, j < m {
            if raw[i] == resolved[j] {
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                removed.append(i); i += 1
            } else {
                j += 1
            }
        }
        removed.append(contentsOf: i..<n)
        return removed
    }
}
