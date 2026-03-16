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
