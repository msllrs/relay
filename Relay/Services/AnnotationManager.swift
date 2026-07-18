import AppKit
import Combine

/// What region a finished annotation captures.
enum CaptureScope: String, CaseIterable, Identifiable {
    case crop        // crop to the drawn marks (per-shape padding)
    case fullScreen  // the entire display, with the marks burned in

    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: "Crop to mark"
        case .fullScreen: "Full screen"
        }
    }
}

/// Orchestrates an annotation session: shows the full-screen overlay, collects
/// drawn strokes, classifies the gesture, captures + crops the screen region,
/// and adds the result to the context stack as an `.annotation` item.
///
/// "Push to draw": the user holds the annotation shortcut (e.g. ⌃⌥A); while held
/// the overlay is up and drawing is live (all strokes stay visible). Releasing
/// the shortcut is the finish signal — it captures the whole gesture. Release,
/// not a timer, ends the hold, so multi-stroke shapes (arrow shaft + head, X's
/// two diagonals) work regardless of how long you pause between strokes.
///
/// AppState drives the lifecycle: it starts a session on the hotkey press and
/// calls `finishHold()` from the key-up monitor on release.
@MainActor
final class AnnotationManager: ObservableObject {
    @Published private(set) var isSessionActive = false
    /// True when this session collects multiple gestures (Return/Esc to finish).
    @Published private(set) var isMultiMode = false

    private weak var appState: AppState?
    private let capture = ScreenCaptureService()
    private var overlay: AnnotationOverlayController?

    /// Strokes drawn during the current hold, in screen-local points
    /// (bottom-left origin) of the screen being annotated.
    private var strokes: [[CGPoint]] = []
    /// In multi mode, strokes committed from prior holds this session.
    private var committedStrokes: [[CGPoint]] = []
    private var isStrokeInProgress = false
    private var pendingFinish = false
    private var activeScreen: NSScreen?
    private var captureScope: CaptureScope = .crop
    /// We only ever surface the system permission prompt once per launch.
    private var didRequestPermission = false

    init(appState: AppState) {
        self.appState = appState
    }

    /// Request Screen Recording access at most once per launch, and only when
    /// preflight says it's missing. Avoids re-prompting on every hold (preflight
    /// caches a stale `false`).
    private func requestPermissionOnceIfNeeded() {
        guard !didRequestPermission else { return }
        if !capture.hasPermission() {
            didRequestPermission = true
            capture.requestPermission()
        }
    }

    // MARK: - Session lifecycle

    /// Begin a push-to-draw session (called on shortcut press). Drawing is live
    /// for the whole hold; `finishHold()` ends it (single mode) or commits it
    /// (multi mode).
    func beginHold() {
        if isSessionActive {
            // Multi mode: a subsequent hold draws another mark on the same session.
            return
        }
        // NOTE: do NOT call requestPermission()/preflight here. CGPreflightScreen-
        // CaptureAccess() caches a stale `false` for the process lifetime even after
        // the grant, so prompting on every hold re-shows the dialog forever while
        // capture actually succeeds. We surface the prompt at most once per launch
        // (below) and otherwise let the capture path + Settings banner handle a real
        // denial — a failed capture, not preflight, is the source of truth.
        requestPermissionOnceIfNeeded()

        captureScope = appState?.annotationCaptureScope ?? .crop
        isMultiMode = appState?.annotationAllowMultiple ?? false
        capture.invalidateCache()
        strokes = []
        committedStrokes = []
        isStrokeInProgress = false
        pendingFinish = false
        activeScreen = NSScreen.main

        let overlay = AnnotationOverlayController(manager: self)
        overlay.show(clickThrough: false) // key window; pen draws immediately
        self.overlay = overlay
        isSessionActive = true
    }

    /// Release of the shortcut. Single mode → capture + dismiss. Multi mode →
    /// commit this hold's strokes and keep the overlay open for more.
    func finishHold() {
        guard isSessionActive else { return }
        // If a stroke is mid-draw, let mouseUp land first, then finish.
        if isStrokeInProgress {
            pendingFinish = true
            return
        }
        if isMultiMode {
            committedStrokes.append(contentsOf: strokes)
            strokes = []
            return // stay active; Return finalizes, Esc cancels
        }
        if strokes.isEmpty {
            endSession() // nothing drawn — just dismiss
            return
        }
        finalizeGesture()
    }

    /// Return key in multi mode → finalize everything drawn this session.
    func commitMultiSession() {
        guard isSessionActive, isMultiMode else { return }
        committedStrokes.append(contentsOf: strokes)
        strokes = []
        if committedStrokes.isEmpty { endSession(); return }
        finalizeGesture()
    }

    func endSession() {
        guard isSessionActive else { return }
        overlay?.hide()
        overlay = nil
        strokes = []
        committedStrokes = []
        isStrokeInProgress = false
        pendingFinish = false
        activeScreen = nil
        isSessionActive = false
        isMultiMode = false
    }

    // MARK: - Recording auto-arm

    /// Currently a no-op: while recording, the user holds the same annotation
    /// shortcut to draw, which routes through begin/finishHold like the
    /// standalone path. Kept for the AppState recording sink to call.
    func armForRecording() {}
    func disarmForRecording() { endSession() }

    // MARK: - Stroke input (called by the drawing view)

    func beginStroke(on screen: NSScreen) {
        isStrokeInProgress = true
        activeScreen = screen
    }

    func completeStroke(_ points: [CGPoint], on screen: NSScreen) {
        isStrokeInProgress = false
        if points.count >= 2 {
            activeScreen = screen
            strokes.append(points)
        }
        // The shortcut was released mid-stroke — finish now that the pen is up.
        if pendingFinish {
            pendingFinish = false
            finishHold()
        }
    }

    // MARK: - Finalize

    private func finalizeGesture() {
        let allStrokes = committedStrokes + strokes
        guard !allStrokes.isEmpty, let screen = activeScreen else { endSession(); return }
        let shape = ShapeClassifier.classify(strokes: allStrokes)
        let scope = captureScope

        let pixelRect: CGRect
        switch scope {
        case .fullScreen:
            // The whole display, in pixels.
            pixelRect = ScreenCaptureService.fullScreenPixelRect(screen)
        case .crop:
            let bbox = ShapeClassifier.unionBoundingBox(allStrokes)
            pixelRect = ScreenCaptureService.toPixelRect(shape.paddedRect(bbox), screen: screen)
        }

        // Dismiss the overlay (and its rendered strokes) before capturing so the
        // shot is clean — we re-draw the marks onto the image ourselves. The
        // smoky dissolve plays on its own capture-excluded panel, so it can run
        // while the screenshot happens without contaminating it.
        endSession()
        AnnotationDissolvePanel.play(strokes: allStrokes, on: screen)

        Task { [weak self] in
            guard let self else { return }
            self.capture.invalidateCache()
            try? await Task.sleep(for: .milliseconds(80))
            await self.captureAndStore(pixelRect: pixelRect, screen: screen, shape: shape, strokes: allStrokes)
        }
    }

    private func captureAndStore(pixelRect: CGRect, screen: NSScreen, shape: AnnotationShape, strokes: [[CGPoint]]) async {
        do {
            let full = try await capture.captureFullScreen(of: screen)
            // Capture succeeded — clear any stale "needs permission" banner that
            // preflight may have set.
            appState?.needsScreenRecordingPermission = false
            guard let path = capture.cropAndSave(full, pixelRect: pixelRect, strokes: strokes, screen: screen) else { return }
            appState?.addItem(ClipboardItem(
                contentType: .annotation,
                textContent: shape.intentLabel,
                imagePath: path
            ))
        } catch {
            // A failed/blank capture is the real signal that permission is missing.
            NSLog("AnnotationManager capture failed: \(error)")
            appState?.needsScreenRecordingPermission = true
        }
    }
}
