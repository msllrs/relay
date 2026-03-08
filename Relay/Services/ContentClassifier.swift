import Foundation

enum ContentClassifier {
    /// Classify text content by inspecting its structure.
    /// Priority chain: JSON > URL > Annotation > Diff > Error > Terminal > Code > Text
    static func classify(text: String) -> ContentType {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }

        // 1. JSON
        if isJSON(trimmed) { return .json }

        // 2. URL (single line with scheme)
        if isURL(trimmed) { return .url }

        // 3. Agentation page annotations
        if isAnnotation(trimmed) { return .agentation }

        // 4. Diff / patch
        if isDiff(trimmed) { return .diff }

        // 5. Error / stack trace
        if isError(trimmed) { return .error }

        // 5. Terminal output
        if isTerminal(trimmed) { return .terminal }

        // 6. Code
        if isCode(trimmed) { return .code }

        // 7. Fallback
        return .text
    }

    // MARK: - Detection helpers

    private static func isJSON(_ text: String) -> Bool {
        guard let first = text.first, first == "{" || first == "[" else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func isURL(_ text: String) -> Bool {
        // Must be a single line
        guard !text.contains("\n") else { return false }
        guard let url = URL(string: text),
              let scheme = url.scheme,
              ["http", "https", "ftp", "ssh", "file"].contains(scheme.lowercased()),
              url.host != nil else {
            return false
        }
        return true
    }

    private static func isAnnotation(_ text: String) -> Bool {
        // Agentation (agentation.dev) page feedback output
        // Starts with "## Page Feedback:" and contains numbered annotation entries
        guard text.contains("## Page Feedback:") else { return false }
        // Detailed format has "**Feedback:**" fields; compact format has numbered bold-element entries
        if text.contains("**Feedback:**") { return true }
        // Compact: "1. **element**: feedback"
        if text.range(of: #"\d+\. \*\*\w+"#, options: .regularExpression) != nil { return true }
        return false
    }

    private static func isDiff(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var hasHunks = false
        var indicators = 0

        for line in lines {
            if line.hasPrefix("diff --git ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("@@ ") {
                indicators += 1
                if line.hasPrefix("@@ ") { hasHunks = true }
            } else if hasHunks && (line.hasPrefix("+") || line.hasPrefix("-")) {
                indicators += 1
            }
        }
        return indicators >= 2
    }

    private static func isError(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var hits = 0

        for line in lines {
            if line.contains("Error:") || line.contains("Exception") || line.contains("Traceback")
                || line.contains("panic:") || line.contains("fatal error") || line.contains("FAIL")
                || line.contains("error[E") {
                hits += 1
            }
            // JS stack frames: "at something (file:line)"
            if line.range(of: #"at .+\(.+:.+\)"#, options: .regularExpression) != nil {
                hits += 1
            }
            // Python stack frames: File "...", line N
            if line.range(of: #"File \".+\", line"#, options: .regularExpression) != nil {
                hits += 1
            }
        }
        return hits >= 2
    }

    private static func isTerminal(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        let promptLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("$ ") || trimmed.hasPrefix("% ") || trimmed.hasPrefix("> ")
        }
        // At least 1 prompt line, or ANSI escape codes present
        if promptLines.count >= 1 { return true }
        if text.contains("\u{1B}[") { return true }
        return false
    }

    private static func isCode(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)

        // Check for common code keywords
        let codeKeywords = [
            "func ", "def ", "class ", "import ", "from ", "const ", "let ", "var ",
            "if ", "else ", "for ", "while ", "return ", "switch ", "case ",
            "struct ", "enum ", "protocol ", "interface ", "public ", "private ",
            "fn ", "pub ", "mod ", "use ", "#include", "#import", "package ",
            "async ", "await ", "throw ", "try ", "catch ",
        ]

        var keywordHits = 0
        var indentedLines = 0
        var braceLines = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Keyword detection
            for keyword in codeKeywords where trimmed.hasPrefix(keyword) || trimmed.contains(" \(keyword)") {
                keywordHits += 1
                break
            }

            // Indentation patterns (leading spaces/tabs)
            if line.hasPrefix("  ") || line.hasPrefix("\t") {
                indentedLines += 1
            }

            // Braces/brackets
            if trimmed.contains("{") || trimmed.contains("}") {
                braceLines += 1
            }
        }

        let lineCount = max(lines.count, 1)
        let indentRatio = Double(indentedLines) / Double(lineCount)

        // Heuristic: enough signals suggest code
        if keywordHits >= 2 { return true }
        if braceLines >= 2 && indentRatio > 0.3 { return true }
        if keywordHits >= 1 && braceLines >= 1 { return true }

        return false
    }
}
