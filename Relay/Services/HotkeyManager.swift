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

    /// True when AXIsProcessTrusted() reports granted but global NSEvent monitors
    /// return nil — the binary hash changed after an update and the TCC entry is stale.
    private(set) var accessibilityBroken = false

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
        // Carbon hotkey and local monitor work without accessibility — register immediately.
        registerCarbonHotKey()
        installLocalMonitor()
        // Global NSEvent monitors require accessibility — request and gate behind it.
        requestAccessibilityForGlobalMonitors()
    }

    // MARK: - Shortcut management

    func updateShortcut(_ shortcut: KeyboardShortcutModel) {
        currentShortcut = shortcut
        shortcut.save()
        if !isSuspended {
            registerCarbonHotKey()
            installLocalMonitor()
        }
    }

    /// Temporarily disable monitors (e.g. while recording a new shortcut).
    private var isSuspended = false

    func suspendMonitors() {
        isSuspended = true
        unregisterCarbonHotKey()
        removeLocalMonitor()
    }

    func resumeMonitors() {
        isSuspended = false
        registerCarbonHotKey()
        installLocalMonitor()
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

    /// Registers the Carbon hotkey for the current shortcut. Does not require accessibility.
    /// Safe to call unconditionally — re-registers if already registered.
    private func registerCarbonHotKey() {
        unregisterCarbonHotKey()
        let carbonMods = carbonModifiers(from: currentShortcut.modifierFlags)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(currentShortcut.keyCode),
            carbonMods,
            kHotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
            hotkeyLog.notice("RegisterEventHotKey succeeded for keyCode=\(self.currentShortcut.keyCode)")
        } else {
            hotkeyLog.error("RegisterEventHotKey failed: \(status)")
        }
    }

    private func unregisterCarbonHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    /// Installs the local NSEvent monitor so the shortcut works when Relay is focused.
    /// Local monitors do not require accessibility.
    private func installLocalMonitor() {
        removeLocalMonitor()
        let keyCode = currentShortcut.keyCode
        let modifierFlags = currentShortcut.modifierFlags
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

    private func removeLocalMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    // MARK: - Accessibility (global monitors only)

    /// Requests accessibility permission needed for global NSEvent monitors (key-up, escape).
    /// Carbon hotkey and local monitor are already registered unconditionally — this only
    /// gates the global monitors that require accessibility.
    private func requestAccessibilityForGlobalMonitors() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hotkeyLog.notice("AXIsProcessTrusted: \(trusted)")
        if !trusted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        // Global monitors are installed on demand in startEscMonitor / startKeyUpMonitor.
        // Nothing else to do here — the Carbon hotkey already works.
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

        // If the global monitor returned nil despite accessibility appearing granted,
        // the TCC entry is stale (binary hash changed after an update).
        detectAccessibilityBrokenIfNeeded(globalMonitor: escGlobalMonitor)
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

        detectAccessibilityBrokenIfNeeded(globalMonitor: globalKeyUpMonitor)
    }

    /// If a global NSEvent monitor returned nil despite AXIsProcessTrusted() being true,
    /// the TCC entry is stale — the binary hash changed after a Sparkle update.
    /// Surfaces the broken state so the UI can warn the user.
    private func detectAccessibilityBrokenIfNeeded(globalMonitor: Any?) {
        guard AXIsProcessTrusted() else { return }
        let broken = globalMonitor == nil
        if broken != accessibilityBroken {
            accessibilityBroken = broken
            appState?.accessibilityBroken = broken
            if broken {
                hotkeyLog.warning("Global monitor is nil despite AXIsProcessTrusted — TCC entry is stale after update")
            }
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
