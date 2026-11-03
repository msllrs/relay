import CoreGraphics
import Foundation

/// An active CGEvent tap scheduled on the main run loop. Owns the tap's mach
/// port and run-loop source so creating and tearing them down stays in one
/// place (see `RelayTests/event-tap-harness.swift`).
final class EventTap {
    private let port: CFMachPort
    private var source: CFRunLoopSource?

    /// Create, schedule, and enable a session-level tap at the head of the
    /// queue. Nil when the tap can't be created (no Accessibility access).
    init?(eventsOfInterest mask: CGEventMask, callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer?) {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) else { return nil }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Re-arm the tap after macOS disables it for stalling.
    func reenable() {
        guard source != nil else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Stop delivering events and release the tap from the window server,
    /// which otherwise keeps it registered (disabled) for the life of the
    /// process. Safe to call more than once.
    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = nil
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
    }

    deinit {
        stop()
    }
}
