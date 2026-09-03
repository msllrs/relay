// Standalone test harness for KeyboardShortcutModel (XCTest needs Xcode, which
// this machine doesn't have). Run with:
//   cat Relay/Models/KeyboardShortcutModel.swift Relay/Services/ModifierDoubleTapDetector.swift \
//       RelayTests/keyboard-shortcut-model-harness.swift > /tmp/ksm-test.swift && swift /tmp/ksm-test.swift
// Exits non-zero on failure.

import AppKit

var failures = 0
func expect(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)")
        failures += 1
    }
}

// Shortcuts saved before double-tap support have no isDoubleTap key and must
// still decode as chords. 1179648 = ⌘ (1<<20) + ⇧ (1<<17).
do {
    let legacy = Data(#"{"keyCode":15,"modifiers":1179648}"#.utf8)
    let decoded = try? JSONDecoder().decode(KeyboardShortcutModel.self, from: legacy)
    expect("legacy JSON decodes", decoded != nil)
    expect("legacy JSON is a chord", decoded?.isDoubleTap == false)
    expect("legacy JSON equals the default ⌘⇧R", decoded == .default)
}

// Round trip a double-tap.
do {
    let tap = KeyboardShortcutModel.doubleTap(.command)
    let data = try! JSONEncoder().encode(tap)
    let back = try! JSONDecoder().decode(KeyboardShortcutModel.self, from: data)
    expect("double-tap round-trips", back == tap)
    expect("double-tap exposes its modifier", back.doubleTapModifier == .command)
    expect("chord has no double-tap modifier", KeyboardShortcutModel.default.doubleTapModifier == nil)
}

// Display strings.
do {
    expect("chord displays ⇧⌘R", KeyboardShortcutModel.default.displayString == "\u{21E7}\u{2318}R")
    expect("⌘ double-tap displays ⌘⌘", KeyboardShortcutModel.doubleTap(.command).displayString == "\u{2318}\u{2318}")
    expect("fn double-tap displays fn fn", KeyboardShortcutModel.doubleTap(.function).displayString == "fn fn")
    expect("chord prompt", KeyboardShortcutModel.default.startPrompt == "Press \u{21E7}\u{2318}R")
    expect("double-tap prompt", KeyboardShortcutModel.doubleTap(.option).startPrompt == "Double-tap \u{2325}")
}

// A double-tap and a chord on the same modifier are distinct shortcuts.
do {
    let chord = KeyboardShortcutModel(keyCode: 0, modifiers: NSEvent.ModifierFlags.command.rawValue)
    expect("⌘A chord ≠ ⌘⌘", chord != KeyboardShortcutModel.doubleTap(.command))
}

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll passed")
