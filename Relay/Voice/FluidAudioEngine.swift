import AVFoundation
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
    private var capture: (any AudioCaptureSource)?
    private var isStreamingFlag = false
    private var pollingTask: Task<Void, Never>?

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

    var handlesPermissionInternally: Bool { false }

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

    func startStreaming(inputDeviceID: AudioDeviceID?, onPartialResult: @escaping @Sendable (String) -> Void, onAudioLevel: @escaping @Sendable (Float) -> Void) async throws {
        #if canImport(FluidAudio)
        guard let models = loadedModels else {
            throw SpeechEngineError.engineUnavailable
        }

        let streaming = StreamingAsrManager(config: .streaming)
        self.streamingManager = streaming
        self.isStreamingFlag = true

        try await streaming.start(models: models, source: .microphone)

        // Poll the actor's transcript properties for updates (more reliable than
        // AsyncStream which can silently drop the continuation across actor hops).
        let manager = streaming
        pollingTask = Task.detached { [weak self] in
            var lastText = ""
            while self?.isStreamingFlag == true {
                try? await Task.sleep(nanoseconds: 500_000_000) // every 0.5s
                guard let self, self.isStreamingFlag else { break }

                let confirmed = await manager.confirmedTranscript
                let volatile = await manager.volatileTranscript
                var text = confirmed
                if !volatile.isEmpty {
                    text += (text.isEmpty ? "" : " ") + volatile
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && text != lastText {
                    lastText = text
                    onPartialResult(text)
                }
            }
        }

        let captureSource = AudioCaptureSourceFactory.make()
        self.capture = captureSource
        try captureSource.start(deviceID: inputDeviceID, onBuffer: { [weak self] buffer in
            guard let self, self.isStreamingFlag else { return }
            let wrapped = UncheckedSendableBuffer(buffer: buffer)
            Task { await streaming.streamAudio(wrapped.buffer) }
        }, onLevel: onAudioLevel)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    /// Move capture to the new device; the streaming manager and its
    /// transcript carry on untouched.
    func restartAudioCapture(inputDeviceID: AudioDeviceID?) async {
        guard isStreamingFlag else { return }
        capture?.switchDevice(to: inputDeviceID)
    }

    func stopAndTranscribe() async throws -> String {
        #if canImport(FluidAudio)
        isStreamingFlag = false
        pollingTask?.cancel()
        pollingTask = nil

        capture?.stop()
        capture = nil

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
        isStreamingFlag = false
        pollingTask?.cancel()
        pollingTask = nil

        capture?.stop()
        capture = nil

        #if canImport(FluidAudio)
        await streamingManager?.cancel()
        streamingManager = nil
        #endif
    }
}
