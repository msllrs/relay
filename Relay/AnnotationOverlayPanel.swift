import AppKit

/// Manages the full-screen drawing overlay panel(s). Phase 3 ships a single
/// modal panel on the active screen that captures all drawing directly.
@MainActor
final class AnnotationOverlayController {
    private weak var manager: AnnotationManager?
    private var panel: AnnotationPanel?

    init(manager: AnnotationManager) {
        self.manager = manager
    }

    func show() {
        guard let manager, let screen = NSScreen.main else { return }
        let panel = AnnotationPanel(screen: screen, manager: manager)
        panel.present()
        self.panel = panel
    }

    func hide() {
        panel?.dismiss()
        panel = nil
    }
}

/// A borderless, transparent panel spanning one screen. In the modal Phase-3
/// flow it becomes key and its content view captures drawing directly.
final class AnnotationPanel: NSPanel {
    private let screenForPanel: NSScreen
    private weak var manager: AnnotationManager?

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
        ignoresMouseEvents = false // modal: capture all drawing

        let view = AnnotationDrawingView(screen: screen, manager: manager)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        view.autoresizingMask = [.width, .height]
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    func present() {
        setFrame(screenForPanel.frame, display: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    func dismiss() {
        orderOut(nil)
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
