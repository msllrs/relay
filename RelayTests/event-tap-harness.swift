// Standalone test harness for EventTap (XCTest needs Xcode, which this
// machine doesn't have). Run with:
//   cat Relay/Services/EventTap.swift RelayTests/event-tap-harness.swift > /tmp/et-test.swift && swift /tmp/et-test.swift
// Exits non-zero on failure.
//
// Counts this process's taps in the window server's tap list, so it checks
// what macOS actually still holds, not just what EventTap thinks. Uses a
// mouse-moved tap: the create/teardown path is the same as the Esc keyDown
// tap, without needing Accessibility access to run.

import CoreGraphics
import Foundation

var failures = 0
func check(_ name: String, _ actual: Int, _ expected: Int) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        print("FAIL \(name): expected \(expected), got \(actual)")
        failures += 1
    }
}

/// Taps registered by this process, enabled or not.
func registeredTaps() -> Int {
    var count: UInt32 = 0
    CGGetEventTapList(0, nil, &count)
    var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    CGGetEventTapList(count, &taps, &count)
    return taps.prefix(Int(count)).filter { $0.tappingProcess == getpid() }.count
}

let passThrough: CGEventTapCallBack = { _, _, event, _ in Unmanaged.passUnretained(event) }
let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)

let baseline = registeredTaps()

guard let tap = EventTap(eventsOfInterest: mask, callback: passThrough, userInfo: nil) else {
    print("FAIL could not create a tap")
    exit(1)
}
check("creating a tap registers it", registeredTaps(), baseline + 1)
tap.stop()
check("stopping a tap unregisters it", registeredTaps(), baseline)
tap.stop()
check("stopping twice is harmless", registeredTaps(), baseline)
tap.reenable()
check("re-enabling a stopped tap doesn't bring it back", registeredTaps(), baseline)

// One Esc tap per recording: many sessions must not pile up taps.
for _ in 0..<10 {
    EventTap(eventsOfInterest: mask, callback: passThrough, userInfo: nil)?.stop()
}
check("ten start/stop cycles leave no taps behind", registeredTaps(), baseline)

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All event tap checks passed")
