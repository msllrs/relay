import AppKit

/// Pasteboard utilities for reliable auto-paste: full-fidelity snapshots,
/// commit waits, and ownership-checked restore.
enum PasteboardHelper {
    /// Ownership marker written alongside auto-paste text. Restore only fires
    /// if the pasteboard still carries this session ID, so we never clobber
    /// something the user copied while the paste was in flight.
    static let sessionMarkerType = NSPasteboard.PasteboardType("com.msllrs.relay.paste-session")

    /// Full-fidelity snapshot: all items × all types as raw data, so RTF,
    /// images, and file URLs survive a round trip (a string-only save/restore
    /// silently destroys them).
    struct Snapshot {
        fileprivate let items: [[NSPasteboard.PasteboardType: Data]]
        var isEmpty: Bool { items.isEmpty }
    }

    static func snapshot() -> Snapshot {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var types: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    types[type] = data
                }
            }
            return types
        }
        return Snapshot(items: items.filter { !$0.isEmpty })
    }

    /// Restore a snapshot. Returns the pasteboard's new change count.
    @discardableResult
    static func restore(_ snapshot: Snapshot) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
        return pasteboard.changeCount
    }

    /// Whether the pasteboard still carries the given session marker.
    static func carriesSession(_ sessionID: String) -> Bool {
        NSPasteboard.general.string(forType: sessionMarkerType) == sessionID
    }

    /// Poll until the pasteboard server has published at least `target`.
    /// Closes the race where a synthesized ⌘V fires before the write is
    /// visible to the target app.
    static func waitForCommit(target: Int, timeout: TimeInterval = 0.15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while NSPasteboard.general.changeCount < target, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
