import XCTest
@testable import Relay

// Mirrors RelayTests/self-correction-harness.swift, which is runnable without
// Xcode. Keep the two in sync when adding cases.
final class SelfCorrectionResolverTests: XCTestCase {

    private func assertResolves(_ input: String, to expected: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SelfCorrectionResolver.resolve(input), expected, file: file, line: line)
    }

    // MARK: - Alignment strategies

    func testWordAnchoredReplacement() {
        assertResolves("Change the padding to 20 pixels, actually scratch that, 8 pixels",
                       to: "Change the padding to 8 pixels")
    }

    func testBareNumberSwap() {
        assertResolves("meet at 3 no wait 4", to: "meet at 4")
    }

    func testSpelledNumberSwapWithHesitation() {
        assertResolves("make the font size fourteen, uh no wait, sixteen",
                       to: "make the font size sixteen")
    }

    func testDeterminerAnchor() {
        assertResolves("use the blue button, actually no, the red one",
                       to: "use the red one")
    }

    func testProperNounSwap() {
        assertResolves("send it to John, I mean, Jane", to: "send it to Jane")
    }

    func testArityFallback() {
        assertResolves("turn it left, scratch that, right", to: "turn it right")
    }

    func testClauseReplacement() {
        assertResolves("put it on the left, changed my mind, put it on the right",
                       to: "put it on the right")
    }

    func testMakeThatNumberSwap() {
        assertResolves("order one coffee, make that two", to: "order two coffee")
    }

    // MARK: - Sentence handling

    func testSentenceInitialCueReachesPreviousSentence() {
        assertResolves("Set the padding to 20 pixels. Scratch that. Use 8 pixels.",
                       to: "Set the padding. Use 8 pixels.")
    }

    func testTrailingRetractionDropsLastSentence() {
        assertResolves("Use dark blue for the header. Set the padding to 20. Scratch that.",
                       to: "Use dark blue for the header.")
    }

    func testTrailingRetractionDropsLastClause() {
        assertResolves("I like the header, change padding to 20, scratch that",
                       to: "I like the header")
    }

    func testRestartDiscardsEverythingBefore() {
        assertResolves("Tell them the meeting moved to Thursday. Actually, let me start over. The meeting is cancelled.",
                       to: "The meeting is cancelled.")
    }

    func testMultipleCorrections() {
        assertResolves("set margin to 4, no wait, 8, and color to red, scratch that, blue",
                       to: "set margin to 8, and color to blue")
    }

    func testCueAtStartOfDictation() {
        assertResolves("Scratch that, set padding to 8", to: "set padding to 8")
    }

    // MARK: - Ref markers

    func testRefMarkersSurviveDeletedSpans() {
        assertResolves("use the value from [ref:1] scratch that from [ref:2]",
                       to: "use the value [ref:1] from [ref:2]")
    }

    // MARK: - Safety

    func testWeakCueWithoutAlignmentIsUntouched() {
        assertResolves("This is fine, I mean it works", to: "This is fine, I mean it works")
    }

    func testNoCueIsIdentity() {
        assertResolves("just a normal sentence about padding",
                       to: "just a normal sentence about padding")
    }

    func testNoWaitTimeFalsePositive() {
        assertResolves("there's no wait time at the restaurant",
                       to: "there's no wait time at the restaurant")
    }

    func testActuallyNoOneFalsePositive() {
        assertResolves("actually no one likes it", to: "actually no one likes it")
    }

    func testDontForgetThatFalsePositive() {
        assertResolves("don't forget that the API is rate limited",
                       to: "don't forget that the API is rate limited")
    }

    // MARK: - Cue gate

    func testContainsCue() {
        XCTAssertTrue(SelfCorrectionResolver.containsCue("padding 20, scratch that, 8"))
        XCTAssertTrue(SelfCorrectionResolver.containsCue("no wait, make it 4"))
        XCTAssertFalse(SelfCorrectionResolver.containsCue("a perfectly normal dictation"))
    }
}
