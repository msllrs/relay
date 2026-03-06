import AppKit
import ApplicationServices
import os.log

private let hotkeyLog = Logger(subsystem: "com.msllrs.relay", category: "HotkeyManager")

@MainActor
final class HotkeyManager {
    private weak var appState: AppState?
    nonisolated(unsafe) private var globalMonitor: Any?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var escGlobalMonitor: Any?
    nonisolated(unsafe) private var escLocalMonitor: Any?
    nonisolated(unsafe) private var globalKeyUpMonitor: Any?
    nonisolated(unsafe) private var localKeyUpMonitor: Any?
    private(set) var currentShortcut: KeyboardShortcutModel

    init(appState: AppState) {
        self.appState = appState
        self.currentShortcut = KeyboardShortcutModel.load()
        requestAccessibilityAndSetup()
    }

    /// Prompts for Accessibility permissions if needed, polls until granted, then installs monitors.
    private func requestAccessibilityAndSetup() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hotkeyLog.notice("AXIsProcessTrusted: \(trusted)")
        if trusted {
            setupMonitors()
        } else {
            // Open Accessibility settings pane so the user can grant permission
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            // Poll until user grants permission, then install monitors
            Task {
                while !AXIsProcessTrusted() {
                    try? await Task.sleep(for: .seconds(1))
                }
                hotkeyLog.notice("Accessibility granted, installing monitors")
                setupMonitors()
            }
        }
    }

    func updateShortcut(_ shortcut: KeyboardShortcutModel) {
        removeMonitors()
        currentShortcut = shortcut
        shortcut.save()
        if !isSuspended { setupMonitors() }
    }

    /// Temporarily disable monitors (e.g. while recording a new shortcut).
    private var isSuspended = false

    func suspendMonitors() {
        isSuspended = true
        removeMonitors()
    }

    func resumeMonitors() {
        isSuspended = false
        setupMonitors()
    }

    private func setupMonitors() {
        let keyCode = currentShortcut.keyCode
        let modifierFlags = currentShortcut.modifierFlags
        hotkeyLog.notice("Setting up monitors for keyCode=\(keyCode) modifiers=\(modifierFlags.rawValue)")

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if !event.isARepeat,
               event.keyCode == keyCode,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags {
                MainActor.assumeIsolated {
                    self?.appState?.hotkeyTriggered()
                }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if !event.isARepeat,
               event.keyCode == keyCode,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags {
                MainActor.assumeIsolated {
                    self?.appState?.hotkeyTriggered()
                }
                return nil
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    func startEscMonitor(onEsc: @escaping @MainActor () -> Void) {
        stopEscMonitor()

        escGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                MainActor.assumeIsolated {
                    onEsc()
                }
            }
        }

        escLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                MainActor.assumeIsolated {
                    onEsc()
                }
                return nil
            }
            return event
        }
    }

    func stopEscMonitor() {
        if let escGlobalMonitor { NSEvent.removeMonitor(escGlobalMonitor) }
        if let escLocalMonitor { NSEvent.removeMonitor(escLocalMonitor) }
        escGlobalMonitor = nil
        escLocalMonitor = nil
    }

    func startKeyUpMonitor(onKeyUp: @escaping @MainActor () -> Void) {
        stopKeyUpMonitor()

        let keyCode = currentShortcut.keyCode

        globalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == keyCode {
                MainActor.assumeIsolated {
                    onKeyUp()
                }
            }
        }

        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == keyCode {
                MainActor.assumeIsolated {
                    onKeyUp()
                }
                return nil
            }
            return event
        }
    }

    func stopKeyUpMonitor() {
        if let globalKeyUpMonitor { NSEvent.removeMonitor(globalKeyUpMonitor) }
        if let localKeyUpMonitor { NSEvent.removeMonitor(localKeyUpMonitor) }
        globalKeyUpMonitor = nil
        localKeyUpMonitor = nil
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let escGlobalMonitor { NSEvent.removeMonitor(escGlobalMonitor) }
        if let escLocalMonitor { NSEvent.removeMonitor(escLocalMonitor) }
        if let globalKeyUpMonitor { NSEvent.removeMonitor(globalKeyUpMonitor) }
        if let localKeyUpMonitor { NSEvent.removeMonitor(localKeyUpMonitor) }
    }
}
