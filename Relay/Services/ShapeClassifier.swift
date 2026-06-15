import CoreGraphics
import Foundation

/// The recognized gesture for a screen annotation, plus the semantic intent it
/// conveys to the downstream LLM and the crop padding it implies.
enum AnnotationShape: String {
    case circle
    case arrow
    case x
    case freeform

    /// Human-readable intent attached to the captured crop as the item's text.
    var intentLabel: String {
        switch self {
        case .circle:   "User circled this region — focus here / this is the relevant element."
        case .x:        "User marked this region with an X — delete or remove this."
        case .arrow:    "User drew an arrow here — indicates a direction, a move, or a relationship."
        case .freeform: "User highlighted this region."
        }
    }

    /// Expand the stroke bounding box to the crop region for this shape.
    /// Circle: tight + small pad. X: generous context. Arrow: spans the stroke.
    func paddedRect(_ bbox: CGRect) -> CGRect {
        switch self {
        case .circle:   bbox.insetBy(dx: -10, dy: -10)
        case .x:        bbox.insetBy(dx: -bbox.width * 0.2, dy: -bbox.height * 0.2)
        case .arrow:    bbox
        case .freeform: bbox.insetBy(dx: -8, dy: -8)
        }
    }
}

/// Heuristic gesture classifier — no ML, mirrors `ContentClassifier`'s priority-chain style.
/// Input is one or more strokes (one per pen-down→pen-up); an X is the only multi-stroke gesture.
enum ShapeClassifier {
    static func classify(strokes: [[CGPoint]]) -> AnnotationShape {
        let nonEmpty = strokes.filter { $0.count >= 2 }
        let allPoints = nonEmpty.flatMap { $0 }
        guard allPoints.count >= 3 else { return .freeform }

        // X — two strokes that cross, or a single stroke that crosses itself sharply.
        if nonEmpty.count >= 2 {
            if strokesCross(nonEmpty[0], nonEmpty[1]) { return .x }
        }

        // Single-stroke shapes use the longest stroke.
        let pts = nonEmpty.max(by: { $0.count < $1.count }) ?? allPoints
        let bbox = boundingBox(pts)
        let diag = hypot(bbox.width, bbox.height)
        guard diag > 1 else { return .freeform }

        let start = pts.first!
        let end = pts.last!
        let closeGap = hypot(end.x - start.x, end.y - start.y)
        let turning = totalTurning(pts)

        // Circle — closed loop (ends meet) with a large cumulative turn (~290°+).
        if closeGap < diag * 0.25, turning > 5.0 {
            return .circle
        }

        // Arrow — open stroke with a sharp direction reversal near the tail (arrowhead).
        if hasArrowheadKink(pts) {
            return .arrow
        }

        return .freeform
    }

    // MARK: - Geometry helpers

    static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Union bounding box across all strokes (used for the crop region).
    static func unionBoundingBox(_ strokes: [[CGPoint]]) -> CGRect {
        let all = strokes.flatMap { $0 }
        return boundingBox(all)
    }

    /// Sum of absolute turning angles between consecutive segments (radians).
    /// A full circle ≈ 2π; we threshold below that to tolerate imperfect loops.
    private static func totalTurning(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 3 else { return 0 }
        var total = 0.0
        for i in 1..<(pts.count - 1) {
            let a = CGPoint(x: pts[i].x - pts[i - 1].x, y: pts[i].y - pts[i - 1].y)
            let b = CGPoint(x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y)
            let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
            guard la > 0.0001, lb > 0.0001 else { continue }
            // Signed angle between successive segments, accumulated as magnitude.
            let cross = Double(a.x * b.y - a.y * b.x)
            let dot = Double(a.x * b.x + a.y * b.y)
            total += abs(atan2(cross, dot))
        }
        return total
    }

    /// True when the stroke makes a sharp angular reversal concentrated in its
    /// last ~25% — the signature of an arrowhead drawn at the end of a shaft.
    private static func hasArrowheadKink(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 5 else { return false }
        let tailStart = Int(Double(pts.count) * 0.6)
        var sharpTurn = false
        for i in max(1, tailStart)..<(pts.count - 1) {
            let a = CGPoint(x: pts[i].x - pts[i - 1].x, y: pts[i].y - pts[i - 1].y)
            let b = CGPoint(x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y)
            let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
            guard la > 0.0001, lb > 0.0001 else { continue }
            let dot = Double(a.x * b.x + a.y * b.y) / Double(la * lb)
            let angle = acos(max(-1, min(1, dot)))
            // > ~110° change = a hard kink, characteristic of an arrowhead.
            if angle > 1.9 { sharpTurn = true }
        }
        return sharpTurn
    }

    /// True if any segment of stroke `a` intersects any segment of stroke `b`.
    private static func strokesCross(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard a.count >= 2, b.count >= 2 else { return false }
        for i in 0..<(a.count - 1) {
            for j in 0..<(b.count - 1) {
                if segmentsIntersect(a[i], a[i + 1], b[j], b[j + 1]) { return true }
            }
        }
        return false
    }

    private static func segmentsIntersect(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> Bool {
        func orientation(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Int {
            let val = (b.y - a.y) * (c.x - b.x) - (b.x - a.x) * (c.y - b.y)
            if abs(val) < 0.0001 { return 0 }
            return val > 0 ? 1 : 2
        }
        let o1 = orientation(p1, p2, p3)
        let o2 = orientation(p1, p2, p4)
        let o3 = orientation(p3, p4, p1)
        let o4 = orientation(p3, p4, p2)
        return o1 != o2 && o3 != o4
    }
}
