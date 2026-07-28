import XCTest
@testable import Relay

/// Reproduces: capture history was in-memory only and got cleared by every
/// quit or update. Entries written by one store instance must be readable by
/// a fresh instance pointed at the same file — the "app relaunch" case.
final class CaptureHistoryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-history-tests-\(UUID().uuidString)")
            .appendingPathComponent("capture-history.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        super.tearDown()
    }

    func testHistorySurvivesRelaunch() {
        let entries = [
            CaptureHistoryEntry(
                contentType: .voiceNote,
                preview: "a dictated note",
                textContent: "a dictated note",
                imagePath: nil,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                sourceAppName: "Ghostty"
            ),
            CaptureHistoryEntry(
                contentType: .code,
                preview: "func main() {",
                textContent: "func main() {\n}",
                imagePath: nil,
                timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                sourceAppName: nil
            ),
        ]

        CaptureHistoryStore(fileURL: fileURL).save(entries)

        // A fresh store instance simulates the app relaunching.
        let reloaded = CaptureHistoryStore(fileURL: fileURL).load()
        XCTAssertEqual(reloaded, entries)
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertEqual(CaptureHistoryStore(fileURL: fileURL).load(), [])
    }

    func testCorruptFileLoadsEmpty() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data("not json".utf8).write(to: fileURL)
        XCTAssertEqual(CaptureHistoryStore(fileURL: fileURL).load(), [])
    }
}
