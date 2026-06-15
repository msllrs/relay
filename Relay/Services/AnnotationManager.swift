import AppKit
import Combine

/// Orchestrates an annotation session: shows the full-screen overlay, collects
/// drawn strokes, classifies the gesture, captures + crops the screen region,
/// and adds the result to the context stack as an `.annotation` item.
///
/// Two session modes:
/// - `.modal` — standalone hotkey. The overlay is key and captures all drawing
///   directly; one gesture finishes the session (Esc cancels).
/// - `.armed` — auto-armed while recording. The overlay is click-through so the
///   user keeps using their apps; holding Option makes it drawable, and each
///   completed gesture is captured while the session stays armed for the next.
@MainActor
final class AnnotationManager: ObservableObject {
    enum Mode { case modal, armed }

    @Published private(set) var isSessionActive = false
    @Published private(set) var isDrawingEnabled = false

    private weak var appState: AppState?
    private let capture = ScreenCaptureService()
    private var overlay: AnnotationOverlayController?
    private var mode: Mode = .modal

    /// Strokes completed in the current gesture group, in screen-local points
    /// (bottom-left origin) of the screen being annotated.
    private var strokes: [[CGPoint]] = []
    private var finalizeTask: Task<Void, Never>?
    private var activeScreen: NSScreen?

    /// Global Option-key monitor (armed mode only — requires Accessibility).
    private var flagsMonitor: Any?
    private var localFlagsMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Session lifecycle

    /// Begin a standalone modal annotation session (drawable immediately).
    func startSession() {
        startSession(mode: .modal)
    }

    private func startSession(mode: Mode) {
        guard !isSessionActive else { return }
        guard capture.requestPermission() else {
            appState?.needsScreenRecordingPermission = true
            return
        }
        appState?.needsScreenRecordingPermission = false

        self.mode = mode
        capture.invalidateCache()
        strokes = []
        activeScreen = NSScreen.main

        let overlay = AnnotationOverlayController(manager: self)
        overlay.show(clickThrough: mode == .armed)
        self.overlay = overlay
        isSessionActive = true
        isDrawingEnabled = (mode == .modal)

        if mode == .armed { startOptionMonitor() }
    }

    func endSession() {
        guard isSessionActive else { return }
        finalizeTask?.cancel()
        finalizeTask = nil
        stopOptionMonitor()
        overlay?.hide()
        overlay = nil
        strokes = []
        activeScreen = nil
        isSessionActive = false
        isDrawingEnabled = false
    }

    /// Toggle for the standalone hotkey.
    func toggleSession() {
        if isSessionActive { endSession() } else { startSession(mode: .modal) }
    }

    // MARK: - Recording auto-arm (armed mode)

    /// Arm the click-through overlay for the duration of a recording. Requires
    /// Accessibility for the global Option monitor; without it we skip arming
    /// and the user can fall back to the standalone hotkey.
    func armForRecording() {
        guard !isSessionActive else { return }
        guard AXIsProcessTrusted() else { return }
        startSession(mode: .armed)
    }

    func disarmForRecording() {
        guard isSessionActive, mode == .armed else { return }
        endSession()
    }

    // MARK: - Option-gated drawing (armed mode)

    private func startOptionMonitor() {
        stopOptionMonitor()
        let handler: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                self?.setDrawingEnabled(event.modifierFlags.contains(.option))
            }
        }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    private func stopOptionMonitor() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let localFlagsMonitor { NSEvent.removeMonitor(localFlagsMonitor) }
        flagsMonitor = nil
        localFlagsMonitor = nil
    }

    private func setDrawingEnabled(_ enabled: Bool) {
        guard mode == .armed, isSessionActive else { return }
        // Don't drop drawability mid-gesture (e.g. a brief Option release).
        if !enabled && finalizeTask != nil { return }
        guard enabled != isDrawingEnabled else { return }
        isDrawingEnabled = enabled
        overlay?.setClickThrough(!enabled)
    }

    // MARK: - Stroke input (called by the drawing view)

    func beginStroke(on screen: NSScreen) {
        finalizeTask?.cancel()
        finalizeTask = nil
        activeScreen = screen
    }

    /// A stroke finished. Wait briefly for a possible second crossing stroke
    /// (the two-stroke X) before finalizing.
    func completeStroke(_ points: [CGPoint], on screen: NSScreen) {
        guard points.count >= 2 else { return }
        activeScreen = screen
        strokes.append(points)

        finalizeTask?.cancel()
        finalizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await self?.finalize()
        }
    }

    // MARK: - Finalize

    private func finalize() async {
        guard !strokes.isEmpty, let screen = activeScreen else { return }
        let shape = ShapeClassifier.classify(strokes: strokes)
        let bbox = ShapeClassifier.unionBoundingBox(strokes)
        let padded = shape.paddedRect(bbox)
        let pixelRect = ScreenCaptureService.toPixelRect(padded, screen: screen)

        let sessionMode = mode
        strokes = []
        finalizeTask = nil

        // Remove the rendered strokes from the screen before capturing.
        if sessionMode == .modal {
            // Modal: one gesture ends the session.
            endSession()
        } else {
            // Armed: keep the session, just clear the drawing and return to pass-through.
            overlay?.clearStrokes()
            isDrawingEnabled = false
            overlay?.setClickThrough(true)
        }

        // Let the window server flush the overlay change, and bypass the cache.
        capture.invalidateCache()
        try? await Task.sleep(for: .milliseconds(80))
        do {
            let full = try await capture.captureFullScreen(of: screen)
            guard let path = capture.cropAndSave(full, pixelRect: pixelRect) else { return }
            appState?.addItem(ClipboardItem(
                contentType: .annotation,
                textContent: shape.intentLabel,
                imagePath: path
            ))
        } catch {
            NSLog("AnnotationManager.finalize capture failed: \(error)")
        }
    }
}
