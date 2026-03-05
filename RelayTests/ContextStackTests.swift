import XCTest
@testable import Relay

@MainActor
final class ContextStackTests: XCTestCase {
    func testStartsEmpty() {
        let stack = ContextStack()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertEqual(stack.count, 0)
    }

    func testAddItem() {
        let stack = ContextStack()
        let item = ClipboardItem(contentType: .text, textContent: "hello")
        stack.add(item)
        XCTAssertEqual(stack.count, 1)
        XCTAssertFalse(stack.isEmpty)
    }

    func testRemoveByOffsets() {
        let stack = ContextStack()
        stack.add(ClipboardItem(contentType: .text, textContent: "a"))
        stack.add(ClipboardItem(contentType: .text, textContent: "b"))
        stack.add(ClipboardItem(contentType: .text, textContent: "c"))

        stack.remove(at: IndexSet(integer: 1))
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(stack.items[0].textContent, "a")
        XCTAssertEqual(stack.items[1].textContent, "c")
    }

    func testRemoveByID() {
        let stack = ContextStack()
        let item = ClipboardItem(contentType: .text, textContent: "target")
        stack.add(ClipboardItem(contentType: .text, textContent: "other"))
        stack.add(item)

        stack.remove(id: item.id)
        XCTAssertEqual(stack.count, 1)
        XCTAssertEqual(stack.items[0].textContent, "other")
    }

    func testMoveItems() {
        let stack = ContextStack()
        stack.add(ClipboardItem(contentType: .text, textContent: "a"))
        stack.add(ClipboardItem(contentType: .text, textContent: "b"))
        stack.add(ClipboardItem(contentType: .text, textContent: "c"))

        stack.move(from: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(stack.items[0].textContent, "b")
        XCTAssertEqual(stack.items[1].textContent, "c")
        XCTAssertEqual(stack.items[2].textContent, "a")
    }

    func testClearAll() {
        let stack = ContextStack()
        stack.add(ClipboardItem(contentType: .text, textContent: "a"))
        stack.add(ClipboardItem(contentType: .text, textContent: "b"))

        stack.clear()
        XCTAssertTrue(stack.isEmpty)
    }

    func testRespectsMaxLimit() {
        let stack = ContextStack()
        for i in 0..<25 {
            stack.add(ClipboardItem(contentType: .text, textContent: "item \(i)"))
        }
        XCTAssertEqual(stack.count, ContextStack.maxItems)
        XCTAssertEqual(stack.items.first?.textContent, "item 5")
    }

    func testIsNearLimit() {
        let stack = ContextStack()
        for i in 0..<18 {
            stack.add(ClipboardItem(contentType: .text, textContent: "item \(i)"))
        }
        XCTAssertTrue(stack.isNearLimit)
    }

    func testIsAtLimit() {
        let stack = ContextStack()
        for i in 0..<20 {
            stack.add(ClipboardItem(contentType: .text, textContent: "item \(i)"))
        }
        XCTAssertTrue(stack.isAtLimit)
    }
}
