import XCTest
import CoreGraphics
@testable import Relay

final class ShapeClassifierTests: XCTestCase {

    // MARK: - Stroke fixtures

    private func circleStroke(center: CGPoint = CGPoint(x: 100, y: 100),
                              radius: Double = 50,
                              turns: Double = 1.0) -> [CGPoint] {
        let steps = Int(36 * turns)
        return (0...steps).map { i -> CGPoint in
            let t = Double(i) / 36.0 * 2 * .pi
            return CGPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
        }
    }

    private func arrowStroke() -> [CGPoint] {
        var p = (0...10).map { CGPoint(x: Double($0) * 15, y: 50) } // shaft pointing right
        // Arrowhead: a sharp reversal at the tip.
        p.append(CGPoint(x: 130, y: 65))
        p.append(CGPoint(x: 150, y: 50))
        p.append(CGPoint(x: 130, y: 35))
        return p
    }

    private func straightLine() -> [CGPoint] {
        (0...10).map { CGPoint(x: Double($0) * 15, y: 50) }
    }

    // MARK: - Classification

    func testClassifiesCircle() {
        XCTAssertEqual(ShapeClassifier.classify(strokes: [circleStroke()]), .circle)
    }

    func testClassifiesX() {
        let down = (0...10).map { CGPoint(x: Double($0) * 10, y: Double($0) * 10) }
        let up = (0...10).map { CGPoint(x: Double($0) * 10, y: 100 - Double($0) * 10) }
        XCTAssertEqual(ShapeClassifier.classify(strokes: [down, up]), .x)
    }

    func testClassifiesArrow() {
        XCTAssertEqual(ShapeClassifier.classify(strokes: [arrowStroke()]), .arrow)
    }

    func testStraightLineIsFreeform() {
        XCTAssertEqual(ShapeClassifier.classify(strokes: [straightLine()]), .freeform)
    }

    func testOpenArcIsNotCircle() {
        // 270° arc whose ends don't meet — we should not over-claim "circled".
        XCTAssertNotEqual(ShapeClassifier.classify(strokes: [circleStroke(turns: 0.75)]), .circle)
    }

    func testEmptyAndTinyAreFreeform() {
        XCTAssertEqual(ShapeClassifier.classify(strokes: []), .freeform)
        XCTAssertEqual(ShapeClassifier.classify(strokes: [[CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]]), .freeform)
    }

    // MARK: - Padding policy

    func testCirclePaddingIsTight() {
        let bbox = CGRect(x: 50, y: 50, width: 100, height: 100)
        XCTAssertEqual(AnnotationShape.circle.paddedRect(bbox), CGRect(x: 40, y: 40, width: 120, height: 120))
    }

    func testXPaddingAddsContext() {
        let bbox = CGRect(x: 50, y: 50, width: 100, height: 100)
        let padded = AnnotationShape.x.paddedRect(bbox)
        XCTAssertTrue(padded.width > bbox.width)
        XCTAssertTrue(padded.height > bbox.height)
    }

    func testArrowPaddingSpansStroke() {
        let bbox = CGRect(x: 50, y: 50, width: 100, height: 20)
        XCTAssertEqual(AnnotationShape.arrow.paddedRect(bbox), bbox)
    }

    // MARK: - Union bounding box

    func testUnionBoundingBoxSpansAllStrokes() {
        let a = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        let b = [CGPoint(x: 20, y: 5), CGPoint(x: 30, y: 40)]
        XCTAssertEqual(ShapeClassifier.unionBoundingBox([a, b]), CGRect(x: 0, y: 0, width: 30, height: 40))
    }
}
