// Standalone test harness for ModifierDoubleTapDetector (XCTest needs Xcode,
// which this machine doesn't have). Run with:
//   cat Relay/Services/ModifierDoubleTapDetector.swift RelayTests/double-tap-detector-harness.swift \
//       > /tmp/dt-test.swift && swift /tmp/dt-test.swift
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

typealias Flags = NSEvent.ModifierFlags
let none = Flags([])

/// Drive a detector through a sequence of (flags, time) and return every fire.
func run(_ detector: inout ModifierDoubleTapDetector, _ steps: [(Flags, TimeInterval)]) -> [Flags] {
    steps.compactMap { detector.flagsChanged($0.0, at: $0.1) }
}

// The headline case: ⌘ down, up, down within the window fires on the second press.
do {
    var d = ModifierDoubleTapDetector(modifier: .command)
    let fires = run(&d, [(.command, 0.00), (none, 0.10), (.command, 0.25)])
    expect("⌘ ⌘ within window fires once, on the second press", fires == [.command])
    expect("second release does not fire again", d.flagsChanged(none, at: 0.30) == nil)
}

// Too slow: second press after the window is a new first tap, not a fire.
do {
    var d = ModifierDoubleTapDetector(modifier: .command)
    let fires = run(&d, [(.command, 0.0), (none, 0.1), (.command, 0.1 + ModifierDoubleTapDetector.window + 0.01)])
    expect("second press after the window does not fire", fires.isEmpty)
    let later = run(&d, [(none, 0.6), (.command, 0.7)])
    expect("…but it starts a fresh sequence that can complete", later == [.command])
}

// A chord in between (⌘C) must not count: ⌘ down, C down, ⌘ up, ⌘ down.
do {
    var d = ModifierDoubleTapDetector(modifier: .command)
    _ = d.flagsChanged(.command, at: 0.0)
    d.keyDown() // C
    let fires = run(&d, [(none, 0.1), (.command, 0.2)])
    expect("⌘C then ⌘ does not fire", fires.isEmpty)
}

// Two modifiers held together is a chord, not a tap.
do {
    var d = ModifierDoubleTapDetector(modifier: .command)
    let fires = run(&d, [(.command, 0.0), ([.command, .shift], 0.05), (.command, 0.1), (none, 0.15), (.command, 0.2)])
    expect("⌘ joined by ⇧ resets; the following ⌘ is only a first tap", fires.isEmpty)
}

// Restricted detector ignores other modifiers entirely.
do {
    var d = ModifierDoubleTapDetector(modifier: .command)
    let fires = run(&d, [(.option, 0.0), (none, 0.1), (.option, 0.2)])
    expect("⌥ ⌥ does not fire a ⌘ detector", fires.isEmpty)
}

// Unrestricted detector (the recorder) reports whichever modifier was tapped.
do {
    var d = ModifierDoubleTapDetector()
    expect("recorder detects ⌥ ⌥", run(&d, [(.option, 0.0), (none, 0.1), (.option, 0.2)]) == [.option])
    expect("recorder detects ⌃ ⌃", run(&d, [(.control, 1.0), (none, 1.1), (.control, 1.2)]) == [.control])
    expect("recorder detects fn fn", run(&d, [(.function, 2.0), (none, 2.1), (.function, 2.2)]) == [.function])
}

// Switching modifiers mid-sequence: ⌘ then ⌥ is not a double tap of either.
do {
    var d = ModifierDoubleTapDetector()
    let fires = run(&d, [(.command, 0.0), (none, 0.1), (.option, 0.2)])
    expect("⌘ then ⌥ does not fire", fires.isEmpty)
    expect("…and ⌥ became the new first tap", run(&d, [(none, 0.3), (.option, 0.4)]) == [.option])
}

// Device-dependent bits (left/right key, caps lock) must not confuse it.
do {
    var d = ModifierDoubleTapDetector(modifier: .command)
    let leftCmd = Flags(rawValue: Flags.command.rawValue | 0x8)   // NX_DEVICELCMDKEYMASK
    let rightCmd = Flags(rawValue: Flags.command.rawValue | 0x10) // NX_DEVICERCMDKEYMASK
    let fires = run(&d, [(leftCmd, 0.0), (none, 0.1), (rightCmd, 0.2)])
    expect("left ⌘ then right ⌘ counts as ⌘ ⌘", fires == [.command])
}

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll passed")
