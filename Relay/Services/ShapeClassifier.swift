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
        // An arrow points FROM somewhere TO somewhere — give generous context
        // around both ends (especially the tip) so the destination is in frame.
        case .arrow:    bbox.insetBy(dx: -max(60, bbox.width * 0.4), dy: -max(60, bbox.height * 0.4))
        case .freeform: bbox.insetBy(dx: -8, dy: -8)
        }
    }
}

/// Heuristic gesture classifier — no ML, mirrors `ContentClassifier`'s priority-chain style.
/// Input is one or more strokes (one per pen-down→pen-up); an X is the only multi-stroke gesture.
enum ShapeClassifier {
    static func classify(strokes: [[CGPoint]]) -> AnnotationShape {
        var nonEmpty = strokes.filter { $0.count >= 2 }

        // Noise filter — with multiple strokes, drop tiny accidental taps/flicks
        // (bbox diagonal < 15% of the largest stroke's) so they can't flip the result.
        if nonEmpty.count > 1 {
            let diags = nonEmpty.map { stroke -> Double in
                let b = boundingBox(stroke)
                return hypot(b.width, b.height)
            }
            if let maxDiag = diags.max(), maxDiag > 0 {
                nonEmpty = zip(nonEmpty, diags).filter { $0.1 >= maxDiag * 0.15 }.map { $0.0 }
            }
        }

        let allPoints = nonEmpty.flatMap { $0 }
        guard allPoints.count >= 3 else { return .freeform }

        // X — two near-straight strokes crossing near their middles. Requiring
        // near-straight legs keeps a lifted-pen loop (an arc crossing its own
        // tail) from reading as a delete mark; requiring a central crossing
        // keeps an arrow's head leg (which meets the shaft at its tip) from
        // reading as one either.
        if nonEmpty.count >= 2 {
            if isNearStraight(nonEmpty[0]), isNearStraight(nonEmpty[1]),
               hasCentralCrossing(nonEmpty[0], nonEmpty[1]) {
                return .x
            }
        }

        // Arrow across pen-lifts — a near-straight shaft plus a separate head
        // stroke near one of its ends. Checked before the circle fallbacks
        // because a V head concatenated onto a shaft can read as a closed loop.
        if nonEmpty.count >= 2 {
            let lengths = nonEmpty.map { pathLength($0) }
            let shaftIndex = lengths.indices.max(by: { lengths[$0] < lengths[$1] })!
            let shaft = nonEmpty[shaftIndex]
            if isNearStraight(shaft) {
                let shaftStart = shaft.first!, shaftEnd = shaft.last!
                let shaftChord = distance(shaftStart, shaftEnd)
                let near = max(40.0, shaftChord * 0.3)
                let heads = nonEmpty.indices.filter { $0 != shaftIndex }.map { nonEmpty[$0] }

                // V head — a stroke bending at an apex (the arrow tip) placed
                // at a shaft end. The vertex test catches wide, smoothly-drawn
                // Vs that never make a sharp per-segment kink; the kink scan
                // stays as a fallback for scribbled heads.
                for head in heads {
                    if let apex = vApex(head) {
                        if min(distance(apex, shaftStart), distance(apex, shaftEnd)) < near {
                            return .arrow
                        }
                    } else if hasSharpKink(head, from: 1, to: head.count - 1),
                              min(minDistance(head, to: shaftStart), minDistance(head, to: shaftEnd)) < near {
                        return .arrow
                    }
                }

                // Split head — any two straight ticks meeting at the same shaft tip.
                let straightHeads = heads.filter { isNearStraight($0) }
                if straightHeads.count >= 2 {
                    for tip in [shaftStart, shaftEnd] {
                        let touching = straightHeads.filter { head in
                            min(distance(head.first!, tip), distance(head.last!, tip)) < near
                        }
                        if touching.count >= 2 { return .arrow }
                    }
                }
            }
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

        // Circle across pen-lifts — a loop drawn as 2+ strokes closes as one
        // combined path even though no single stroke does. The junction jump
        // between strokes is small when the user really drew one loop, so
        // turning on the concatenated path stays honest. Circle only; arrow
        // and freeform stay longest-stroke based.
        if nonEmpty.count >= 2 {
            let combinedBBox = boundingBox(allPoints)
            let combinedDiag = hypot(combinedBBox.width, combinedBBox.height)
            if combinedDiag > 1 {
                let combinedGap = hypot(allPoints.last!.x - allPoints.first!.x,
                                        allPoints.last!.y - allPoints.first!.y)
                if combinedGap < combinedDiag * 0.25, totalTurning(allPoints) > 5.0 {
                    return .circle
                }
            }
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

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(b.x - a.x, b.y - a.y))
    }

    /// Total drawn length of a stroke (sum of segment lengths).
    private static func pathLength(_ pts: [CGPoint]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var length = 0.0
        for i in 1..<pts.count {
            length += distance(pts[i - 1], pts[i])
        }
        return length
    }

    /// Minimum distance from any point of the stroke to `target`.
    private static func minDistance(_ pts: [CGPoint], to target: CGPoint) -> Double {
        pts.reduce(.infinity) { min($0, distance($1, target)) }
    }

    /// True when the stroke is nearly a straight segment: its endpoints span
    /// most of its drawn length and no point bows far off the start→end chord.
    /// Chord deviation (not cumulative turning) so dense hand strokes with tiny
    /// per-segment jitter still read as straight — a bowed X leg deviates ~5%
    /// of its chord and passes; a quarter-arc of a loop deviates ~21% and fails.
    private static func isNearStraight(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return false }
        let length = pathLength(pts)
        let chord = distance(first, last)
        guard length > 0.0001, chord > 0.0001, chord / length > 0.7 else { return false }
        // Max perpendicular distance of any point from the start→end line.
        var maxDeviation = 0.0
        for p in pts {
            let cross = Double((last.x - first.x) * (p.y - first.y) - (last.y - first.y) * (p.x - first.x))
            maxDeviation = max(maxDeviation, abs(cross) / chord)
        }
        return maxDeviation < chord * 0.15
    }

    /// The apex of a V-shaped stroke, or nil when the stroke isn't a V. The
    /// apex is the point farthest (perpendicular) from the endpoint chord; a V
    /// requires it to bow well off the chord, both halves to be near-straight
    /// legs, and the interior angle at the apex to be under ~130°. Catches
    /// wide, cleanly-drawn arrowheads that never make a sharp per-segment kink.
    private static func vApex(_ pts: [CGPoint]) -> CGPoint? {
        guard pts.count >= 3, let first = pts.first, let last = pts.last else { return nil }
        let chord = distance(first, last)
        guard chord > 0.0001 else { return nil }
        var apexIndex = 0
        var maxDeviation = 0.0
        for (i, p) in pts.enumerated() {
            let cross = Double((last.x - first.x) * (p.y - first.y) - (last.y - first.y) * (p.x - first.x))
            let deviation = abs(cross) / chord
            if deviation > maxDeviation { maxDeviation = deviation; apexIndex = i }
        }
        // Straight strokes never qualify (isNearStraight caps deviation at 15%).
        guard maxDeviation > max(12, chord * 0.25),
              apexIndex > 0, apexIndex < pts.count - 1 else { return nil }
        let apex = pts[apexIndex]
        guard isNearStraight(Array(pts[0...apexIndex])),
              isNearStraight(Array(pts[apexIndex...])) else { return nil }
        // Interior angle at the apex between the two legs.
        let ax = Double(first.x - apex.x), ay = Double(first.y - apex.y)
        let bx = Double(last.x - apex.x), by = Double(last.y - apex.y)
        let la = hypot(ax, ay), lb = hypot(bx, by)
        guard la > 0.0001, lb > 0.0001 else { return nil }
        let angle = acos(max(-1, min(1, (ax * bx + ay * by) / (la * lb))))
        return angle < 2.3 ? apex : nil
    }

    /// True when the stroke makes a sharp angular reversal near either end —
    /// the signature of an arrowhead, whether the head was drawn after the
    /// shaft (kink in the tail) or before it (kink near the start).
    private static func hasArrowheadKink(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 5 else { return false }
        let headEnd = Int(Double(pts.count) * 0.4)
        let tailStart = Int(Double(pts.count) * 0.6)
        return hasSharpKink(pts, from: 1, to: headEnd)
            || hasSharpKink(pts, from: tailStart, to: pts.count - 1)
    }

    /// Scans interior points in `from..<to` for a hard kink between adjacent
    /// segments (> ~110° direction change).
    private static func hasSharpKink(_ pts: [CGPoint], from: Int, to: Int) -> Bool {
        guard pts.count >= 3 else { return false }
        let lower = max(1, from)
        let upper = min(pts.count - 1, to)
        guard lower < upper else { return false }
        for i in lower..<upper {
            let a = CGPoint(x: pts[i].x - pts[i - 1].x, y: pts[i].y - pts[i - 1].y)
            let b = CGPoint(x: pts[i + 1].x - pts[i].x, y: pts[i + 1].y - pts[i].y)
            let la = hypot(a.x, a.y), lb = hypot(b.x, b.y)
            guard la > 0.0001, lb > 0.0001 else { continue }
            let dot = Double(a.x * b.x + a.y * b.y) / Double(la * lb)
            let angle = acos(max(-1, min(1, dot)))
            // > ~110° change = a hard kink, characteristic of an arrowhead.
            if angle > 1.9 { return true }
        }
        return false
    }

    /// True if strokes `a` and `b` cross away from their endpoints: the
    /// crossing must sit > 20% of each stroke's chord length from both of that
    /// stroke's endpoints. X legs cross centrally; an arrow's head stroke
    /// meets the shaft at its tip and is rejected here.
    private static func hasCentralCrossing(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
        guard a.count >= 2, b.count >= 2 else { return false }
        func isCentral(_ pt: CGPoint, in stroke: [CGPoint]) -> Bool {
            let margin = distance(stroke.first!, stroke.last!) * 0.2
            return distance(pt, stroke.first!) > margin && distance(pt, stroke.last!) > margin
        }
        for i in 0..<(a.count - 1) {
            for j in 0..<(b.count - 1) {
                if let pt = segmentIntersection(a[i], a[i + 1], b[j], b[j + 1]),
                   isCentral(pt, in: a), isCentral(pt, in: b) {
                    return true
                }
            }
        }
        return false
    }

    /// The intersection point of segments p1–p2 and p3–p4, or nil if they
    /// don't cross.
    private static func segmentIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> CGPoint? {
        let d1 = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        let d2 = CGPoint(x: p4.x - p3.x, y: p4.y - p3.y)
        let denom = Double(d1.x * d2.y - d1.y * d2.x)
        guard abs(denom) > 0.0001 else { return nil } // Parallel or degenerate.
        let t = Double((p3.x - p1.x) * d2.y - (p3.y - p1.y) * d2.x) / denom
        let u = Double((p3.x - p1.x) * d1.y - (p3.y - p1.y) * d1.x) / denom
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return CGPoint(x: p1.x + CGFloat(t) * d1.x, y: p1.y + CGFloat(t) * d1.y)
    }
}
