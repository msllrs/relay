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
        panel.alphaValue = 0

        let view = RecordingOverlayView().environmentObject(appState)
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: 56, height: 56)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }

    func show(below statusItemButton: NSStatusBarButton) {
        self.statusItemButton = statusItemButton
        let origin = defaultOrigin()
        cachedDefaultOrigin = origin
        panel.setFrameOrigin(customOrigin ?? origin)
        panel.orderFrontRegardless()
        installDragMonitor()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        removeDragMonitor()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        })
    }

    // MARK: - Positioning

    private func defaultOrigin() -> NSPoint {
        guard let button = statusItemButton, let buttonWindow = button.window else {
            return cachedDefaultOrigin ?? panel.frame.origin
        }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let x = screenRect.midX - panelSize / 2
        let y = screenRect.minY - panelSize - 4
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
        let panelRef = panel
        nonisolated(unsafe) var startOrigin: NSPoint?
        nonisolated(unsafe) var startMouse: NSPoint?
        nonisolated(unsafe) var isTracking = false
        nonisolated(unsafe) var isDragging = false

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            switch event.type {
            case .leftMouseDown:
                // Only start tracking if the click is on our panel
                guard event.window === panelRef else { return event }
                startOrigin = panelRef.frame.origin
                startMouse = NSEvent.mouseLocation
                isTracking = true
                isDragging = false
                return event

            case .leftMouseDragged:
                guard isTracking, let origin = startOrigin, let mouse = startMouse else { return event }
                let current = NSEvent.mouseLocation
                let dx = current.x - mouse.x
                let dy = current.y - mouse.y

                if !isDragging {
                    // Only start dragging after 3pt movement to preserve tap gesture
                    guard sqrt(dx * dx + dy * dy) > 3 else { return event }
                    isDragging = true
                }

                panelRef.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
                return event

            case .leftMouseUp:
                guard isTracking else { return event }
                if isDragging {
                    MainActor.assumeIsolated {
                        self?.commitDragPosition()
                    }
                }
                startOrigin = nil
                startMouse = nil
                isTracking = false
                isDragging = false
                return event

            default:
                return event
            }
        }
    }

    private func removeDragMonitor() {
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
    }

    private func commitDragPosition() {
        if let center = statusItemCenter() {
            let panelCenter = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let dx = panelCenter.x - center.x
            let dy = panelCenter.y - center.y
            let distance = sqrt(dx * dx + dy * dy)

            if distance < 40 {
                customOrigin = nil
                let target = defaultOrigin()
                cachedDefaultOrigin = target
                animateOrigin(to: target)
                return
            }
        }
        customOrigin = panel.frame.origin
    }

    /// Animate panel origin with async frame stepping.
    private func animateOrigin(to target: NSPoint) {
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
