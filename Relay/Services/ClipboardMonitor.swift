import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private weak var appState: AppState?
    private var timer: Timer?
    private var lastChangeCount: Int

    init(appState: AppState) {
        self.appState = appState
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkClipboard()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Grab current pasteboard content immediately, skipping the change-count guard.
    func captureCurrentClipboard() {
        guard appState != nil else { return }

        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount

        ingestPasteboard(pasteboard)
    }

    private func checkClipboard() {
        guard let appState, appState.isMonitoring else { return }

        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Feedback loop prevention: skip if this change was caused by us
        if let writtenCount = appState.lastWrittenChangeCount, writtenCount == currentCount {
            appState.lastWrittenChangeCount = nil
            return
        }

        ingestPasteboard(pasteboard)
    }

    /// Shared pasteboard processing: read files, images, or text and add to stack.
    private func ingestPasteboard(_ pasteboard: NSPasteboard) {
        guard let appState else { return }

        // Try to read file URLs first (Finder copies include icon TIFF too)
        if let fileURLs = readFileURLs(from: pasteboard) {
            for url in fileURLs {
                let item = ClipboardItem.fromFileURL(url)
                if !isDuplicateOfLastItem(item) {
                    appState.addItem(item)
                }
            }
            return
        }

        // Try to read image
        if let imageData = readImage(from: pasteboard),
           let path = saveImageToTemp(imageData) {
            let item = ClipboardItem(contentType: .image, imagePath: path)
            if !isDuplicateOfLastItem(item) {
                appState.addItem(item)
            }
            return
        }

        // Try to read text
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let contentType = ContentClassifier.classify(text: text)
            let truncatedText = truncateIfNeeded(text)
            let item = ClipboardItem(contentType: contentType, textContent: truncatedText)
            if !isDuplicateOfLastItem(item) {
                appState.addItem(item)
            }
        }
    }

    /// Returns true if the new item's content matches the last item in the stack.
    private func isDuplicateOfLastItem(_ item: ClipboardItem) -> Bool {
        guard let last = appState?.stack.items.last else { return false }

        // Compare text content
        if let newText = item.textContent, let lastText = last.textContent {
            return newText == lastText
        }

        // Compare image file data
        if let newPath = item.imagePath, let lastPath = last.imagePath {
            guard let newData = try? Data(contentsOf: URL(fileURLWithPath: newPath)),
                  let lastData = try? Data(contentsOf: URL(fileURLWithPath: lastPath)) else {
                return false
            }
            return newData == lastData
        }

        return false
    }

    private func readFileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return nil
        }
        let fileURLs = objects.filter { $0.isFileURL }
        return fileURLs.isEmpty ? nil : fileURLs
    }

    private func readImage(from pasteboard: NSPasteboard) -> Data? {
        let imageTypes: [NSPasteboard.PasteboardType] = [.tiff, .png]
        for type in imageTypes {
            if let data = pasteboard.data(forType: type) {
                return data
            }
        }
        return nil
    }

    /// Save image data to a temp file and return the path.
    private func saveImageToTemp(_ data: Data) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = UUID().uuidString + ".png"
        let fileURL = dir.appendingPathComponent(filename)
        do {
            try data.write(to: fileURL)
            return fileURL.path
        } catch {
            return nil
        }
    }

    /// Truncate text items larger than 10KB
    private func truncateIfNeeded(_ text: String) -> String {
        let maxSize = 10_240
        guard text.utf8.count > maxSize else { return text }
        let truncated = String(text.prefix(maxSize))
        return truncated + "\n[truncated]"
    }
}
