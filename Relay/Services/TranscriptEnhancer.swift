import Foundation

enum TranscriptEnhancement: String, CaseIterable, Identifiable {
    case off
    case clean
    case formatted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "None"
        case .clean: "Clean"
        case .formatted: "Formatted"
        }
    }
}

enum TranscriptEnhancer {
    static func enhance(_ text: String, level: TranscriptEnhancement) -> String {
        switch level {
        case .off:
            return text
        case .clean:
            return clean(text)
        case .formatted:
            return format(clean(text))
        }
    }

    // MARK: - Clean

    /// Remove filler words while preserving [ref:N] markers.
    private static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Extract ref markers, replacing with sentinel
        let sentinel = "\u{FFFC}"
        var refs: [String] = []
        var working = text
        let refPattern = /\[ref:\d+\]/
        while let match = working.firstMatch(of: refPattern) {
            refs.append(String(working[match.range]))
            working.replaceSubrange(match.range, with: sentinel)
        }

        // Phrase fillers (must be removed before single-word fillers)
        let phraseFillersPattern = /\b(?:you know|I mean|sort of|kind of)\b/
            .ignoresCase()
        working = working.replacing(phraseFillersPattern, with: "")

        // "like" between commas or as a hedge (", like,")
        let likeHedgePattern = /,\s*like\s*,/
            .ignoresCase()
        working = working.replacing(likeHedgePattern, with: ",")

        // Sentence-initial "so" / "well" (after sentence boundary or start of string)
        let sentenceInitialPattern = /(?:^|[.!?]\s+)(?:so|well)\b\s*/
            .ignoresCase()
        working = working.replacing(sentenceInitialPattern) { match in
            let full = String(match.output)
            // Keep the sentence-ending punctuation + space if present
            if let dotRange = full.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
                let prefix = full[full.startIndex...dotRange.lowerBound]
                return String(prefix) + " "
            }
            return ""
        }

        // Always-remove filler words (word-boundary)
        let alwaysRemovePattern = /\b(?:um|uh|uhh|hmm|basically|actually|literally)\b/
            .ignoresCase()
        working = working.replacing(alwaysRemovePattern, with: "")

        // Collapse multiple spaces
        let multiSpacePattern = /\s{2,}/
        working = working.replacing(multiSpacePattern, with: " ")

        // Clean up space before punctuation that filler removal may leave
        let spacePunctuationPattern = /\s+([,.])/
        working = working.replacing(spacePunctuationPattern) { match in
            String(match.output.1)
        }

        // Collapse repeated commas (e.g. ",," from adjacent filler removals)
        let repeatedCommaPattern = /,(\s*,)+/
        working = working.replacing(repeatedCommaPattern, with: ",")

        working = working.trimmingCharacters(in: .whitespaces)

        // Restore ref markers
        for ref in refs {
            if let range = working.range(of: sentinel) {
                working.replaceSubrange(range, with: ref)
            }
        }

        return working
    }

    // MARK: - Format

    /// Capitalize after sentence boundaries, add trailing period, deduplicate adjacent words,
    /// and normalize punctuation spacing.
    private static func format(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        // Extract ref markers
        let sentinel = "\u{FFFC}"
        var refs: [String] = []
        var working = text
        let refPattern = /\[ref:\d+\]/
        while let match = working.firstMatch(of: refPattern) {
            refs.append(String(working[match.range]))
            working.replaceSubrange(match.range, with: sentinel)
        }

        // Deduplicate adjacent words (case-insensitive)
        let dupPattern = /\b(\w+)(\s+\1\b)+/
            .ignoresCase()
        working = working.replacing(dupPattern) { match in
            String(match.output.1)
        }

        // Capitalize first character
        if let first = working.first, first.isLetter {
            working = first.uppercased() + working.dropFirst()
        }

        // Capitalize after sentence-ending punctuation
        let sentenceCapPattern = /([.!?]\s+)(\p{Ll})/
        working = working.replacing(sentenceCapPattern) { match in
            String(match.output.1) + String(match.output.2).uppercased()
        }

        // Add trailing period if text doesn't end with punctuation
        let trimmed = working.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, !".!?".contains(last) && last != "\u{FFFC}".first {
            // Check if text ends with a sentinel (ref marker at the end)
            let stripped = trimmed.replacingOccurrences(of: sentinel, with: "").trimmingCharacters(in: .whitespaces)
            if let realLast = stripped.last, !".!?".contains(realLast) {
                if trimmed.hasSuffix(sentinel) {
                    working = addTrailingPeriod(trimmed, sentinel: sentinel)
                } else {
                    working = trimmed + "."
                }
            } else {
                working = trimmed
            }
        } else {
            working = trimmed
        }

        // Normalize space before punctuation
        let spacePuncPattern = /\s+([.!?,])/
        working = working.replacing(spacePuncPattern) { match in
            String(match.output.1)
        }

        // Restore ref markers
        for ref in refs {
            if let range = working.range(of: sentinel) {
                working.replaceSubrange(range, with: ref)
            }
        }

        return working
    }

    /// Insert a trailing period before any trailing ref-marker sentinels.
    private static func addTrailingPeriod(_ text: String, sentinel: String) -> String {
        var result = text
        // Walk backward past sentinels and spaces to find insertion point
        var insertionIndex = result.endIndex
        while insertionIndex > result.startIndex {
            let prevIndex = result.index(before: insertionIndex)
            let ch = result[prevIndex]
            if String(ch) == sentinel || ch == " " {
                insertionIndex = prevIndex
            } else {
                break
            }
        }
        if insertionIndex > result.startIndex {
            let before = result[result.index(before: insertionIndex)]
            if !".!?".contains(before) {
                result.insert(".", at: insertionIndex)
            }
        }
        return result
    }
}
