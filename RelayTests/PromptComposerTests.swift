import XCTest
@testable import Relay

final class PromptComposerTests: XCTestCase {
    func testComposesWithTaskAndText() {
        let items = [
            ClipboardItem(contentType: .code, textContent: "func hello() { }")
        ]
        let result = PromptComposer.compose(task: "Review this code", items: items)

        XCTAssertTrue(result.contains("<task>Review this code</task>"))
        XCTAssertTrue(result.contains("<context>"))
        XCTAssertTrue(result.contains("<item type=\"code\" index=\"1\">"))
        XCTAssertTrue(result.contains("func hello() { }"))
        XCTAssertTrue(result.contains("</item>"))
        XCTAssertTrue(result.contains("</context>"))
    }

    func testComposesWithEmptyTask() {
        let items = [
            ClipboardItem(contentType: .text, textContent: "some text")
        ]
        let result = PromptComposer.compose(task: "", items: items)

        XCTAssertFalse(result.contains("<task>"))
        XCTAssertTrue(result.contains("<context>"))
    }

    func testComposesWithMultipleItems() {
        let items = [
            ClipboardItem(contentType: .code, textContent: "let x = 1"),
            ClipboardItem(contentType: .terminal, textContent: "$ swift build"),
            ClipboardItem(contentType: .voiceNote, textContent: "Fix the build error"),
        ]
        let result = PromptComposer.compose(task: "Debug", items: items)

        XCTAssertTrue(result.contains("<item type=\"code\" index=\"1\">"))
        XCTAssertTrue(result.contains("<item type=\"terminal\" index=\"2\">"))
        XCTAssertTrue(result.contains("<item type=\"voice_note\" index=\"3\">"))
    }

    func testComposesEmpty() {
        let result = PromptComposer.compose(task: "", items: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testWhitespaceTaskTreatedAsEmpty() {
        let result = PromptComposer.compose(task: "   \n  ", items: [])
        XCTAssertFalse(result.contains("<task>"))
    }

    func testVoiceNoteXMLTag() {
        let items = [
            ClipboardItem(contentType: .voiceNote, textContent: "Please explain this")
        ]
        let result = PromptComposer.compose(task: "", items: items)
        XCTAssertTrue(result.contains("type=\"voice_note\""))
    }
}
