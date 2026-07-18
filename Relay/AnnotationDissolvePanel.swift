import AppKit
import CoreImage
import QuartzCore

/// Plays the "smoky dissolve" exit for a committed annotation: the drawn mark
/// melts into one soft cloud — the stroke fattens under a growing blur, swells,
/// drifts upward, and lets go late. (Tuned like the lapse project's dissolve:
/// blur carries the effect and the ink stays one cohesive mass.)
///
/// The effect runs on its own panel, separate from the drawing overlay, so the
/// drawing panel can close instantly (keyboard focus returns to the user's app
/// right away). The panel is click-through, never key, and — critically —
/// `sharingType = .none`, which excludes it from ScreenCaptureKit output, so
/// the screenshot taken ~80ms after commit never contains the smoke.
final class AnnotationDissolvePanel: NSPanel {

    /// Show the dissolve for `strokes` (screen-local, bottom-left origin) and
    /// clean the panel up when it finishes. Honors Reduce Motion by skipping
    /// straight to nothing (the strokes already vanished with the overlay).
    static func play(strokes: [[CGPoint]], on screen: NSScreen) {
        guard !strokes.isEmpty else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return }

        let panel = AnnotationDissolvePanel(screen: screen)
        let duration = panel.runDissolve(strokes: strokes)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration + 0.1))
            panel.orderOut(nil)
            panel.close()
        }
    }

    private init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        sharingType = .none // invisible to screen capture
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.layerUsesCoreImageFilters = true // animated CIGaussianBlur on sublayers
        contentView = content
    }

    override var canBecomeKey: Bool { false }

    // MARK: - Effect

    /// Build and start all animations; returns the total effect duration.
    private func runDissolve(strokes: [[CGPoint]]) -> TimeInterval {
        guard let host = contentView?.layer else { return 0 }
        orderFrontRegardless()

        let meltDuration = 0.6
        addMeltLayer(strokes, to: host, beginTime: CACurrentMediaTime(), duration: meltDuration)
        return meltDuration
    }

    /// The melt: the whole mark as ONE layer whose stroke fattens while a
    /// gaussian blur ramps up — the ink becomes a cloud instead of diluting —
    /// swelling ~5%, drifting up, and fading on a hold-early/drop-late curve.
    private func addMeltLayer(_ strokes: [[CGPoint]], to host: CALayer, beginTime: CFTimeInterval, duration: TimeInterval) {
        // Generous inset: fattened + blurred ink lands well outside the path.
        let bbox = ShapeClassifier.unionBoundingBox(strokes).insetBy(dx: -48, dy: -48)

        let layer = CAShapeLayer()
        layer.frame = bbox
        let path = CGMutablePath()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: CGPoint(x: first.x - bbox.minX, y: first.y - bbox.minY))
            for p in stroke.dropFirst() {
                path.addLine(to: CGPoint(x: p.x - bbox.minX, y: p.y - bbox.minY))
            }
        }
        layer.path = path
        layer.strokeColor = NSColor.systemOrange.cgColor
        layer.fillColor = nil
        layer.lineWidth = 3
        layer.lineCap = .round
        layer.lineJoin = .round

        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setDefaults()
            blur.setValue(0, forKey: kCIInputRadiusKey)
            blur.name = "meltBlur"
            layer.filters = [blur]
        }
        host.addSublayer(layer)

        // Blur carries the effect: the shape melts into one cloud.
        let blurUp = CABasicAnimation(keyPath: "filters.meltBlur.inputRadius")
        blurUp.fromValue = 0
        blurUp.toValue = 16

        // Fatten the stroke under the blur so the mass stays visible instead
        // of diluting away in the first frames.
        let fatten = CABasicAnimation(keyPath: "lineWidth")
        fatten.toValue = 13

        // ≈ 1 − p²: stay present through the melt, then let go.
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.75, 0]
        fade.keyTimes = [0, 0.5, 1]

        let rise = CABasicAnimation(keyPath: "position.y")
        rise.byValue = 10 // bottom-left origin: smoke drifts up

        let swell = CABasicAnimation(keyPath: "transform.scale")
        swell.toValue = 1.05

        run([blurUp, fatten, fade, rise, swell], on: layer, beginTime: beginTime, duration: duration)
    }

    private func run(_ animations: [CAAnimation], on layer: CALayer, beginTime: CFTimeInterval, duration: TimeInterval) {
        let group = CAAnimationGroup()
        group.animations = animations
        group.beginTime = beginTime
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut) // ease-out melt
        group.fillMode = .both // hold start during stagger delay, end state after
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "dissolve")
    }
}
