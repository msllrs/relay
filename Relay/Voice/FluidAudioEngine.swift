import AVFoundation
import CoreAudio
import Foundation
import Synchronization

#if canImport(FluidAudio)
import FluidAudio
#endif

/// FluidAudio/Parakeet-based transcription engine with streaming support.
final class FluidAudioEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(FluidAudio)
    private var loadedModels: AsrModels?
    private var streamingManager: StreamingAsrManager?
    /// CTC keyword-spotter models backing vocabulary boosting; cached across sessions.
    private var ctcModels: CtcModels?
    #endif
    private var capture: (any AudioCaptureSource)?
    private var isStreamingFlag = false
    private var pollingTask: Task<Void, Never>?
    /// 16 kHz samples streamed this session, for short-clip padding.
    private let streamedSamples = Mutex(0)

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
        await configureVocabularyBoostingIfPossible(streaming)

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

        streamedSamples.withLock { $0 = 0 }

        // Warm-capture pre-roll: audio from just before the hotkey landed.
        let preRoll = PreRollAudioService.shared.drainPreRoll()
        if let preRollBuffer = PCM16kMonoConverter.makeBuffer(from: preRoll) {
            streamedSamples.withLock { $0 += preRoll.count }
            await streaming.streamAudio(preRollBuffer)
        }

        let captureSource = AudioCaptureSourceFactory.make()
        self.capture = captureSource
        try captureSource.start(deviceID: inputDeviceID, onBuffer: { [weak self] buffer in
            guard let self, self.isStreamingFlag else { return }
            self.streamedSamples.withLock { $0 += Int(buffer.frameLength) }
            let wrapped = UncheckedSendableBuffer(buffer: buffer)
            Task { await streaming.streamAudio(wrapped.buffer) }
        }, onLevel: onAudioLevel)
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    #if canImport(FluidAudio)
    /// Bias recognition toward the user's vocabulary terms. The CTC spotter
    /// models are an extra download: boost immediately when they're cached,
    /// otherwise fetch them in the background so the next session has them —
    /// never block a recording start on a download.
    private func configureVocabularyBoostingIfPossible(_ streaming: StreamingAsrManager) async {
        let terms = VocabularyStore.load()
        guard !terms.isEmpty else { return }

        if ctcModels == nil {
            guard CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory()) else {
                NSLog("FluidAudioEngine: vocabulary boost models not cached; downloading for next session")
                Task.detached(priority: .utility) {
                    _ = try? await CtcModels.download()
                }
                return
            }
            ctcModels = try? await CtcModels.downloadAndLoad()
        }
        guard let ctcModels else { return }

        do {
            let vocabulary = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            try await streaming.configureVocabularyBoosting(vocabulary: vocabulary, ctcModels: ctcModels)
        } catch {
            NSLog("FluidAudioEngine: vocabulary boosting failed: %@", error.localizedDescription)
        }
    }
    #endif

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

        // Parakeet's TDT decoder produces empty or junk output on clips shorter
        // than its 1.5s chunk window — exactly what a quick tap-to-talk yields.
        // Pad with trailing silence up to the minimum before finishing.
        let minimumSamples = 24_000 // 1.5s at 16 kHz
        let streamed = streamedSamples.withLock { $0 }
        if streamed > 0, streamed < minimumSamples {
            let padFrames = AVAudioFrameCount(minimumSamples - streamed)
            if let silence = AVAudioPCMBuffer(pcmFormat: PCM16kMonoConverter.makeTargetFormat(), frameCapacity: padFrames),
               let data = silence.floatChannelData?[0] {
                data.initialize(repeating: 0, count: Int(padFrames))
                silence.frameLength = padFrames
                await streaming.streamAudio(silence)
            }
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
