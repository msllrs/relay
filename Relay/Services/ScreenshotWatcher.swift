import Foundation

/// Watches Spotlight for newly created screenshots (kMDItemIsScreenCapture)
/// while a dictation session is active, so screenshots taken mid-recording
/// land in the stack without the user needing to know that ⌃ sends a capture
/// to the clipboard. Metadata-based so it works with any save location,
/// locale, or filename pattern.
@MainActor
final class ScreenshotWatcher {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var sessionStart = Date.distantPast
    private var seenPaths = Set<String>()

    var onScreenshot: ((URL) -> Void)?

    /// Where screenshots can land: the system's configured save location plus
    /// the Desktop default. Resolved at each start so location changes apply.
    private static var screenshotLocations: [URL] {
        var dirs = Set<URL>()
        if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            dirs.insert(desktop.standardizedFileURL)
        }
        if let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (custom as NSString).expandingTildeInPath
            dirs.insert(URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL)
        }
        // CleanShot intercepts the system screenshot shortcuts and saves to
        // its own media directory — include it when installed.
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let cleanshot = appSupport.appendingPathComponent("CleanShot/media", isDirectory: true)
            if FileManager.default.fileExists(atPath: cleanshot.path) {
                dirs.insert(cleanshot.standardizedFileURL)
            }
        }
        return Array(dirs)
    }

    func start() {
        guard query == nil else { return }
        sessionStart = Date()
        seenPaths.removeAll()

        let scopes = Self.screenshotLocations
        // Touch each scope directory so macOS raises its Files-and-Folders
        // prompt on first use — Spotlight silently filters results from
        // folders the app can't read (Desktop is TCC-protected), so without
        // the grant the query simply never matches.
        for dir in scopes {
            _ = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        }

        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        // Narrow scopes — a home-wide query's live-update phase re-evaluates
        // every file event under ~ (Library churn included) and pegs the CPU
        // for the whole recording session.
        query.searchScopes = scopes
        query.notificationBatchingInterval = 0.5

        // Only DidUpdate additions matter — the initial gathering result is
        // every screenshot on disk, which we must not ingest.
        observer = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] notification in
            // Extract plain values before hopping isolation — NSMetadataItem
            // is not Sendable.
            let added = notification.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let captures: [(path: String, created: Date?)] = added.compactMap { item in
                guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                return (path, item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date)
            }
            MainActor.assumeIsolated {
                self?.handle(captures: captures)
            }
        }

        query.start()
        self.query = query
    }

    func stop() {
        query?.stop()
        query = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    private func handle(captures: [(path: String, created: Date?)]) {
        for capture in captures {
            guard !seenPaths.contains(capture.path) else { continue }
            // Spotlight update batches can include re-indexed old captures —
            // only ingest files created during this recording session.
            if let created = capture.created, created < sessionStart {
                continue
            }
            seenPaths.insert(capture.path)
            onScreenshot?(URL(fileURLWithPath: capture.path))
        }
    }
}
