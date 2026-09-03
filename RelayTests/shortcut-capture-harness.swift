// Standalone test harness for ShortcutCaptureNSView (XCTest needs Xcode, which
// this machine doesn't have). Run with:
//   cat Relay/Models/KeyboardShortcutModel.swift Relay/Services/ModifierDoubleTapDetector.swift \
//       Relay/Views/ShortcutCaptureView.swift RelayTests/shortcut-capture-harness.swift > /tmp/sc-test.swift && swift /tmp/sc-test.swift
// Exits non-zero on failure.
//
// Reproduces the "stuck on Press shortcut..." bug reported on Sequoia: the
// recorder claimed first responder from a DispatchQueue.main.async scheduled
// in makeNSView. If SwiftUI attaches the view to the popover window *after*
// that block runs, `view.window` is nil, nothing becomes first responder, and
// every keystroke goes nowhere. The recorder must claim focus itself whenever
// it lands in a window, regardless of ordering.

import AppKit
import SwiftUI

_ = NSApplication.shared

var failures = 0
func expect(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

func spinRunLoop() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

func makeWindow() -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
    return window
}

func keyEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
    )!
}

// The reported bug: the view is created (and the representable's deferred
// focus grab has already run against a nil window) before SwiftUI attaches it
// to the popover window. Attaching must still make it first responder.
do {
    let window = makeWindow()
    let view = ShortcutCaptureNSView()
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) } // what makeNSView did
    spinRunLoop()
    expect("deferred grab before attach leaves nothing focused (precondition)",
           window.firstResponder !== view)
    window.contentView?.addSubview(view)
    spinRunLoop()
    expect("recorder is first responder after being attached late",
           window.firstResponder === view)
}

// The ordering that happened to work: attached first, then focus grabbed.
do {
    let window = makeWindow()
    let view = ShortcutCaptureNSView()
    window.contentView?.addSubview(view)
    DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    spinRunLoop()
    expect("recorder is first responder when attached early", window.firstResponder === view)
}

// Keystroke handling once focused.
do {
    let window = makeWindow()
    let view = ShortcutCaptureNSView()
    var captured: KeyboardShortcutModel?
    var cancelled = false
    view.onCapture = { captured = $0 }
    view.onCancel = { cancelled = true }
    window.contentView?.addSubview(view)
    spinRunLoop()

    view.keyDown(with: keyEvent(keyCode: 15, flags: [], in: window))
    expect("bare key is ignored", captured == nil)

    view.keyDown(with: keyEvent(keyCode: 15, flags: [.command, .shift], in: window))
    expect("⌘⇧R is captured",
           captured == KeyboardShortcutModel(keyCode: 15, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue))

    view.keyDown(with: keyEvent(keyCode: 53, flags: [], in: window))
    expect("Esc cancels", cancelled)
}

// Double-tapping a modifier records a double-tap shortcut.
do {
    let window = makeWindow()
    let view = ShortcutCaptureNSView()
    var captured: KeyboardShortcutModel?
    view.onCapture = { captured = $0 }
    window.contentView?.addSubview(view)
    spinRunLoop()

    func flags(_ f: NSEvent.ModifierFlags, at t: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: t,
            windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55
        )!
    }
    view.flagsChanged(with: flags(.command, at: 0.0))
    view.flagsChanged(with: flags([], at: 0.1))
    expect("single ⌘ tap records nothing", captured == nil)
    view.flagsChanged(with: flags(.command, at: 0.2))
    expect("⌘ ⌘ records a double-tap shortcut", captured == .doubleTap(.command))
}

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll passed")
