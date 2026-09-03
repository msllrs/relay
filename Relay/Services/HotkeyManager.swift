import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os.log

private let hotkeyLog = Logger(subsystem: "com.msllrs.relay", category: "HotkeyManager")

/// Unique IDs for the registered Carbon hotkeys.
private let kHotkeyID = EventHotKeyID(signature: fourCharCode("RLAY"), id: 1)
private let kAnnotateHotkeyID = EventHotKeyID(signature: fourCharCode("RLAY"), id: 2)

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

/// CGEvent tap callback for the Esc-to-cancel monitor. The tap's run-loop
/// source is scheduled on the main run loop, so this executes on the main
/// thread. Returning nil consumes the event: the frontmost app never sees
/// the Esc that cancelled a recording.
private func escTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

    // macOS disables taps it considers stalled; re-arm and let events flow.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { manager.reenableEscTap() }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 else {
        return Unmanaged.passUnretained(event)
    }

    MainActor.assumeIsolated { manager.escHandler?() }
    return nil
}

@MainActor
final class HotkeyManager {
    private weak var appState: AppState?

    /// True when AXIsProcessTrusted() reports granted but global NSEvent monitors
    /// return nil — the binary hash changed after an update and the TCC entry is stale.
    private(set) var accessibilityBroken = false

    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var annotateHotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var annotateLocalMonitor: Any?
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
    nonisolated(unsafe) private var localMonitor: Any?
    nonisolated(unsafe) private var escGlobalMonitor: Any?
    nonisolated(unsafe) private var escLocalMonitor: Any?
    nonisolated(unsafe) private var escEventTap: CFMachPort?
    nonisolated(unsafe) private var escRunLoopSource: CFRunLoopSource?
    fileprivate var escHandler: (@MainActor () -> Void)?
    nonisolated(unsafe) private var globalKeyUpMonitor: Any?
    nonisolated(unsafe) private var localKeyUpMonitor: Any?
    nonisolated(unsafe) private var annotateGlobalKeyUpMonitor: Any?
    nonisolated(unsafe) private var annotateLocalKeyUpMonitor: Any?
    nonisolated(unsafe) private var annotateFlagsMonitors: [Any] = []
    /// Prevents opening System Settings repeatedly when AXIsProcessTrusted() returns
    /// false transiently (e.g. after a sleep/wake cycle).
    private var didRedirectToAccessibilitySettings = false
    private(set) var currentShortcut: KeyboardShortcutModel
    private(set) var currentAnnotateShortcut: KeyboardShortcutModel

    init(appState: AppState) {
        self.appState = appState
        self.currentShortcut = KeyboardShortcutModel.load()
        self.currentAnnotateShortcut = KeyboardShortcutModel.load(
            key: KeyboardShortcutModel.annotateDefaultsKey,
            fallback: .annotateDefault
        )
        installCarbonHandler()
        registerCarbonHotKey()
        registerAnnotateHotKey()
        installLocalMonitor()
        installAnnotateLocalMonitor()
        requestAccessibilityForGlobalMonitors()
    }

    // MARK: - Shortcut management

    func updateShortcut(_ shortcut: KeyboardShortcutModel) {
        currentShortcut = shortcut
        appState?.dictationShortcut = shortcut
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
        unregisterAnnotateHotKey()
        removeLocalMonitor()
        removeAnnotateLocalMonitor()
    }

    func resumeMonitors() {
        isSuspended = false
        registerCarbonHotKey()
        registerAnnotateHotKey()
        installLocalMonitor()
        installAnnotateLocalMonitor()
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
                let id = hotkeyID.id
                MainActor.assumeIsolated {
                    if id == kAnnotateHotkeyID.id {
                        manager.appState?.annotateHotkeyTriggered()
                    } else {
                        manager.appState?.hotkeyTriggered()
                    }
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

    /// Registers the standalone annotation Carbon hotkey. Does not require accessibility.
    private func registerAnnotateHotKey() {
        unregisterAnnotateHotKey()
        let carbonMods = carbonModifiers(from: currentAnnotateShortcut.modifierFlags)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(currentAnnotateShortcut.keyCode),
            carbonMods,
            kAnnotateHotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            annotateHotKeyRef = ref
            hotkeyLog.notice("RegisterEventHotKey (annotate) succeeded for keyCode=\(self.currentAnnotateShortcut.keyCode)")
        } else {
            hotkeyLog.error("RegisterEventHotKey (annotate) failed: \(status)")
        }
    }

    private func unregisterAnnotateHotKey() {
        if let annotateHotKeyRef { UnregisterEventHotKey(annotateHotKeyRef) }
        annotateHotKeyRef = nil
    }

    func updateAnnotateShortcut(_ shortcut: KeyboardShortcutModel) {
        currentAnnotateShortcut = shortcut
        shortcut.save(key: KeyboardShortcutModel.annotateDefaultsKey)
        if !isSuspended {
            registerAnnotateHotKey()
            installAnnotateLocalMonitor()
        }
    }

    private func installAnnotateLocalMonitor() {
        removeAnnotateLocalMonitor()
        let keyCode = currentAnnotateShortcut.keyCode
        let modifierFlags = currentAnnotateShortcut.modifierFlags
        annotateLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if !event.isARepeat,
               event.keyCode == keyCode,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == modifierFlags {
                MainActor.assumeIsolated {
                    self?.appState?.annotateHotkeyTriggered()
                }
                return nil
            }
            return event
        }
    }

    private func removeAnnotateLocalMonitor() {
        if let annotateLocalMonitor { NSEvent.removeMonitor(annotateLocalMonitor) }
        annotateLocalMonitor = nil
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

    /// Checks accessibility silently at launch — no prompt, no System Settings redirect.
    /// The Carbon hotkey and local monitor already work without accessibility.
    /// Global monitors (key-up, escape) are installed on demand; if accessibility isn't
    /// granted at that point the user will see the Settings banner instead of a disruptive
    /// launch-time dialog.
    private func requestAccessibilityForGlobalMonitors() {
        let trusted = AXIsProcessTrusted()
        hotkeyLog.notice("AXIsProcessTrusted at launch: \(trusted)")
        appState?.accessibilityNotGranted = !trusted
    }

    func startEscMonitor(onEsc: @escaping @MainActor () -> Void) {
        stopEscMonitor()
        escHandler = onEsc

        // Active CGEvent tap so the cancelling Esc is CONSUMED — NSEvent
        // global monitors only observe, so the frontmost app would also
        // receive the Esc (closing its dialogs, exiting full screen, …).
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: escTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) {
            escEventTap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            escRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            return
        }

        // Fallback when the tap can't be created (no accessibility): cancel
        // still works via observe-only monitors, but Esc leaks through.
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

    /// Re-arm the tap after macOS disables it for stalling.
    fileprivate func reenableEscTap() {
        if let tap = escEventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func stopEscMonitor() {
        escHandler = nil
        if let escRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escRunLoopSource, .commonModes)
            self.escRunLoopSource = nil
        }
        if let escEventTap {
            CGEvent.tapEnable(tap: escEventTap, enable: false)
            self.escEventTap = nil
        }
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
        if !AXIsProcessTrusted() {
            appState?.accessibilityNotGranted = true
            // Not granted yet — open System Settings so user can grant it.
            // Only do this once per app session to avoid a loop when the TCC cache
            // is stale after a sleep/wake cycle.
            if !didRedirectToAccessibilitySettings {
                didRedirectToAccessibilitySettings = true
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }
        appState?.accessibilityNotGranted = false
        // Granted but monitor is nil — stale TCC entry after an update.
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

    /// Fires when the annotation shortcut's key is released — the "release to
    /// capture" signal for push-to-draw. Watches the base key and the modifiers
    /// (releasing any part of the combo ends the hold).
    func startAnnotateKeyUpMonitor(onRelease: @escaping @MainActor () -> Void) {
        stopAnnotateKeyUpMonitor()

        let keyCode = currentAnnotateShortcut.keyCode
        let requiredMods = currentAnnotateShortcut.modifierFlags

        // Base-key release (keyUp).
        annotateGlobalKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == keyCode {
                MainActor.assumeIsolated { onRelease() }
            }
        }
        annotateLocalKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            if event.keyCode == keyCode {
                MainActor.assumeIsolated { onRelease() }
                return nil
            }
            return event
        }

        // Modifier release (flagsChanged): if the held modifiers are no longer
        // all present, the combo was broken — treat as release.
        let modHandler: (NSEvent) -> Void = { event in
            let now = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !now.isSuperset(of: requiredMods) {
                MainActor.assumeIsolated { onRelease() }
            }
        }
        // Reuse the existing flags monitors slots is unsafe; attach standalone ones
        // that we tear down together with the key-up monitors.
        let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { modHandler($0) }
        let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { modHandler($0); return $0 }
        annotateFlagsMonitors = [g, l].compactMap { $0 }

        detectAccessibilityBrokenIfNeeded(globalMonitor: annotateGlobalKeyUpMonitor)
    }

    func stopAnnotateKeyUpMonitor() {
        if let annotateGlobalKeyUpMonitor { NSEvent.removeMonitor(annotateGlobalKeyUpMonitor) }
        if let annotateLocalKeyUpMonitor { NSEvent.removeMonitor(annotateLocalKeyUpMonitor) }
        annotateGlobalKeyUpMonitor = nil
        annotateLocalKeyUpMonitor = nil
        for m in annotateFlagsMonitors { NSEvent.removeMonitor(m) }
        annotateFlagsMonitors = []
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let annotateHotKeyRef { UnregisterEventHotKey(annotateHotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let annotateLocalMonitor { NSEvent.removeMonitor(annotateLocalMonitor) }
        if let escGlobalMonitor { NSEvent.removeMonitor(escGlobalMonitor) }
        if let escLocalMonitor { NSEvent.removeMonitor(escLocalMonitor) }
        if let escRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escRunLoopSource, .commonModes)
        }
        if let escEventTap {
            CGEvent.tapEnable(tap: escEventTap, enable: false)
        }
        if let globalKeyUpMonitor { NSEvent.removeMonitor(globalKeyUpMonitor) }
        if let localKeyUpMonitor { NSEvent.removeMonitor(localKeyUpMonitor) }
        if let annotateGlobalKeyUpMonitor { NSEvent.removeMonitor(annotateGlobalKeyUpMonitor) }
        if let annotateLocalKeyUpMonitor { NSEvent.removeMonitor(annotateLocalKeyUpMonitor) }
        for m in annotateFlagsMonitors { NSEvent.removeMonitor(m) }
    }
}
