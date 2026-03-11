import Foundation

enum ContentType: String, CaseIterable, Identifiable, Codable {
    case code
    case json
    case markdown
    case terminal
    case url
    case error
    case diff
    case agentation
    case text
    case image
    case file
    case folder
    case voiceNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .code: "Code"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .terminal: "Terminal"
        case .url: "URL"
        case .error: "Error"
        case .diff: "Diff"
        case .agentation: "Agentation"
        case .text: "Text"
        case .image: "Image"
        case .file: "File"
        case .folder: "Folder"
        case .voiceNote: "Voice Note"
        }
    }

    var icon: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .json: "curlybraces"
        case .markdown: "text.document"
        case .terminal: "terminal"
        case .url: "link"
        case .error: "exclamationmark.triangle"
        case .diff: "plus.forwardslash.minus"
        case .agentation: "bubble.left.and.text.bubble.right"
        case .text: "doc.text"
        case .image: "photo"
        case .file: "doc"
        case .folder: "doc"
        case .voiceNote: "mic.fill"
        }
    }

    /// Tag name used in prompt XML output
    var xmlTag: String {
        switch self {
        case .voiceNote: "voice_note"
        default: rawValue
        }
    }
}
