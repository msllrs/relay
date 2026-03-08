import Combine
import SwiftUI

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = MenuBarIconBuilder.buildIcon(state: .normal)
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover.contentSize = NSSize(width: 360, height: 10) // height is dynamic
        popover.behavior = .transient // closes on click-outside and Esc
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopover()
                .environmentObject(appState)
        )

        // Update the icon when any AppState property changes.
        // objectWillChange fires before the value is set, so defer to next run loop.
        cancellables.append(appState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() })
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Ensure the popover's window can receive key events
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateIcon() {
        let state: MenuBarIconBuilder.IconState
        if appState.isRecording {
            state = .recording
        } else if appState.itemJustAdded {
            state = .badge
        } else if appState.isMonitoring {
            state = .active
        } else {
            state = .normal
        }
        statusItem.button?.image = MenuBarIconBuilder.buildIcon(state: state)
    }
}
