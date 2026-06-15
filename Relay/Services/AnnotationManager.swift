import AppKit
import Combine

/// Orchestrates an annotation session: shows the full-screen overlay, collects
/// drawn strokes, classifies the gesture, captures + crops the screen region,
/// and adds the result to the context stack as an `.annotation` item.
///
/// Phase 3 ships a *modal* session — the overlay is key and captures all drawing
/// directly, finishing on a completed gesture or Esc. The Option-gated click-
/// through path is layered on in a later phase.
@MainActor
final class AnnotationManager: ObservableObject {
    @Published private(set) var isSessionActive = false

    private weak var appState: AppState?
    private let capture = ScreenCaptureService()
    private var overlay: AnnotationOverlayController?

    /// Strokes completed in the current session, in screen-local points
    /// (bottom-left origin) of the screen being annotated.
    private var strokes: [[CGPoint]] = []
    private var finalizeTask: Task<Void, Never>?
    /// The screen the current session is drawing on.
    private var activeScreen: NSScreen?

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Session lifecycle

    /// Begin a standalone modal annotation session.
    func startSession() {
        guard !isSessionActive else { return }
        guard capture.requestPermission() else {
            appState?.needsScreenRecordingPermission = true
            return
        }
        appState?.needsScreenRecordingPermission = false

        capture.invalidateCache()
        strokes = []
        activeScreen = NSScreen.main

        let overlay = AnnotationOverlayController(manager: self)
        overlay.show()
        self.overlay = overlay
        isSessionActive = true
    }

    func endSession() {
        guard isSessionActive else { return }
        finalizeTask?.cancel()
        finalizeTask = nil
        overlay?.hide()
        overlay = nil
        strokes = []
        activeScreen = nil
        isSessionActive = false
    }

    /// Toggle for the standalone hotkey.
    func toggleSession() {
        if isSessionActive { endSession() } else { startSession() }
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

        // Dismiss the overlay before capturing so the strokes aren't in the shot.
        let capturedStrokes = strokes
        endSession()

        guard !capturedStrokes.isEmpty else { return }
        // Let the window server actually hide the overlay panel before grabbing
        // the screen, and bypass the capture cache (it predates the dismissal).
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
