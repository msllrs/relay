import Foundation

enum PromptFormat: String, CaseIterable, Identifiable {
    case xml
    case markdown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .xml: "XML"
        case .markdown: "Markdown"
        }
    }
}

enum VoiceNotePosition: String, CaseIterable, Identifiable {
    case top, bottom, inline

    var id: String { rawValue }

    var label: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .inline: "Inline"
        }
    }
}

enum PromptComposer {
    static func compose(items: [ClipboardItem], format: PromptFormat = .xml, voiceNotePosition: VoiceNotePosition = .top) -> String {
        let ordered = reorder(items: items, position: voiceNotePosition)
        switch format {
        case .xml: return composeXML(items: ordered)
        case .markdown: return composeMarkdown(items: ordered)
        }
    }

    private static func reorder(items: [ClipboardItem], position: VoiceNotePosition) -> [ClipboardItem] {
        switch position {
        case .inline:
            return items
        case .top:
            let voice = items.filter { $0.contentType == .voiceNote }
            let rest = items.filter { $0.contentType != .voiceNote }
            return voice + rest
        case .bottom:
            let voice = items.filter { $0.contentType == .voiceNote }
            let rest = items.filter { $0.contentType != .voiceNote }
            return rest + voice
        }
    }

    // MARK: - XML

    private static func composeXML(items: [ClipboardItem]) -> String {
        var parts: [String] = []

        if !items.isEmpty {
            var contextParts: [String] = []
            var nonVoiceIndex = 0
            for item in items {
                let content = contentString(for: item)
                if item.contentType == .voiceNote {
                    contextParts.append("<item type=\"\(item.contentType.xmlTag)\">\n\(content)\n</item>")
                } else {
                    nonVoiceIndex += 1
                    contextParts.append("<item type=\"\(item.contentType.xmlTag)\" index=\"\(nonVoiceIndex)\">\n\(content)\n</item>")
                }
            }
            parts.append("<context>\n\(contextParts.joined(separator: "\n\n"))\n</context>")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Markdown

    private static func composeMarkdown(items: [ClipboardItem]) -> String {
        var parts: [String] = []

        if !items.isEmpty {
            var contextParts: [String] = []
            var nonVoiceIndex = 0
            for item in items {
                let content = contentString(for: item)
                if item.contentType == .voiceNote {
                    let header = "### \(item.contentType.label)"
                    contextParts.append("\(header)\n\(markdownContent(for: item, raw: content))")
                } else {
                    nonVoiceIndex += 1
                    let header = "### \(nonVoiceIndex). \(item.contentType.label)"
                    contextParts.append("\(header)\n\(markdownContent(for: item, raw: content))")
                }
            }
            parts.append("## Context\n\(contextParts.joined(separator: "\n\n"))")
        }

        return parts.joined(separator: "\n\n")
    }

    private static func markdownContent(for item: ClipboardItem, raw: String) -> String {
        switch item.contentType {
        case .code, .json, .terminal, .error, .diff:
            return "```\n\(raw)\n```"
        case .image:
            return "![image](\(raw.replacingOccurrences(of: "[image: ", with: "").replacingOccurrences(of: "]", with: "")))"
        case .file, .folder:
            return "`\(raw)`"
        case .url:
            return raw
        case .agentation:
            return raw
        case .text, .voiceNote:
            return raw
        }
    }

    // MARK: - Shared

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
