import Foundation

/// Persists capture history to Application Support so it survives restarts
/// and updates. Pure file I/O with an injectable location for tests.
struct CaptureHistoryStore {
    let fileURL: URL

    static let `default` = CaptureHistoryStore(
        fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
            .appendingPathComponent("capture-history.json")
    )

    func load() -> [CaptureHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CaptureHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    func save(_ entries: [CaptureHistoryEntry]) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
