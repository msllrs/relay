import AVFoundation
import CoreAudio
import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// WhisperKit-based transcription engine.
final class WhisperKitEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

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

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(WhisperKit)
        progress(0.1)
        whisperKit = try await WhisperKit(model: "base.en")
        progress(1.0)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func startStreaming(inputDeviceID: AudioDeviceID?, onPartialResult: @escaping @Sendable (String) -> Void) async throws {
        #if canImport(WhisperKit)
        guard whisperKit != nil else {
            throw SpeechEngineError.engineUnavailable
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        if let deviceID = inputDeviceID {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        let recordingFormat = engine.validInputFormat()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        self.tempFileURL = tempURL

        let audioFile = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)
        self.audioFile = audioFile

        // Pass nil format to let Core Audio negotiate correctly
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            try? audioFile.write(from: buffer)
        }

        engine.prepare()
        try engine.start()

        onPartialResult("[Recording... transcription will appear when you stop]")
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func stopAndTranscribe() async throws -> String {
        #if canImport(WhisperKit)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioFile = nil

        guard let whisperKit, let tempURL = tempFileURL else {
            throw SpeechEngineError.transcriptionFailed("No recording available")
        }

        let results: [TranscriptionResult] = try await whisperKit.transcribe(audioPath: tempURL.path)
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        try? FileManager.default.removeItem(at: tempURL)
        tempFileURL = nil

        return text
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func cancel() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioFile = nil

        if let tempURL = tempFileURL {
            try? FileManager.default.removeItem(at: tempURL)
            tempFileURL = nil
        }
    }
}
