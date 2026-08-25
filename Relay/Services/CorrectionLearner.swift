import ApplicationServices
import Foundation

/// Opt-in accuracy loop: after an auto-paste lands, watch the target field via
/// the Accessibility API and learn from the user's manual corrections. A word
/// the user fixes twice gets added to the vocabulary so the speech engines
/// recognize it next time. Entirely on-device.
@MainActor
final class CorrectionLearner {
    static let shared = CorrectionLearner()

    var isEnabled = false {
        didSet {
            if !isEnabled {
                pendingCheck?.cancel()
                pendingCheck = nil
            }
        }
    }

    /// How long after the paste we look for corrections. One sample keeps the
    /// AX traffic negligible; corrections made later are caught next dictation.
    private let checkDelay: Duration = .seconds(20)
    /// A substitution must be seen this many times before it's learned.
    private let promotionThreshold = 2
    private let countsKey = "correctionCandidateCounts"

    private var pendingCheck: Task<Void, Never>?

    func observePaste(text: String) {
        guard isEnabled, !text.isEmpty, AXIsProcessTrusted() else { return }
        guard let element = Self.focusedTextElement() else { return }

        pendingCheck?.cancel()
        let pastedWords = Self.words(of: text)
        guard pastedWords.count >= 2 else { return }

        pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: self?.checkDelay ?? .seconds(20))
            guard let self, !Task.isCancelled else { return }
            guard let current = Self.value(of: element) else { return }
            self.learn(pasted: pastedWords, current: Self.words(of: current))
        }
    }

    /// Align pasted words against the field's current words and record
    /// single-word substitutions that look like corrections (similar length,
    /// meaningful overlap — not rewrites or deletions).
    private func learn(pasted: [String], current: [String]) {
        guard !current.isEmpty else { return }
        let substitutions = Self.substitutions(from: pasted, to: current)
        guard !substitutions.isEmpty else { return }

        var counts = (UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
        var vocabulary = VocabularyStore.load()
        var vocabularyChanged = false

        for (original, corrected) in substitutions {
            // Only learn real words the engines could produce next time.
            guard corrected.count >= 3,
                  corrected.rangeOfCharacter(from: .letters) != nil,
                  !vocabulary.contains(where: { $0.caseInsensitiveCompare(corrected) == .orderedSame })
            else { continue }

            let key = "\(original.lowercased())→\(corrected)"
            let count = (counts[key] ?? 0) + 1
            counts[key] = count
            if count >= promotionThreshold {
                vocabulary.append(corrected)
                vocabularyChanged = true
                counts.removeValue(forKey: key)
                NSLog("CorrectionLearner: learned '%@' (was transcribed as '%@')", corrected, original)
            }
        }

        UserDefaults.standard.set(counts, forKey: countsKey)
        if vocabularyChanged {
            VocabularyStore.save(vocabulary)
        }
    }

    /// Word-level alignment: walk both sequences with a common-anchor scan and
    /// treat isolated one-for-one differences as substitutions. Conservative on
    /// purpose — heavy edits produce no candidates rather than junk.
    static func substitutions(from old: [String], to new: [String]) -> [(String, String)] {
        var result: [(String, String)] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i].caseInsensitiveCompare(new[j]) == .orderedSame {
                i += 1
                j += 1
                continue
            }
            // A substitution only counts when the very next words re-align.
            let nextMatches = i + 1 < old.count && j + 1 < new.count
                && old[i + 1].caseInsensitiveCompare(new[j + 1]) == .orderedSame
            let lastPair = i == old.count - 1 && j == new.count - 1
            if nextMatches || lastPair {
                let a = old[i], b = new[j]
                if a.caseInsensitiveCompare(b) != .orderedSame, similar(a, b) {
                    result.append((a, b))
                }
                i += 1
                j += 1
            } else {
                // Sequences diverged (insertions, deletions, rewrites) — bail
                // out rather than guess.
                break
            }
        }
        return result
    }

    /// Corrections are usually respellings of what was heard — require the
    /// pair to be in the same size neighborhood so "meeting"→"Merriweather"
    /// doesn't count but "jira"→"Jira" and "cloud"→"Claude" do.
    private static func similar(_ a: String, _ b: String) -> Bool {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return false }
        return abs(a.count - b.count) <= max(2, maxLen / 3)
    }

    private static func words(of text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    // MARK: - AX helpers

    private static func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String else {
            return nil
        }
        return value
    }
}
