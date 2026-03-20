import Foundation

enum TranscriptEnhancement: String, CaseIterable, Identifiable {
    case off
    case clean
    case formatted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Raw"
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

        // Context-aware filler removal (like, right)
        working = removeContextFillers(working)

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

    // MARK: - Context-aware filler removal

    /// Remove filler "like" and "right" using preceding/following context to distinguish
    /// from meaningful uses (e.g. "I like this", "looks like a bug", "the right approach").
    private static func removeContextFillers(_ text: String) -> String {
        var working = text

        // Rule 1: "like" after conjunction — "and like X" → "and X"
        let likeAfterConjunction = /\b(and|but|or|so|then|because)\s+like\s+/
            .ignoresCase()
        working = working.replacing(likeAfterConjunction) { match in
            String(match.output.1) + " "
        }

        // Rule 2: Sentence/clause-initial "like" before pronoun/determiner
        // Matches start-of-string or after sentence boundary
        let likeInitial = /(?:^|[.!?]\s+)like\s+(?=(?:I|we|he|she|it|they|you|the|this|that|these|those|my|our|his|her|its|their|your|a|an|some|every|each)\b)/
            .ignoresCase()
        working = working.replacing(likeInitial) { match in
            let full = String(match.output)
            // Keep sentence boundary if present
            if let dotRange = full.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
                let prefix = full[full.startIndex...dotRange.lowerBound]
                return String(prefix) + " "
            }
            return ""
        }

        // Rule 3: "like" before intensifier after copula — "it's like really X" → "it's really X"
        // Only fires after copula forms to avoid removing meaningful "like" (e.g. "I like really good code")
        let likeBeforeIntensifier = /(\'s|\'m|\'re|was|were|is|are|am|been)\s+like\s+(really|very|totally|just|super|pretty|absolutely|completely|extremely)\b/
            .ignoresCase()
        working = working.replacing(likeBeforeIntensifier) { match in
            String(match.output.1) + " " + String(match.output.2)
        }

        // Rule 4: "like" before "not" after copula — "it's like not working" → "it's not working"
        let likeBeforeNot = /(\'s|\'m|\'re|was|were|is|are|am|been)\s+like\s+(not)\b/
            .ignoresCase()
        working = working.replacing(likeBeforeNot) { match in
            String(match.output.1) + " " + String(match.output.2)
        }

        // Rule 5: Filler "right" — after conjunction + before pronoun/determiner (very narrow)
        let fillerRight = /\b(and|but|or|so|then|because)\s+right\s+(?=(?:I|we|he|she|it|they|you|the|this|that|these|those|my|our|his|her|its|their|your|a|an)\b)/
            .ignoresCase()
        working = working.replacing(fillerRight) { match in
            String(match.output.1) + " "
        }

        // Rule 6: Sentence-initial "right" before pronoun/determiner
        let rightInitial = /(?:^|[.!?]\s+)right\s+(?=(?:I|we|he|she|it|they|you|the|this|that|these|those|my|our|his|her|its|their|your|a|an)\b)/
            .ignoresCase()
        working = working.replacing(rightInitial) { match in
            let full = String(match.output)
            if let dotRange = full.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?")) {
                let prefix = full[full.startIndex...dotRange.lowerBound]
                return String(prefix) + " "
            }
            return ""
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
