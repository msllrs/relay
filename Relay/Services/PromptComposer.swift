import Foundation

enum PromptComposer {
    /// Compose a structured XML prompt from the task intent and context stack items.
    static func compose(task: String, items: [ClipboardItem]) -> String {
        var parts: [String] = []

        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTask.isEmpty {
            parts.append("<task>\(trimmedTask)</task>")
        }

        if !items.isEmpty {
            var contextParts: [String] = []
            for (index, item) in items.enumerated() {
                let content = contentString(for: item)
                contextParts.append("<item type=\"\(item.contentType.xmlTag)\" index=\"\(index + 1)\">\n\(content)\n</item>")
            }
            parts.append("<context>\n\(contextParts.joined(separator: "\n\n"))\n</context>")
        }

        return parts.joined(separator: "\n\n")
    }

    private static func contentString(for item: ClipboardItem) -> String {
        if let text = item.textContent {
            return text
        }

        if let path = item.imagePath {
            return "[image: \(path)]"
        }

        return ""
    }
}
