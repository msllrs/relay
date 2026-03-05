import AVFoundation
import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// FluidAudio/Parakeet-based transcription engine.
final class FluidAudioEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(FluidAudio)
    private var asrManager: AsrManager?
    #endif
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var tempFileURL: URL?

    var isAvailable: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    var needsModelDownload: Bool {
        #if canImport(FluidAudio)
        return asrManager == nil
        #else
        return true
        #endif
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(FluidAudio)
        progress(0.1)
        let model = try await AsrModels.downloadAndLoad(version: .v3)
        asrManager = AsrManager(model: model)
        progress(1.0)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func startStreaming(onPartialResult: @escaping @Sendable (String) -> Void) async throws {
        #if canImport(FluidAudio)
        guard asrManager != nil else {
            throw SpeechEngineError.engineUnavailable
        }

        let engine = AVAudioEngine()
        self.audioEngine = engine

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        self.tempFileURL = tempURL

        let audioFile = try AVAudioFile(forWriting: tempURL, settings: recordingFormat.settings)
        self.audioFile = audioFile

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
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
        #if canImport(FluidAudio)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        audioFile = nil

        guard let asrManager, let tempURL = tempFileURL else {
            throw SpeechEngineError.transcriptionFailed("No recording available")
        }

        let audioData = try AudioConverter.loadAndConvert(url: tempURL)
        let result = try await asrManager.transcribe(audioData: audioData)

        try? FileManager.default.removeItem(at: tempURL)
        tempFileURL = nil

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }
}
