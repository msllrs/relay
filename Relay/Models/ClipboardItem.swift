import Foundation
import AppKit

struct ClipboardItem: Identifiable, Equatable {
    let id: UUID
    let contentType: ContentType
    var textContent: String?
    let imagePath: String?
    let timestamp: Date

    init(
        id: UUID = UUID(),
        contentType: ContentType,
        textContent: String? = nil,
        imagePath: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.contentType = contentType
        self.textContent = textContent
        self.imagePath = imagePath
        self.timestamp = timestamp
    }

    /// Short preview string for display in the list
    var preview: String {
        if let text = textContent {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
            if firstLine.count > 80 {
                return String(firstLine.prefix(80)) + "..."
            }
            return firstLine
        }
        if imagePath != nil {
            return "Image"
        }
        return ""
    }

    /// Thumbnail NSImage for image items
    var thumbnail: NSImage? {
        guard let path = imagePath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - File URL factory

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp", "heic", "heif"
    ]

    /// Create a ClipboardItem from a file URL, classifying images, folders, and other files.
    static func fromFileURL(_ url: URL) -> ClipboardItem {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            return ClipboardItem(contentType: .image, imagePath: url.path)
        }
        if url.hasDirectoryPath {
            return ClipboardItem(contentType: .folder, textContent: url.path)
        }
        return ClipboardItem(contentType: .file, textContent: url.path)
    }
}
