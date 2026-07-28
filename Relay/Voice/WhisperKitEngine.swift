import AVFoundation
import CoreAudio
import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// WhisperKit-based transcription engine.
/// Uses our own capture source for mic audio (bypassing WhisperKit's AudioStreamTranscriber
/// which crashes on macOS 26 due to a bug in AVAudioApplication.requestRecordPermission
/// when called from an actor context).
final class WhisperKitEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif
    private var capture: (any AudioCaptureSource)?
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

        let capture = AudioCaptureSourceFactory.make()
        self.capture = capture
        try capture.start(deviceID: inputDeviceID, onBuffer: { [weak self] buffer in
            guard let self, self.isRecordingFlag else { return }
            if let floats = buffer.floatChannelData?[0] {
                let count = Int(buffer.frameLength)
                self.audioSamples.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            }
        }, onLevel: onAudioLevel)

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

    /// Move capture to the new device; accumulated samples and the
    /// transcription loop carry on untouched.
    func restartAudioCapture(inputDeviceID: AudioDeviceID?) async {
        guard isRecordingFlag else { return }
        capture?.switchDevice(to: inputDeviceID)
    }

    func stopAndTranscribe() async throws -> String {
        #if canImport(WhisperKit)
        isRecordingFlag = false
        transcriptionTask?.cancel()
        transcriptionTask = nil

        capture?.stop()
        capture = nil

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
        capture?.stop()
        capture = nil
        audioSamples = []
    }
}
