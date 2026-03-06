@preconcurrency import AVFoundation
import CoreAudio
import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// FluidAudio/Parakeet-based transcription engine with streaming support.
final class FluidAudioEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(FluidAudio)
    private var loadedModels: AsrModels?
    private var streamingManager: StreamingAsrManager?
    #endif
    private var audioEngine: AVAudioEngine?

    var isAvailable: Bool {
        #if canImport(FluidAudio)
        return true
        #else
        return false
        #endif
    }

    var needsModelDownload: Bool {
        #if canImport(FluidAudio)
        return loadedModels == nil
        #else
        return true
        #endif
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        #if canImport(FluidAudio)
        progress(0.05)
        let modelDir = try await AsrModels.download(version: .v3)
        progress(0.3)
        let models = try await AsrModels.load(from: modelDir, version: .v3)
        progress(0.9)
        loadedModels = models
        progress(1.0)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func startStreaming(inputDeviceID: AudioDeviceID?, onPartialResult: @escaping @Sendable (String) -> Void) async throws {
        #if canImport(FluidAudio)
        guard let models = loadedModels else {
            throw SpeechEngineError.engineUnavailable
        }

        let streaming = StreamingAsrManager(config: .default)
        self.streamingManager = streaming

        // StreamingAsrManager handles mic capture internally with .microphone source
        try await streaming.start(models: models, source: .microphone)

        // Get the update stream while in actor context, then iterate outside
        let updates = await streaming.transcriptionUpdates
        Task {
            var confirmedText = ""
            for await update in updates {
                if update.isConfirmed {
                    confirmedText += (confirmedText.isEmpty ? "" : " ") + update.text
                    onPartialResult(confirmedText)
                } else {
                    let display = confirmedText.isEmpty
                        ? update.text
                        : confirmedText + " " + update.text
                    onPartialResult(display)
                }
            }
        }
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func stopAndTranscribe() async throws -> String {
        #if canImport(FluidAudio)
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        guard let streaming = streamingManager else {
            throw SpeechEngineError.transcriptionFailed("No recording available")
        }

        let finalText = try await streaming.finish()
        streamingManager = nil

        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func cancel() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        #if canImport(FluidAudio)
        await streamingManager?.cancel()
        streamingManager = nil
        #endif
    }
}
