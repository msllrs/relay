import XCTest
@testable import Relay

// Mirrors RelayTests/dictation-finalize-harness.swift, which is runnable
// without Xcode. Keep the two in sync when adding cases.
final class DictationFinalizePolicyTests: XCTestCase {

    private func assertDecides(_ context: DictationFinalizePolicy.Context,
                               _ expected: DictationFinalizePolicy.Action,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(DictationFinalizePolicy.decide(context), expected, file: file, line: line)
    }

    // The ordinary case: nothing changed while the transcript finalized.
    func testUninterruptedFinishDelivers() {
        assertDecides(.init(generationAtStop: 1, generationNow: 1,
                            isRecording: false, placeholderStillInStack: true),
                      .deliver)
    }

    // The reported bug: user started a new recording before the previous
    // session's (slow) finalize landed. Delivering would re-freeze old text
    // into the display and auto-copy a half-finished new session.
    func testNewRecordingStartedAccumulates() {
        assertDecides(.init(generationAtStop: 1, generationNow: 2,
                            isRecording: true, placeholderStillInStack: true),
                      .accumulate)
    }

    // User started AND stopped a newer recording while this one finalized;
    // the newer session's own finalize owns delivery for both.
    func testNewerSessionFinishedAccumulates() {
        assertDecides(.init(generationAtStop: 1, generationNow: 2,
                            isRecording: false, placeholderStillInStack: true),
                      .accumulate)
    }

    // The stack was cleared (Clear Stack, or clear-on-copy from a newer
    // session) while finalizing: resurrecting the text would be the "previous
    // recording wasn't cleared" bug. Capture history is the safety net.
    func testClearedWhileFinalizingIsHistoryOnly() {
        assertDecides(.init(generationAtStop: 1, generationNow: 2,
                            isRecording: false, placeholderStillInStack: false),
                      .historyOnly)
    }

    func testClearedMidNewRecordingIsHistoryOnly() {
        assertDecides(.init(generationAtStop: 1, generationNow: 3,
                            isRecording: true, placeholderStillInStack: false),
                      .historyOnly)
    }

    // Defensive: recording flag alone forces accumulate even if the
    // generation looks current — delivery must never race a live session.
    func testLiveRecordingAlwaysBlocksDelivery() {
        assertDecides(.init(generationAtStop: 2, generationNow: 2,
                            isRecording: true, placeholderStillInStack: true),
                      .accumulate)
    }
}
