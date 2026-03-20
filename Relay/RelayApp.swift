import Combine
import SwiftUI

/// NSHostingController that caps the popover height at 85% of screen visible area.
/// Without this, a SwiftUI ScrollView claims infinite height and the popover either
/// explodes to fill the screen or collapses. The cap gives ScrollView a finite proposal.
final class MaxHeightHostingController<Content: View>: NSHostingController<Content> {
    private static var maxScreenFraction: CGFloat { 0.85 }

    override var preferredContentSize: NSSize {
        get {
            var size = super.preferredContentSize
            size.width = min(size.width, 360)
            if let screen = NSScreen.main {
                size.height = min(size.height, screen.visibleFrame.height * Self.maxScreenFraction)
            }
            return size
        }
        set { super.preferredContentSize = newValue }
    }
}

@main
struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No visible scenes — everything is driven by the status item
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let appState = AppState()
    private var cancellables: [Any] = []
    private var lastIconState: MenuBarIconBuilder.IconState?
    private var dotLayer: CALayer?
    private var dotGeneration = 0
    private var overlayController: RecordingOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = MenuBarIconBuilder.buildIcon(state: .normal)
            button.action = #selector(togglePopover)
            button.target = self

            let dropView = StatusItemDropView(
                appState: appState,
                openPopover: { [weak self] in self?.showPopover() }
            )
            dropView.frame = button.bounds
            dropView.autoresizingMask = [.width, .height]
            button.addSubview(dropView)
        }

        popover.contentSize = NSSize(width: 360, height: 10) // height is dynamic
        popover.behavior = appState.pinPopover ? .applicationDefined : .transient
        popover.animates = false // instant show/close prevents isShown race on rapid clicks
        popover.delegate = self
        popover.contentViewController = MaxHeightHostingController(
            rootView: MenuBarPopover()
                .environmentObject(appState)
        )

        // Switch popover behavior when pin state changes
        cancellables.append(appState.$pinPopover
            .removeDuplicates()
            .sink { [weak self] pinned in
                self?.popover.behavior = pinned ? .applicationDefined : .transient
            })

        // Update the icon when any AppState property changes.
        // objectWillChange fires before the value is set, so defer to next run loop.
        cancellables.append(appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() })

        // Show/hide recording overlay when recording state changes
        overlayController = RecordingOverlayController(appState: appState)
        cancellables.append(appState.$isRecording
            .removeDuplicates()
            .sink { [weak self] isRecording in
                guard let self, let button = self.statusItem.button else { return }
                if isRecording && self.appState.showRecordingOverlay && !self.popover.isShown {
                    self.overlayController?.show(below: button)
                } else {
                    self.overlayController?.hide()
                }
            })

        // Hide/show overlay immediately when the setting is toggled mid-recording
        cancellables.append(appState.$showRecordingOverlay
            .removeDuplicates()
            .sink { [weak self] showOverlay in
                guard let self else { return }
                if self.appState.isRecording && !self.popover.isShown {
                    if showOverlay, let button = self.statusItem.button {
                        self.overlayController?.show(below: button)
                    } else if !showOverlay {
                        self.overlayController?.hide()
                    }
                }
            })
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.close()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        overlayController?.hide()
    }

    func popoverDidClose(_ notification: Notification) {
        if appState.isRecording, appState.showRecordingOverlay, let button = statusItem.button {
            overlayController?.show(below: button)
        }
    }

    private func updateIcon() {
        let state: MenuBarIconBuilder.IconState
        if appState.itemJustAdded {
            state = .badge
        } else if appState.isRecording {
            state = .recording
        } else if appState.isMonitoring {
            state = .active
        } else {
            state = .normal
        }
        guard state != lastIconState else { return }
        let previousState = lastIconState
        lastIconState = state
        let appearance = statusItem.button?.effectiveAppearance
        statusItem.button?.image = MenuBarIconBuilder.buildIcon(state: state, appearance: appearance)

        // Manage the animated dot overlay
        let newColor = MenuBarIconBuilder.dotColor(for: state)
        let hadDot = previousState.flatMap(MenuBarIconBuilder.dotColor(for:)) != nil

        if let color = newColor {
            let dot = dotLayer ?? makeDotLayer()
            dot.backgroundColor = color.cgColor

            if hadDot {
                // Transition between dot colors: scale down then back up
                let scaleDown = CABasicAnimation(keyPath: "transform.scale")
                scaleDown.fromValue = 1.0
                scaleDown.toValue = 0.01
                scaleDown.duration = 0.1

                let scaleUp = CABasicAnimation(keyPath: "transform.scale")
                scaleUp.fromValue = 0.01
                scaleUp.toValue = 1.0
                scaleUp.duration = 0.15
                scaleUp.beginTime = 0.1

                let group = CAAnimationGroup()
                group.animations = [scaleDown, scaleUp]
                group.duration = 0.25
                dot.add(group, forKey: "dotSwap")
            } else {
                // Appear: scale up from zero
                let appear = CABasicAnimation(keyPath: "transform.scale")
                appear.fromValue = 0.01
                appear.toValue = 1.0
                appear.duration = 0.15
                dot.add(appear, forKey: "dotAppear")
            }
        } else if let dot = dotLayer {
            // Disappear: scale down then remove
            let disappear = CABasicAnimation(keyPath: "transform.scale")
            disappear.fromValue = 1.0
            disappear.toValue = 0.01
            disappear.duration = 0.12
            disappear.fillMode = .forwards
            disappear.isRemovedOnCompletion = false
            dot.add(disappear, forKey: "dotDisappear")

            dotGeneration += 1
            let expectedGeneration = dotGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.dotGeneration == expectedGeneration else { return }
                self.dotLayer?.removeFromSuperlayer()
                self.dotLayer = nil
            }
        }
    }

    private func makeDotLayer() -> CALayer {
        guard let button = statusItem.button else { fatalError("No status button") }
        button.wantsLayer = true
        // SVG dot: center (28, 8) in 36×36 viewBox → (14, 4) in 18pt icon.
        // NSStatusBarButton is flipped, but its layer is geometry-flipped to match,
        // so we use the same Y=4 from top.
        let dotSize: CGFloat = 5.5
        let buttonSize = button.bounds.size
        let iconSize: CGFloat = 18
        let iconX = (buttonSize.width - iconSize) / 2
        let iconY = (buttonSize.height - iconSize) / 2

        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        // anchorPoint defaults to (0.5, 0.5) — position is the center point
        layer.position = CGPoint(x: iconX + 14, y: iconY + 4)
        layer.cornerRadius = dotSize / 2
        layer.masksToBounds = true
        button.layer?.addSublayer(layer)
        dotLayer = layer
        return layer
    }
}

// MARK: - Drag-and-drop target for the status bar button

private final class StatusItemDropView: NSView {
    private weak var appState: AppState?
    private let openPopover: () -> Void

    init(appState: AppState, openPopover: @escaping () -> Void) {
        self.appState = appState
        self.openPopover = openPopover
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Allow drags to reach this view, but forward all mouse events to the button
    override func hitTest(_ point: NSPoint) -> NSView? {
        // During a drag session the system resolves destinations separately,
        // so returning nil here lets normal clicks pass through to the button.
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }

        MainActor.assumeIsolated {
            guard let appState else { return }
            for url in urls {
                appState.addItem(ClipboardItem.fromFileURL(url))
            }
            openPopover()
        }
        return true
    }
}
