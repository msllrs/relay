// Standalone test harness for WindowLocator (XCTest needs Xcode, which this
// machine doesn't have). Run with:
//   cat Relay/Services/WindowLocator.swift RelayTests/window-locator-harness.swift > /tmp/wl-test.swift && swift /tmp/wl-test.swift
// Exits non-zero on failure.

import CoreGraphics
import Foundation

var failures = 0
func check(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS \(name)")
    } else {
        print("FAIL \(name)")
        failures += 1
    }
}

let relayPID: pid_t = 100
// Front-to-back, global CG coords (top-left origin).
let windows = [
    OnScreenWindow(windowID: 1, ownerPID: relayPID, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900)), // Relay overlay
    OnScreenWindow(windowID: 2, ownerPID: 200, layer: 25, bounds: CGRect(x: 0, y: 0, width: 1440, height: 24)),       // menu bar
    OnScreenWindow(windowID: 3, ownerPID: 300, layer: 0, bounds: CGRect(x: 600, y: 100, width: 10, height: 10)),       // tiny helper
    OnScreenWindow(windowID: 4, ownerPID: 300, layer: 0, bounds: CGRect(x: 500, y: 50, width: 400, height: 300)),      // front app window
    OnScreenWindow(windowID: 5, ownerPID: 400, layer: 0, bounds: CGRect(x: 100, y: 40, width: 1000, height: 700)),     // window behind it
]

// MARK: topmostWindow

check("skips own PID, menu bar layer, and tiny windows",
      WindowLocator.topmostWindow(at: CGPoint(x: 605, y: 105), in: windows, excludingPID: relayPID)?.windowID == 4)
check("front window wins where windows overlap",
      WindowLocator.topmostWindow(at: CGPoint(x: 700, y: 200), in: windows, excludingPID: relayPID)?.windowID == 4)
check("falls through to the window behind outside the front one",
      WindowLocator.topmostWindow(at: CGPoint(x: 200, y: 200), in: windows, excludingPID: relayPID)?.windowID == 5)
check("nil over the bare desktop",
      WindowLocator.topmostWindow(at: CGPoint(x: 1300, y: 850), in: windows, excludingPID: relayPID) == nil)

// MARK: window(forStrokes:)

let mostlyInFront = [CGPoint(x: 450, y: 200)] + (0..<5).map { CGPoint(x: 600 + Double($0) * 10, y: 200) }
check("stroke votes pick the window holding most of the mark",
      WindowLocator.window(forStrokes: mostlyInFront, in: windows, excludingPID: relayPID)?.windowID == 4)
let tie = [CGPoint(x: 200, y: 200), CGPoint(x: 700, y: 200)]
check("ties go to the window the stroke reached first",
      WindowLocator.window(forStrokes: tie, in: windows, excludingPID: relayPID)?.windowID == 5)
check("no window under any point → nil",
      WindowLocator.window(forStrokes: [CGPoint(x: 1300, y: 850)], in: windows, excludingPID: relayPID) == nil)

// MARK: coordinate conversion

// Primary display 1440×900 at origin; a second 1920×1080 display to its right,
// bottom-aligned (AppKit frame origin (1440, 0)).
let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

check("screen-local → global on primary flips Y",
      WindowLocator.globalPoint(fromScreenLocal: CGPoint(x: 10, y: 890), screenFrame: primary, primaryHeight: 900) == CGPoint(x: 10, y: 10))
check("screen-local → global on secondary offsets X and goes above primary's top",
      WindowLocator.globalPoint(fromScreenLocal: CGPoint(x: 0, y: 1080), screenFrame: secondary, primaryHeight: 900) == CGPoint(x: 1440, y: -180))
check("AppKit global → CG global flips Y",
      WindowLocator.globalPoint(fromAppKit: CGPoint(x: 50, y: 800), primaryHeight: 900) == CGPoint(x: 50, y: 100))

check("window pixel rect on a 2× primary",
      WindowLocator.pixelRect(forWindowBounds: CGRect(x: 500, y: 50, width: 400, height: 300), screenFrame: primary, primaryHeight: 900, scale: 2)
        == CGRect(x: 1000, y: 100, width: 800, height: 600))
check("window pixel rect clipped to the screen edge",
      WindowLocator.pixelRect(forWindowBounds: CGRect(x: 1300, y: 800, width: 400, height: 300), screenFrame: primary, primaryHeight: 900, scale: 1)
        == CGRect(x: 1300, y: 800, width: 140, height: 100))
check("window on the secondary maps into its local pixels",
      WindowLocator.pixelRect(forWindowBounds: CGRect(x: 1540, y: -80, width: 200, height: 100), screenFrame: secondary, primaryHeight: 900, scale: 1)
        == CGRect(x: 100, y: 100, width: 200, height: 100))
check("window off this screen → nil",
      WindowLocator.pixelRect(forWindowBounds: CGRect(x: 1540, y: -80, width: 200, height: 100), screenFrame: primary, primaryHeight: 900, scale: 1) == nil)

// MARK: ring

let ring = WindowLocator.ring(around: CGPoint(x: 100, y: 100), radius: 10)
check("ring closes on itself", abs(ring.first!.x - ring.last!.x) < 0.001 && abs(ring.first!.y - ring.last!.y) < 0.001)
check("ring points sit on the radius", ring.allSatisfy { abs(hypot($0.x - 100, $0.y - 100) - 10) < 0.001 })

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All window locator checks passed")
