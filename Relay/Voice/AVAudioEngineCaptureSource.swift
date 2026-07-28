import AVFoundation
import CoreAudio
import Foundation

/// Legacy capture path: a fresh AVAudioEngine per session with a native-format
/// tap, converted to 16 kHz mono on a serial queue. Kept as an escape hatch
/// while AUHALCaptureSource soaks (`defaults write com.msllrs.relay
/// useLegacyAudioCapture -bool YES`).
final class AVAudioEngineCaptureSource: AudioCaptureSource, @unchecked Sendable {
    private let controlQueue = DispatchQueue(label: "com.msllrs.relay.avengine-control")
    private let processingQueue = DispatchQueue(label: "com.msllrs.relay.avengine-processing")

    // Control-queue-guarded state.
    private var engine: AVAudioEngine?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?

    /// Confined to processingQueue.
    private let monoConverter = PCM16kMonoConverter()

    func start(
        deviceID: AudioDeviceID?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        try controlQueue.sync {
            stopLocked()
            self.onBuffer = onBuffer
            self.onLevel = onLevel
            try startEngineLocked(deviceID: deviceID)
        }
    }

    func switchDevice(to deviceID: AudioDeviceID?) {
        controlQueue.sync {
            guard engine != nil else { return }
            stopEngineLocked()
            try? startEngineLocked(deviceID: deviceID)
        }
    }

    func stop() {
        controlQueue.sync {
            stopLocked()
        }
    }

    private func startEngineLocked(deviceID: AudioDeviceID?) throws {
        // AVAudioEngine must be created fresh each session: a persistent engine
        // ends up with a stale audio graph that delivers zeroed buffers.
        let engine = AVAudioEngine()
        self.engine = engine

        if let deviceID {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        // Pass nil format so Core Audio negotiates correctly (AirPods, device switching).
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
                }
            }
            let wrapped = UncheckedSendableBuffer(buffer: copy)
            self.processingQueue.async {
                guard let converted = self.monoConverter.convert(wrapped.buffer) else { return }
                self.onLevel?(PCM16kMonoConverter.rms(of: converted))
                self.onBuffer?(converted)
            }
        }

        engine.prepare()
        try engine.start()
    }

    private func stopEngineLocked() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    private func stopLocked() {
        stopEngineLocked()
        processingQueue.sync {} // drain pending deliveries
        onBuffer = nil
        onLevel = nil
    }
}
