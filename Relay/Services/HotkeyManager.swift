import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let hotkeyLog = Logger(subsystem: "com.msllrs.relay", category: "HotkeyManager")

/// Unique ID for the registered Carbon hotkey.
private let kHotkeyID = EventHotKeyID(signature: fourCharCode("RLAY"), id: 1)

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for char in string.utf8.prefix(4) {
        result = (result << 8) | OSType(char)
    }
    return result
}

/// Convert NSEvent modifier flags to Carbon modifier mask used by RegisterEventHotKey.
private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.command) { carbon |= UInt32(cmdKey) }
    if flags.contains(.option) { carbon |= UInt32(optionKey) }
    if flags.contains(.control) { carbon |= UInt32(controlKey) }
    if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
    return carbon
}

@MainActor
final class HotkeyManager {
    private weak var appState: AppState?
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var escGlobalMonitor: Any?
    nonisolated(unsafe) private var escLocalMonitor: Any?
    nonisolated(unsafe) private var globalKeyUpMonitor: Any?
    nonisolated(unsafe) private var localKeyUpMonitor: Any?
    private(set) var currentShortcut: KeyboardShortcutModel

    init(appState: AppState) {
        self.appState = appState
        self.currentShortcut = KeyboardShortcutModel.load()
        installCarbonHandler()
        requestAccessibilityAndSetup()
    }

    /// Request accessibility permissions (needed for global NSEvent monitors like key-up and escape).
    /// Carbon hotkeys work without it, but push-to-talk key-up detection requires it.
    private func requestAccessibilityAndSetup() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hotkeyLog.notice("AXIsProcessTrusted: \(trusted)")
        if trusted {
            setupMonitors()
        } else {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
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

    // MARK: - Carbon Hot Key

    /// Installs the Carbon event handler once. It lives for the lifetime of the app.
    private func installCarbonHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        // Store a raw pointer to self for the C callback.
        // Safe because HotkeyManager lives for the app's lifetime.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotkeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotkeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                MainActor.assumeIsolated {
                    manager.appState?.hotkeyTriggered()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func setupMonitors() {
        let keyCode = currentShortcut.keyCode
        let modifierFlags = currentShortcut.modifierFlags
        hotkeyLog.notice("Setting up monitors for keyCode=\(keyCode) modifiers=\(modifierFlags.rawValue)")

        // Register a system-level Carbon hotkey that consumes the keystroke.
        let carbonMods = carbonModifiers(from: modifierFlags)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            carbonMods,
            kHotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            hotkeyLog.error("RegisterEventHotKey failed: \(status)")
        }

        // Local monitor still needed so the shortcut works when Relay itself is focused
        // (Carbon hotkeys don't fire for the registering app's own key events).
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
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
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
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let escGlobalMonitor { NSEvent.removeMonitor(escGlobalMonitor) }
        if let escLocalMonitor { NSEvent.removeMonitor(escLocalMonitor) }
        if let globalKeyUpMonitor { NSEvent.removeMonitor(globalKeyUpMonitor) }
        if let localKeyUpMonitor { NSEvent.removeMonitor(localKeyUpMonitor) }
    }
}
