import AVFoundation
import CoreAudio
import Foundation

#if canImport(FluidAudio)
import FluidAudio
#endif

/// Wrapper to shuttle AVAudioPCMBuffer across isolation boundaries.
/// The wrapped buffer must not be accessed from the sending context after wrapping.
private struct SendableBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// FluidAudio/Parakeet-based transcription engine with streaming support.
final class FluidAudioEngine: SpeechEngine, @unchecked Sendable {
    #if canImport(FluidAudio)
    private var loadedModels: AsrModels?
    private var streamingManager: StreamingAsrManager?
    #endif
    private var audioEngine: AVAudioEngine?
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

        // Set up our own AVAudioEngine to capture mic audio,
        // compute levels for the waveform, and feed buffers to FluidAudio.
        let engine = AVAudioEngine()
        self.audioEngine = engine

        if let deviceID = inputDeviceID {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        // Pass nil format to let Core Audio negotiate correctly (AirPods, device switching)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            guard self?.audioEngine != nil else { return }

            // Compute RMS for waveform visualisation
            if let channelData = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames { sum += channelData[i] * channelData[i] }
                let rms = sqrt(sum / max(Float(frames), 1))
                onAudioLevel(rms)
            }

            // Feed audio to FluidAudio for transcription.
            // Copy into a Sendable wrapper so it can cross the actor boundary.
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                for ch in 0..<Int(buffer.format.channelCount) {
                    dst[ch].update(from: src[ch], count: Int(buffer.frameLength))
                }
            }
            let wrapped = SendableBuffer(buffer: copy)
            Task { await streaming.streamAudio(wrapped.buffer) }
        }

        engine.prepare()
        try engine.start()
        #else
        throw SpeechEngineError.engineUnavailable
        #endif
    }

    func stopAndTranscribe() async throws -> String {
        #if canImport(FluidAudio)
        isStreamingFlag = false
        pollingTask?.cancel()
        pollingTask = nil

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
        isStreamingFlag = false
        pollingTask?.cancel()
        pollingTask = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil

        #if canImport(FluidAudio)
        await streamingManager?.cancel()
        streamingManager = nil
        #endif
    }
}
