import Foundation

/// A user-defined removal rule. `pattern` is a raw regex fragment matched with
/// case-insensitive lookaround word boundaries, so "um+" kills "um" and "ummm"
/// but never the "um" inside "circumstance".
struct WordRemovalRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var isEnabled = true
    var pattern = ""
}

/// A user-defined replacement: literal match → literal replacement, applied
/// case-insensitively at word boundaries. Replacements support \n, \t, \r,
/// and \\ escapes so "new paragraph" can map to an actual paragraph break.
struct WordRemappingRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var isEnabled = true
    var match = ""
    var replacement = ""
}

/// Words and phrases the speech engines should be biased toward recognizing
/// (names, jargon, product terms). Parakeet uses FluidAudio's decode-time
/// vocabulary boosting; Whisper gets them as a glossary prompt.
enum VocabularyStore {
    static func load() -> [String] {
        (UserDefaults.standard.stringArray(forKey: "customVocabularyTerms") ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func save(_ terms: [String]) {
        UserDefaults.standard.set(terms, forKey: "customVocabularyTerms")
    }
}

enum WordRules {
    static let defaultRemovals = ["uh+", "um+", "er+", "hm+"].map {
        WordRemovalRule(isEnabled: false, pattern: $0)
    }

    /// Apply removals then remappings, protecting [ref:N] markers throughout.
    static func apply(
        _ text: String,
        removals: [WordRemovalRule],
        remappings: [WordRemappingRule]
    ) -> String {
        let activeRemovals = removals.filter { $0.isEnabled && !$0.pattern.isEmpty }
        let activeRemappings = remappings.filter { $0.isEnabled && !$0.match.isEmpty }
        guard !activeRemovals.isEmpty || !activeRemappings.isEmpty else { return text }

        // Shield ref markers behind sentinels so no rule can touch them.
        let sentinel = "\u{FFFC}"
        var refs: [String] = []
        var working = text
        while let match = working.firstMatch(of: /\[ref:\d+\]/) {
            refs.append(String(working[match.range]))
            working.replaceSubrange(match.range, with: sentinel)
        }

        let beforeRemovals = working
        for rule in activeRemovals {
            let pattern = "(?<!\\w)(?:\(rule.pattern))(?!\\w)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: "")
        }
        if working != beforeRemovals {
            working = cleanup(working)
        }

        for rule in activeRemappings {
            let escaped = NSRegularExpression.escapedPattern(for: rule.match)
            let pattern = "(?<!\\w)\(escaped)(?!\\w)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            // Escape the template so a literal $ in the replacement isn't read
            // as a capture-group reference, then process \n-style escapes.
            let template = NSRegularExpression.escapedTemplate(for: processEscapes(rule.replacement))
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: template)
        }

        for ref in refs {
            if let range = working.range(of: sentinel) {
                working.replaceSubrange(range, with: ref)
            }
        }
        return working
    }

    /// Punctuation/whitespace repair after removals — the difference between
    /// "Um, so, I think" → ", so, I think" (broken) and → "so, I think".
    static func cleanup(_ text: String) -> String {
        let passes: [(String, String)] = [
            ("[ \\t]{2,}", " "),                       // collapse doubled spaces
            ("[ \\t]+([,\\.!?;:])", "$1"),             // space before punctuation
            ("([,\\.!?;:])[ \\t]*\\1+", "$1"),         // doubled punctuation
            ("(?m)^[ \\t]*[,\\.!?;:]+[ \\t]*", ""),    // orphan punctuation opening a line
            ("[ \\t]+\\n", "\n"),                      // trailing line whitespace
            ("\\n[ \\t]+", "\n"),                      // leading line whitespace
        ]
        var working = text
        for (pattern, template) in passes {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(working.startIndex..., in: working)
            working = regex.stringByReplacingMatches(in: working, range: range, withTemplate: template)
        }
        return working.trimmingCharacters(in: .whitespaces)
    }

    /// Support \n, \t, \r, and \\ in replacements. The placeholder keeps
    /// "\\n" as a literal backslash-n instead of a newline.
    private static func processEscapes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\\\", with: "\u{0000}")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\u{0000}", with: "\\")
    }

    // MARK: - Persistence

    static func loadRemovals() -> [WordRemovalRule] {
        guard let data = UserDefaults.standard.data(forKey: "wordRemovalRules"),
              let rules = try? JSONDecoder().decode([WordRemovalRule].self, from: data)
        else { return defaultRemovals }
        return rules
    }

    static func loadRemappings() -> [WordRemappingRule] {
        guard let data = UserDefaults.standard.data(forKey: "wordRemappingRules"),
              let rules = try? JSONDecoder().decode([WordRemappingRule].self, from: data)
        else { return [] }
        return rules
    }

    static func save(removals: [WordRemovalRule]) {
        if let data = try? JSONEncoder().encode(removals) {
            UserDefaults.standard.set(data, forKey: "wordRemovalRules")
        }
    }

    static func save(remappings: [WordRemappingRule]) {
        if let data = try? JSONEncoder().encode(remappings) {
            UserDefaults.standard.set(data, forKey: "wordRemappingRules")
        }
    }
}
