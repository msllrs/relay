import XCTest
@testable import Relay

// Mirrors RelayTests/auto-paste-guard-harness.swift, which is runnable
// without Xcode. Keep the two in sync when adding cases.
final class AutoPasteGuardTests: XCTestCase {

    private func assertDecides(_ focusedElementPID: pid_t?, ownPID: pid_t,
                               _ expected: AutoPasteGuard.Verdict,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(AutoPasteGuard.decide(focusedElementPID: focusedElementPID, ownPID: ownPID),
                       expected, file: file, line: line)
    }

    // The reported bug: focus is inside Relay itself (Settings text field).
    func testFocusInOwnProcessIsBlocked() {
        assertDecides(500, ownPID: 500, .blockSelfTarget)
    }

    // The normal case: focus is in the external target app.
    func testFocusInAnotherProcessProceeds() {
        assertDecides(812, ownPID: 500, .proceed)
    }

    // Focused element unreadable: we can't prove the target isn't us — don't
    // fire a blind ⌘V.
    func testUnknownFocusIsBlocked() {
        assertDecides(nil, ownPID: 500, .blockUnknownTarget)
    }
}
