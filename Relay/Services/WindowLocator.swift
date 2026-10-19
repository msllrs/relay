import CoreGraphics
import Foundation

/// An on-screen window as reported by the window server. `bounds` is in global
/// CoreGraphics coordinates (top-left origin of the primary display, points).
struct OnScreenWindow: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    let bounds: CGRect
}

/// Finds the app window under a point or a set of drawn strokes, and maps its
/// bounds into a screen's capture pixels. The lookup and coordinate math are
/// pure so they can be tested without a window server (see
/// `RelayTests/window-locator-harness.swift`).
enum WindowLocator {
    /// Windows smaller than this (points, either side) are tooltips, badges, or
    /// invisible helpers — never what the user meant to point at.
    static let minimumSide: CGFloat = 40

    /// On-screen windows front-to-back, as the window server orders them.
    static func onScreenWindows() -> [OnScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0 { return nil }
            return OnScreenWindow(windowID: id, ownerPID: pid, layer: layer, bounds: bounds)
        }
    }

    /// The frontmost normal app window containing `point` (global CG coords).
    /// Skips `excludingPID` (Relay's own overlay and popover), non-zero layers
    /// (menu bar, Dock, floating panels), and tiny windows.
    static func topmostWindow(at point: CGPoint, in windows: [OnScreenWindow], excludingPID: pid_t) -> OnScreenWindow? {
        windows.first { window in
            window.ownerPID != excludingPID
                && window.layer == 0
                && window.bounds.width >= minimumSide
                && window.bounds.height >= minimumSide
                && window.bounds.contains(point)
        }
    }

    /// The window the user drew on: each stroke point votes for the topmost
    /// window under it and the most-voted window wins. Voting (rather than the
    /// bounding-box centre) keeps an arrow that starts in one window and points
    /// into another attached to the window holding most of the mark.
    static func window(forStrokes points: [CGPoint], in windows: [OnScreenWindow], excludingPID: pid_t) -> OnScreenWindow? {
        var votes: [CGWindowID: Int] = [:]
        var firstSeen: [CGWindowID] = []
        for point in points {
            guard let hit = topmostWindow(at: point, in: windows, excludingPID: excludingPID) else { continue }
            if votes[hit.windowID] == nil { firstSeen.append(hit.windowID) }
            votes[hit.windowID, default: 0] += 1
        }
        // Ties go to the window the stroke reached first.
        var winner: CGWindowID?
        for id in firstSeen where winner == nil || votes[id]! > votes[winner!]! {
            winner = id
        }
        return winner.flatMap { id in windows.first { $0.windowID == id } }
    }

    // MARK: - Coordinate conversion

    /// Screen-local point (bottom-left origin, as the annotation overlay records
    /// strokes) → global CG point (top-left origin of the primary display).
    /// `screenFrame` is the screen's AppKit frame; `primaryHeight` is the height
    /// of the primary (menu bar) display.
    static func globalPoint(fromScreenLocal p: CGPoint, screenFrame: CGRect, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: screenFrame.minX + p.x, y: primaryHeight - (screenFrame.minY + p.y))
    }

    /// AppKit global point (bottom-left origin, e.g. `NSEvent.mouseLocation`) →
    /// global CG point.
    static func globalPoint(fromAppKit p: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    /// Window bounds (global CG) → pixel rect within the screen's captured image
    /// (top-left origin), clipped to the screen. Nil if the window isn't on it.
    static func pixelRect(forWindowBounds bounds: CGRect, screenFrame: CGRect, primaryHeight: CGFloat, scale: CGFloat) -> CGRect? {
        // The screen's top edge in global CG coordinates.
        let screenTopCG = primaryHeight - screenFrame.maxY
        let local = CGRect(
            x: bounds.minX - screenFrame.minX,
            y: bounds.minY - screenTopCG,
            width: bounds.width,
            height: bounds.height
        )
        let visible = local.intersection(CGRect(origin: .zero, size: screenFrame.size))
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        return CGRect(
            x: visible.minX * scale,
            y: visible.minY * scale,
            width: visible.width * scale,
            height: visible.height * scale
        ).integral
    }

    /// A ring of points around `center` (screen-local, bottom-left), used to mark
    /// a click or the cursor on a capture with the same renderer as drawn strokes.
    static func ring(around center: CGPoint, radius: CGFloat = 16, segments: Int = 36) -> [CGPoint] {
        (0...segments).map { i in
            let angle = CGFloat(i) / CGFloat(segments) * 2 * .pi
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
    }
}
