import Foundation

enum ContentType: String, CaseIterable, Identifiable, Codable {
    case code
    case json
    case terminal
    case url
    case text
    case image
    case voiceNote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .code: "Code"
        case .json: "JSON"
        case .terminal: "Terminal"
        case .url: "URL"
        case .text: "Text"
        case .image: "Image"
        case .voiceNote: "Voice Note"
        }
    }

    var icon: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .json: "curlybraces"
        case .terminal: "terminal"
        case .url: "link"
        case .text: "doc.text"
        case .image: "photo"
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
