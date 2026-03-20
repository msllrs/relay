import XCTest
@testable import Relay

final class TranscriptEnhancerTests: XCTestCase {

    // MARK: - Off level

    func testOffReturnsOriginalText() {
        let input = "um so basically I think we should, like, refactor this"
        XCTAssertEqual(TranscriptEnhancer.enhance(input, level: .off), input)
    }

    // MARK: - Clean level

    func testCleanRemovesSimpleFillers() {
        let input = "um I think uh we should do this"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "I think we should do this")
    }

    func testCleanRemovesPhraseFillers() {
        let input = "I think you know we should sort of refactor this"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "I think we should refactor this")
    }

    func testCleanRemovesLikeHedge() {
        let input = "we should, like, refactor this"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "we should, refactor this")
    }

    func testCleanRemovesSentenceInitialSo() {
        let input = "so I think we should do this"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "I think we should do this")
    }

    func testCleanRemovesSentenceInitialWell() {
        let input = "well I think we should do this"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "I think we should do this")
    }

    func testCleanPreservesMeaningfulLike() {
        // "like" not between commas should be preserved
        let input = "I like this approach"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "I like this approach")
    }

    func testCleanPreservesRefMarkers() {
        let input = "um check [ref:1] and uh also [ref:2] for context"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertTrue(result.contains("[ref:1]"))
        XCTAssertTrue(result.contains("[ref:2]"))
        XCTAssertFalse(result.contains("um"))
        XCTAssertFalse(result.contains("uh"))
    }

    func testCleanEmptyText() {
        XCTAssertEqual(TranscriptEnhancer.enhance("", level: .clean), "")
    }

    func testCleanAllFillerText() {
        let input = "um uh hmm"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "")
    }

    func testCleanRemovesBasicallyActuallyLiterally() {
        let input = "it basically works and is actually literally fine"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "it works and is fine")
    }

    func testCleanRemovesIMean() {
        let input = "I mean the code is fine"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertEqual(result, "the code is fine")
    }

    // MARK: - Context-aware filler "like"

    func testCleanRemovesLikeAfterConjunction() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("and like I think so", level: .clean),
            "and I think so")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("but like the code is broken", level: .clean),
            "but the code is broken")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("or like we could refactor", level: .clean),
            "or we could refactor")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("then like it started working", level: .clean),
            "then it started working")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("because like the API changed", level: .clean),
            "because the API changed")
    }

    func testCleanRemovesSentenceInitialLike() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("like I was trying to fix it", level: .clean),
            "I was trying to fix it")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("like the whole thing broke", level: .clean),
            "the whole thing broke")
    }

    func testCleanRemovesLikeBeforeIntensifier() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("it's like really broken", level: .clean),
            "it's really broken")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("that was like totally wrong", level: .clean),
            "that was totally wrong")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("it's like just a small fix", level: .clean),
            "it's just a small fix")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("it's like very slow", level: .clean),
            "it's very slow")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("it was like super easy", level: .clean),
            "it was super easy")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("it's like pretty obvious", level: .clean),
            "it's pretty obvious")
    }

    func testCleanRemovesLikeBeforeNot() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("it's like not working", level: .clean),
            "it's not working")
    }

    func testCleanPreservesMeaningfulLikeWithVerb() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("I like this approach", level: .clean),
            "I like this approach")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("looks like a bug", level: .clean),
            "looks like a bug")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("feels like the right fix", level: .clean),
            "feels like the right fix")
    }

    // MARK: - Context-aware filler "right"

    func testCleanRemovesFillerRight() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("so right the thing is broken", level: .clean),
            "the thing is broken")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("and right I was thinking", level: .clean),
            "and I was thinking")
    }

    func testCleanPreservesMeaningfulRight() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance("the right approach", level: .clean),
            "the right approach")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("that's right", level: .clean),
            "that's right")
        XCTAssertEqual(
            TranscriptEnhancer.enhance("right there", level: .clean),
            "right there")
    }

    // MARK: - Multiple context fillers

    func testCleanRemovesMultipleContextFillers() {
        XCTAssertEqual(
            TranscriptEnhancer.enhance(
                "so like I was trying and like it broke but like not really",
                level: .clean),
            "I was trying and it broke but not really")
    }

    func testCleanContextFillersWithRefMarkers() {
        let input = "and like check [ref:1] but like it's like not working"
        let result = TranscriptEnhancer.enhance(input, level: .clean)
        XCTAssertTrue(result.contains("[ref:1]"))
        XCTAssertFalse(result.contains("like"))
    }

    // MARK: - Formatted level

    func testFormattedCapitalizesFirstWord() {
        let input = "the code needs refactoring"
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        XCTAssertTrue(result.hasPrefix("The"))
    }

    func testFormattedCapitalizesAfterPeriod() {
        let input = "first point. second point"
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        XCTAssertTrue(result.contains(". Second"))
    }

    func testFormattedAddsTrailingPeriod() {
        let input = "the code needs refactoring"
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        XCTAssertTrue(result.hasSuffix("."))
    }

    func testFormattedDoesNotDoubleTrailingPeriod() {
        let input = "the code needs refactoring."
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        XCTAssertTrue(result.hasSuffix("."))
        XCTAssertFalse(result.hasSuffix(".."))
    }

    func testFormattedDeduplicatesAdjacentWords() {
        let input = "the the code is is fine"
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        XCTAssertTrue(result.contains("the code"))
        XCTAssertTrue(result.contains("is fine"))
        XCTAssertFalse(result.contains("the the"))
        XCTAssertFalse(result.contains("is is"))
    }

    func testFormattedPreservesRefMarkers() {
        let input = "um check [ref:1] and uh fix [ref:2] please"
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        XCTAssertTrue(result.contains("[ref:1]"))
        XCTAssertTrue(result.contains("[ref:2]"))
    }

    func testFormattedCombinesCleanAndFormat() {
        let input = "um so basically the the code needs refactoring"
        let result = TranscriptEnhancer.enhance(input, level: .formatted)
        // Should remove fillers, deduplicate, capitalize, and add period
        XCTAssertFalse(result.contains("um"))
        XCTAssertFalse(result.contains("basically"))
        XCTAssertFalse(result.contains("the the"))
        XCTAssertTrue(result.first?.isUppercase == true)
        XCTAssertTrue(result.hasSuffix("."))
    }
}
