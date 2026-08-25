import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayController {
    private let panel: NSPanel
    private let hostingView: NSHostingView<AnyView>
    private let panelSize: CGFloat = 56 // 36pt circle + 10pt shadow padding per side
    private weak var statusItemButton: NSStatusBarButton?
    private var customOrigin: NSPoint?
    private var cachedDefaultOrigin: NSPoint?
    private var dragMonitor: Any?
    private var dragStartOrigin: NSPoint?
    private var dragStartMouse: NSPoint?
    private var isDragging = false
    private let visibility = OverlayVisibility()
    private var hideTask: Task<Void, Never>?

    init(appState: AppState) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 56, height: 56),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.isMovable = false

        let view = RecordingOverlayView(visibility: visibility).environmentObject(appState)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 56, height: 56)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    func show(below statusItemButton: NSStatusBarButton) {
        hideTask?.cancel()
        hideTask = nil
        visibility.suppressTap = false
        self.statusItemButton = statusItemButton
        let origin = defaultOrigin()
        cachedDefaultOrigin = origin
        panel.setFrameOrigin(customOrigin ?? origin)
        panel.orderFrontRegardless()
        installDragMonitor()

        // Defer one runloop turn so the collapsed state renders first,
        // then the SwiftUI spring animates the bubble growing out of the menubar.
        DispatchQueue.main.async { [visibility] in
            MainActor.assumeIsolated {
                visibility.visible = true
            }
        }
    }

    func hide() {
        if isDragging {
            customOrigin = panel.frame.origin
        }
        dragStartOrigin = nil
        dragStartMouse = nil
        isDragging = false
        removeDragMonitor()
        visibility.visible = false
        hideTask?.cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            hideTask = nil
            panel.orderOut(nil)
            return
        }
        // Keep the panel on screen until the SwiftUI retract animation finishes.
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    // MARK: - Positioning

    private func defaultOrigin() -> NSPoint {
        guard let button = statusItemButton, let buttonWindow = button.window else {
            return cachedDefaultOrigin ?? panel.frame.origin
        }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let x = screenRect.midX - panelSize / 2
        let y = screenRect.minY - panelSize
        return NSPoint(x: x, y: y)
    }

    private func statusItemCenter() -> NSPoint? {
        guard let button = statusItemButton, let buttonWindow = button.window else {
            return nil
        }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        return NSPoint(x: screenRect.midX, y: screenRect.midY)
    }

    // MARK: - Drag handling

    private func installDragMonitor() {
        removeDragMonitor()
        let panelRef = panel

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            switch event.type {
            case .leftMouseDown:
                // Only start tracking if the click is on our panel
                guard event.window === panelRef else { return event }
                MainActor.assumeIsolated {
                    self?.beginTracking()
                }
            case .leftMouseDragged:
                MainActor.assumeIsolated {
                    self?.continueTracking()
                }
            case .leftMouseUp:
                MainActor.assumeIsolated {
                    self?.endTracking()
                }
            default:
                break
            }
            return event
        }
    }

    private func beginTracking() {
        visibility.suppressTap = false
        dragStartOrigin = panel.frame.origin
        dragStartMouse = NSEvent.mouseLocation
        isDragging = false
    }

    private func continueTracking() {
        guard let origin = dragStartOrigin, let start = dragStartMouse else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - start.x
        let dy = current.y - start.y

        if !isDragging {
            // Only start dragging after 3pt movement to preserve tap gesture
            guard sqrt(dx * dx + dy * dy) > 3 else { return }
            isDragging = true
            visibility.suppressTap = true
        }

        panel.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    private func endTracking() {
        guard dragStartMouse != nil else { return }
        if isDragging {
            commitDragPosition()
        }
        dragStartOrigin = nil
        dragStartMouse = nil
        isDragging = false
    }

    private func removeDragMonitor() {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
    }

    private func commitDragPosition() {
        let panelCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let home = defaultOrigin()
        let homeCenter = NSPoint(x: home.x + panelSize / 2, y: home.y + panelSize / 2)
        var distance = distanceBetween(panelCenter, homeCenter)
        if let iconCenter = statusItemCenter() {
            distance = min(distance, distanceBetween(panelCenter, iconCenter))
        }

        if distance < 40 {
            customOrigin = nil
            cachedDefaultOrigin = home
            animateOrigin(to: home)
            return
        }
        customOrigin = panel.frame.origin
    }

    private func distanceBetween(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    /// Animate panel origin with async frame stepping.
    private func animateOrigin(to target: NSPoint) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrameOrigin(target)
            return
        }
        let start = panel.frame.origin
        let duration: CFTimeInterval = 0.2
        let startTime = CACurrentMediaTime()

        Task { @MainActor [weak self] in
            while let self {
                let elapsed = CACurrentMediaTime() - startTime
                let t = min(elapsed / duration, 1.0)
                // Ease-out cubic
                let eased = 1.0 - pow(1.0 - t, 3)
                let x = start.x + (target.x - start.x) * eased
                let y = start.y + (target.y - start.y) * eased
                self.panel.setFrameOrigin(NSPoint(x: x, y: y))
                if t >= 1.0 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}
