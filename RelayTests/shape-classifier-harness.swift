// Standalone test harness for ShapeClassifier (XCTest needs Xcode, which this
// machine doesn't have). Run with:
//   cat Relay/Services/ShapeClassifier.swift RelayTests/shape-classifier-harness.swift > /tmp/sc-test.swift && swift /tmp/sc-test.swift
// Exits non-zero on failure.

import CoreGraphics
import Foundation

func arc(center: CGPoint, radius: (Double) -> Double, fromDeg: Double, toDeg: Double, stepDeg: Double = 8) -> [CGPoint] {
    var pts: [CGPoint] = []
    var a = fromDeg
    let step = fromDeg <= toDeg ? stepDeg : -stepDeg
    while (step > 0 && a <= toDeg) || (step < 0 && a >= toDeg) {
        let rad = a * .pi / 180
        let r = radius(a)
        pts.append(CGPoint(x: center.x + r * cos(rad), y: center.y + r * sin(rad)))
        a += step
    }
    return pts
}

func line(_ from: CGPoint, _ to: CGPoint, points: Int = 12) -> [CGPoint] {
    (0..<points).map { i in
        let t = CGFloat(i) / CGFloat(points - 1)
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }
}

var failures = 0
func expect(_ name: String, _ strokes: [[CGPoint]], _ expected: AnnotationShape) {
    let got = ShapeClassifier.classify(strokes: strokes)
    if got == expected {
        print("PASS  \(name): \(got)")
    } else {
        print("FAIL  \(name): expected \(expected), got \(got)")
        failures += 1
    }
}

let c = CGPoint(x: 200, y: 200)

// REPRO — the user's lasso: an overlapping loop drawn as two strokes (pen
// lifted briefly). The short second stroke crosses the loop where the tail
// overlaps the start. Must NOT classify as X.
let lassoMain = arc(center: c, radius: { _ in 100 }, fromDeg: 90, toDeg: 430)
let lassoTail = line(CGPoint(x: c.x + 115, y: c.y + 5), CGPoint(x: c.x + 80, y: c.y - 15), points: 6)
expect("two-stroke lasso (user repro)", [lassoMain, lassoTail], .circle)

// Circle split across two pen-lifts (two half arcs, no crossing) should still
// read as a closed loop, not freeform.
let halfA = arc(center: c, radius: { _ in 100 }, fromDeg: 90, toDeg: 265)
let halfB = arc(center: c, radius: { _ in 100 }, fromDeg: 270, toDeg: 445)
expect("two-stroke circle", [halfA, halfB], .circle)

// True X — two straight crossing strokes must still classify as X.
expect("true X", [
    line(CGPoint(x: 100, y: 100), CGPoint(x: 220, y: 210)),
    line(CGPoint(x: 210, y: 95), CGPoint(x: 95, y: 205)),
], .x)

// Single-stroke closed loop.
expect("single-stroke circle", [arc(center: c, radius: { _ in 90 }, fromDeg: 0, toDeg: 355)], .circle)

// Tiny accidental noise stroke crossing a big loop — noise must not flip it to X.
let bigLoop = arc(center: c, radius: { _ in 100 }, fromDeg: 0, toDeg: 355)
let noise = line(CGPoint(x: 295, y: 195), CGPoint(x: 305, y: 205), points: 3)
expect("circle + tiny noise stroke", [bigLoop, noise], .circle)

// Arrow — shaft with a hard arrowhead kink at the end. Drop the duplicated
// junction point so segments stay non-degenerate, as in a real stroke.
var arrow = line(CGPoint(x: 100, y: 200), CGPoint(x: 260, y: 200), points: 14)
arrow += Array(line(CGPoint(x: 260, y: 200), CGPoint(x: 235, y: 182), points: 5).dropFirst())
expect("arrow", [arrow], .arrow)

// Plain open stroke stays freeform.
expect("straight line", [line(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 140))], .freeform)

/// A hand-like stroke: dense points, a gentle parabolic bow, and small
/// alternating jitter. Visually straight, but per-segment turning noise is huge.
func bowedLine(_ from: CGPoint, _ to: CGPoint, sag: CGFloat, points: Int = 80, jitter: CGFloat = 1.5) -> [CGPoint] {
    let dx = to.x - from.x, dy = to.y - from.y
    let len = hypot(dx, dy)
    let px = -dy / len, py = dx / len
    return (0..<points).map { i in
        let t = CGFloat(i) / CGFloat(points - 1)
        let bow = sag * 4 * t * (1 - t)
        let j: CGFloat = (i % 2 == 0 ? jitter : -jitter)
        return CGPoint(x: from.x + dx * t + px * (bow + j), y: from.y + dy * t + py * (bow + j))
    }
}

// REPRO — hand-drawn X: long, slightly bowed, dense legs must still read as X.
expect("hand-drawn X (long bowed legs)", [
    bowedLine(CGPoint(x: 100, y: 100), CGPoint(x: 800, y: 750), sag: 35),
    bowedLine(CGPoint(x: 780, y: 90), CGPoint(x: 90, y: 760), sag: -30),
], .x)

// REPRO — arrow drawn as two strokes: straight shaft, then a V head at the tip.
let shaft = line(CGPoint(x: 400, y: 900), CGPoint(x: 395, y: 100), points: 40)
var vHead = line(CGPoint(x: 320, y: 220), CGPoint(x: 395, y: 100), points: 10)
vHead += Array(line(CGPoint(x: 395, y: 100), CGPoint(x: 470, y: 230), points: 10).dropFirst())
expect("two-stroke arrow (shaft + V head)", [shaft, vHead], .arrow)

// Same arrow with the head drawn before the shaft.
expect("two-stroke arrow (head first)", [vHead, shaft], .arrow)

// Single-stroke arrow where the head was drawn first (kink near the start).
var headFirstArrow = Array(vHead.dropLast(3))
headFirstArrow += Array(line(headFirstArrow.last!, CGPoint(x: 430, y: 900), points: 30).dropFirst())
expect("single-stroke arrow (head first)", [headFirstArrow], .arrow)

// Arrows point in many directions — build shaft + V head for an arbitrary tip.
func arrowStrokes(tail: CGPoint, tip: CGPoint, spread: CGFloat = 0.45, splitHead: Bool = false) -> [[CGPoint]] {
    let dx = tip.x - tail.x, dy = tip.y - tail.y
    let len = hypot(dx, dy)
    let ux = dx / len, uy = dy / len
    let headLen = len * 0.25
    func headEnd(spread: CGFloat) -> CGPoint {
        // Rotate the reversed shaft direction by ±spread radians.
        let bx = -ux * cos(spread) + uy * sin(spread)
        let by = -ux * sin(spread) - uy * cos(spread)
        return CGPoint(x: tip.x + bx * headLen, y: tip.y + by * headLen)
    }
    let shaft = line(tail, tip, points: 40)
    let legA = line(headEnd(spread: spread), tip, points: 8)
    let legB = line(tip, headEnd(spread: -spread), points: 8)
    if splitHead {
        return [shaft, legA, legB]
    }
    return [shaft, legA + Array(legB.dropFirst())]
}
expect("two-stroke arrow pointing left", arrowStrokes(tail: CGPoint(x: 700, y: 400), tip: CGPoint(x: 150, y: 390)), .arrow)
expect("two-stroke arrow pointing down-right", arrowStrokes(tail: CGPoint(x: 120, y: 100), tip: CGPoint(x: 600, y: 550)), .arrow)
expect("two-stroke arrow pointing down", arrowStrokes(tail: CGPoint(x: 300, y: 100), tip: CGPoint(x: 310, y: 650)), .arrow)

// REPRO — wide arrowhead: interior angle near 90°, drawn carefully (no sharp
// per-segment kink anywhere). Must still read as an arrow.
expect("two-stroke arrow with wide V head", arrowStrokes(tail: CGPoint(x: 300, y: 800), tip: CGPoint(x: 310, y: 100), spread: 0.8), .arrow)

// Arrow drawn as three strokes: shaft, then each head leg separately.
expect("three-stroke arrow (split head)", arrowStrokes(tail: CGPoint(x: 200, y: 700), tip: CGPoint(x: 500, y: 150), splitHead: true), .arrow)

// Same three-stroke arrow plus an accidental noise flick elsewhere.
var noisyArrow = arrowStrokes(tail: CGPoint(x: 200, y: 700), tip: CGPoint(x: 500, y: 150), splitHead: true)
noisyArrow.append(line(CGPoint(x: 640, y: 660), CGPoint(x: 655, y: 672), points: 3))
expect("three-stroke arrow + noise flick", noisyArrow, .arrow)

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll passed")
