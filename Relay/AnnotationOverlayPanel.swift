import AppKit

/// Manages the full-screen drawing overlay panel. v1 shows a single panel on
/// the active screen. In `.modal` mode it is key and captures all drawing; in
/// `.armed` mode it is click-through until drawing is enabled (Option held).
@MainActor
final class AnnotationOverlayController {
    private weak var manager: AnnotationManager?
    private var panel: AnnotationPanel?

    init(manager: AnnotationManager) {
        self.manager = manager
    }

    func show(clickThrough: Bool) {
        guard let manager, let screen = NSScreen.main else { return }
        let panel = AnnotationPanel(screen: screen, manager: manager)
        panel.present(clickThrough: clickThrough)
        self.panel = panel
    }

    func hide() {
        panel?.dismiss()
        panel = nil
    }

    /// Toggle pass-through. When click-through, pointer events reach apps below;
    /// otherwise the panel captures drawing.
    func setClickThrough(_ clickThrough: Bool) {
        panel?.setClickThrough(clickThrough)
    }

    func clearStrokes() {
        panel?.clearStrokes()
    }
}

/// A borderless, transparent panel spanning one screen.
final class AnnotationPanel: NSPanel {
    private let screenForPanel: NSScreen
    private weak var manager: AnnotationManager?
    private var drawingView: AnnotationDrawingView?

    init(screen: NSScreen, manager: AnnotationManager) {
        self.screenForPanel = screen
        self.manager = manager
        super.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.001) // catch clicks, stay invisible
        hasShadow = false
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false

        let view = AnnotationDrawingView(screen: screen, manager: manager)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
        drawingView = view
    }

    override var canBecomeKey: Bool { true }

    func present(clickThrough: Bool) {
        setFrame(screenForPanel.frame, display: true)
        setClickThrough(clickThrough)
        if clickThrough {
            orderFrontRegardless()
        } else {
            makeKeyAndOrderFront(nil)
            orderFrontRegardless()
        }
    }

    func dismiss() {
        orderOut(nil)
    }

    func setClickThrough(_ clickThrough: Bool) {
        ignoresMouseEvents = clickThrough
        if !clickThrough {
            makeKeyAndOrderFront(nil)
        }
    }

    func clearStrokes() {
        drawingView?.clearStrokes()
    }

    /// Esc cancels the session.
    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated {
            manager?.endSession()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            MainActor.assumeIsolated {
                manager?.endSession()
            }
            return
        }
        super.keyDown(with: event)
    }
}

/// Captures pointer drawing and renders the in-progress strokes. Uses the
/// view's native (bottom-left origin) coordinate space throughout, which maps
/// directly to the panel/screen-local points `toPixelRect` expects.
final class AnnotationDrawingView: NSView {
    private let screenForView: NSScreen
    private weak var manager: AnnotationManager?

    private var completedStrokes: [[CGPoint]] = []
    private var currentStroke: [CGPoint] = []

    init(screen: NSScreen, manager: AnnotationManager) {
        self.screenForView = screen
        self.manager = manager
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false } // bottom-left origin, matches screen coords

    func clearStrokes() {
        completedStrokes = []
        currentStroke = []
        needsDisplay = true
    }

    // MARK: - Drawing input

    override func mouseDown(with event: NSEvent) {
        manager?.beginStroke(on: screenForView)
        currentStroke = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentStroke.append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentStroke.append(convert(event.locationInWindow, from: nil))
        let stroke = currentStroke
        completedStrokes.append(stroke)
        currentStroke = []
        needsDisplay = true
        manager?.completeStroke(stroke, on: screenForView)
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.systemOrange.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for stroke in completedStrokes { strokePath(stroke, in: ctx) }
        strokePath(currentStroke, in: ctx)
    }

    private func strokePath(_ points: [CGPoint], in ctx: CGContext) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: first)
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }
}
