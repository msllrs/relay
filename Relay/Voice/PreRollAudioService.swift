import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Opt-in warm capture: keeps a capture source running while idle, holding the
/// last second of audio in a ring buffer so a new recording can prepend ~0.45s
/// from before the hotkey landed — the first word is never clipped.
///
/// Runs its own capture unit alongside the recording session's, so engines
/// stay untouched apart from draining the ring at session start. Suspended
/// during screen lock and system sleep (nobody dictates at a locked screen,
/// and warm engines held across sleep are exactly how audio graphs go stale).
///
/// Note: while enabled, macOS shows the mic-in-use indicator permanently —
/// which is why this is off by default.
final class PreRollAudioService: @unchecked Sendable {
    static let shared = PreRollAudioService()

    static let preRollDuration: TimeInterval = 0.45
    private static let ringDuration: TimeInterval = 1.0
    private static let sampleRate = 16_000

    private struct State {
        var enabled = false
        var suspended = false
        var deviceID: AudioDeviceID?
        var ring: [Float] = []
    }

    private let state = Mutex(State())
    private var capture: (any AudioCaptureSource)?
    private var startRetry: DispatchWorkItem?
    private let controlQueue = DispatchQueue(label: "com.msllrs.relay.preroll-control")
    private var observers: [NSObjectProtocol] = []

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setSuspended(true)
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setSuspended(false)
        })
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setSuspended(true)
        })
        observers.append(distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.setSuspended(false)
        })
    }

    // MARK: - Control

    func setEnabled(_ enabled: Bool, deviceID: AudioDeviceID?) {
        state.withLock {
            $0.enabled = enabled
            $0.deviceID = deviceID
        }
        reconcile()
    }

    /// The preferred input device changed (selection or system default).
    func deviceChanged(to deviceID: AudioDeviceID?) {
        let wasEnabled = state.withLock { s -> Bool in
            s.deviceID = deviceID
            return s.enabled
        }
        guard wasEnabled else { return }
        reconcile(forceRestart: true)
    }

    private func setSuspended(_ suspended: Bool) {
        state.withLock { $0.suspended = suspended }
        reconcile()
    }

    /// Start or stop the warm capture to match (enabled && !suspended).
    private func reconcile(forceRestart: Bool = false) {
        controlQueue.async { [self] in
            startRetry?.cancel()
            startRetry = nil
            let (shouldRun, deviceID) = state.withLock { ($0.enabled && !$0.suspended, $0.deviceID) }

            if !shouldRun {
                stopCapture()
                return
            }
            if forceRestart {
                stopCapture()
            }
            guard capture == nil else { return }
            startCapture(deviceID: deviceID, isRetry: false)
        }
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        state.withLock { $0.ring.removeAll() }
    }

    private func startCapture(deviceID: AudioDeviceID?, isRetry: Bool) {
        let source = AudioCaptureSourceFactory.make()
        do {
            try source.start(deviceID: deviceID, onBuffer: { [weak self] buffer in
                self?.append(buffer)
            }, onLevel: { _ in })
            capture = source
        } catch {
            if isRetry {
                NSLog("PreRollAudioService: warm capture retry failed, giving up: %@", error.localizedDescription)
                return
            }
            NSLog("PreRollAudioService: warm capture failed to start: %@", error.localizedDescription)
            let work = DispatchWorkItem { [self] in
                startRetry = nil
                let (shouldRun, deviceID) = state.withLock { ($0.enabled && !$0.suspended, $0.deviceID) }
                guard shouldRun, capture == nil else { return }
                startCapture(deviceID: deviceID, isRetry: true)
            }
            startRetry = work
            controlQueue.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    // MARK: - Ring

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        let capacity = Int(Self.ringDuration * Double(Self.sampleRate))
        state.withLock { s in
            s.ring.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            if s.ring.count > capacity {
                s.ring.removeFirst(s.ring.count - capacity)
            }
        }
    }

    /// Take the most recent pre-roll window and clear the ring. Called by
    /// engines at session start, before their own capture spins up — the
    /// ~100ms of unit startup after the drain is the one window pre-roll
    /// can't cover with a separate warm unit.
    func drainPreRoll() -> [Float] {
        let want = Int(Self.preRollDuration * Double(Self.sampleRate))
        return state.withLock { s in
            defer { s.ring.removeAll() }
            guard !s.ring.isEmpty else { return [] }
            return Array(s.ring.suffix(want))
        }
    }
}
