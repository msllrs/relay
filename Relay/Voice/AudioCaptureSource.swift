import AVFoundation
import CoreAudio
import Foundation

/// Delivers standardized microphone audio to a speech engine: 16 kHz mono
/// Float32 buffers plus an RMS level per buffer for the waveform.
///
/// Implementations: AUHALCaptureSource (default), AVAudioEngineCaptureSource
/// (legacy fallback, `defaults write com.msllrs.relay useLegacyAudioCapture -bool YES`).
protocol AudioCaptureSource: AnyObject, Sendable {
    /// Start capturing from the given device (`nil` = system default).
    /// Capturing from an explicit device never changes the system default.
    func start(
        deviceID: AudioDeviceID?,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws

    /// Move live capture to a new device (`nil` = system default) without
    /// dropping the consumer. Buffers keep flowing to the same callbacks.
    func switchDevice(to deviceID: AudioDeviceID?)

    func stop()
}

enum AudioCaptureSourceFactory {
    static func make() -> any AudioCaptureSource {
        if UserDefaults.standard.bool(forKey: "useLegacyAudioCapture") {
            return AVAudioEngineCaptureSource()
        }
        return AUHALCaptureSource()
    }
}

/// Converts arbitrary-format PCM buffers to 16 kHz mono Float32, rebuilding
/// the underlying converter whenever the input format changes (device switch,
/// voice-processing multichannel output). Not thread-safe: confine to the
/// capture source's processing queue.
final class PCM16kMonoConverter {
    static func makeTargetFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    }

    private let targetFormat = PCM16kMonoConverter.makeTargetFormat()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == targetFormat.sampleRate,
           buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        if converter == nil || inputFormat != buffer.format {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else { return nil }
            // Multichannel inputs (voice processing emits 3-7 channels) fold to channel 0.
            if buffer.format.channelCount > 1 {
                newConverter.channelMap = [0]
            }
            converter = newConverter
            inputFormat = buffer.format
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(max(1, (Double(buffer.frameLength) * ratio).rounded(.up) + 32))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // The input block runs synchronously inside convert(to:) on this thread;
        // the Sendable annotations on AVAudioConverterInputBlock are stricter
        // than the actual single-shot usage here.
        nonisolated(unsafe) var consumedInput = false
        nonisolated(unsafe) let inputBuffer = buffer
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return output.frameLength > 0 ? output : nil
        default:
            return nil
        }
    }

    static func makeBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: makeTargetFormat(), frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0] else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frames { sum += samples[i] * samples[i] }
        return sqrtf(sum / Float(frames))
    }
}
