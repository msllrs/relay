import AVFoundation
import CoreAudio
import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// WhisperKit-based transcription engine.
/// Uses our own AVAudioEngine for mic capture (bypassing WhisperKit's AudioStreamTranscriber
/// which crashes on macOS 26 due to a bug in AVAudioApplication.requestRecordPermission
/// when called from an actor context).
final class WhisperKitEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif
    private var audioEngine: AVAudioEngine?
    /// Accumulated 16 kHz mono float samples for transcription.
    private var audioSamples: [Float] = []
    private var isRecordingFlag = false
    private var transcriptionTask: Task<Void, Never>?

    var isAvailable: Bool {
        #if canImport(WhisperKit)
        return true
        #else
        return false
        #endif
    }

    var needsModelDownload: Bool {
        #if canImport(WhisperKit)
        return whisperKit == nil
        #else
        return true
        #endif
    }

    var handlesPermissionInternally: Bool { false }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(WhisperKit)
        progress(0.1)
        whisperKit = try await WhisperKit(model: "base.en", load: true)
        progress(1.0)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func startStreaming(inputDeviceID: AudioDeviceID?, onPartialResult: @escaping @Sendable (String) -> Void, onAudioLevel: @escaping @Sendable (Float) -> Void) async throws {
        #if canImport(WhisperKit)
        guard let whisperKit else {
            throw SpeechEngineError.engineUnavailable
        }

        audioSamples = []
        isRecordingFlag = true

        // Set up our own AVAudioEngine to capture mic audio
        let engine = AVAudioEngine()
        self.audioEngine = engine

        if let deviceID = inputDeviceID {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        let hardwareRate = engine.inputNode.inputFormat(forBus: 0).sampleRate
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)

        // Create converter to 16kHz mono (what WhisperKit expects)
        guard let nodeFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat,
            sampleRate: hardwareRate,
            channels: inputFormat.channelCount,
            interleaved: inputFormat.isInterleaved
        ) else {
            throw SpeechEngineError.recordingFailed
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw SpeechEngineError.recordingFailed
        }

        guard let converter = AVAudioConverter(from: nodeFormat, to: targetFormat) else {
            throw SpeechEngineError.recordingFailed
        }

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nodeFormat) { [weak self] buffer, _ in
            guard let self, self.isRecordingFlag else { return }

            // Compute RMS for waveform
            if let channelData = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames { sum += channelData[i] * channelData[i] }
                let rms = sqrt(sum / max(Float(frames), 1))
                onAudioLevel(rms)
            }

            // Resample to 16kHz mono
            let ratio = 16000.0 / hardwareRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

            var error: NSError?
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if let floats = outputBuffer.floatChannelData?[0] {
                let count = Int(outputBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: floats, count: count))
                self.audioSamples.append(contentsOf: samples)
            }
        }

        engine.prepare()
        try engine.start()

        // Periodic transcription loop in background
        let kit = whisperKit
        transcriptionTask = Task.detached { [weak self] in
            let options = DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
            while self?.isRecordingFlag == true {
                try? await Task.sleep(nanoseconds: 1_500_000_000) // every 1.5s
                guard let self = self, self.isRecordingFlag else { break }

                let currentSamples = self.audioSamples
                guard Float(currentSamples.count) / 16000.0 > 1.0 else { continue }

                let results: [TranscriptionResult]? = try? await kit.transcribe(
                    audioArray: currentSamples,
                    decodeOptions: options
                )
                if let results {
                    let text = results.flatMap(\.segments).map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        onPartialResult(text)
                    }
                }
            }
        }
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func stopAndTranscribe() async throws -> String {
        #if canImport(WhisperKit)
        isRecordingFlag = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        guard let whisperKit else {
            throw SpeechEngineError.transcriptionFailed("No recording available")
        }

        let samples = audioSamples
        audioSamples = []

        guard !samples.isEmpty else {
            return ""
        }

        let options = DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioArray: samples,
            decodeOptions: options
        )
        return results.flatMap(\.segments).map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func cancel() async {
        isRecordingFlag = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioSamples = []
    }
}
