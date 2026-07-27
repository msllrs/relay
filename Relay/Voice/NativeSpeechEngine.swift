import AVFoundation
import Foundation
import Speech
import Synchronization

/// Uses macOS built-in SFSpeechRecognizer + AVAudioEngine for on-device transcription.
final class NativeSpeechEngine: SpeechEngine, @unchecked Sendable {
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private let transcription = Mutex("")
    private var completionContinuation: CheckedContinuation<String, any Error>?
    /// Kept for mid-session capture restarts on device changes.
    private var onAudioLevel: (@Sendable (Float) -> Void)?

    var isAvailable: Bool {
        guard let recognizer = speechRecognizer else { return false }
        return recognizer.isAvailable
    }

    var needsModelDownload: Bool { false }
    var handlesPermissionInternally: Bool { true } // SFSpeechRecognizer handles both speech + mic permissions

    init(locale: Locale = .current) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1.0)
    }

    func startStreaming(inputDeviceID: AudioDeviceID?, onPartialResult: @escaping @Sendable (String) -> Void, onAudioLevel: @escaping @Sendable (Float) -> Void) async throws {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            throw SpeechEngineError.engineUnavailable
        }

        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard status == .authorized else {
            throw SpeechEngineError.permissionDenied
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            throw SpeechEngineError.permissionDenied
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true

        self.recognitionRequest = request
        self.onAudioLevel = onAudioLevel
        transcription.withLock { $0 = "" }

        try startAudioCapture(inputDeviceID: inputDeviceID, request: request, onAudioLevel: onAudioLevel)

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.transcription.withLock { $0 = text }
                onPartialResult(text)

                if result.isFinal {
                    self.completionContinuation?.resume(returning: text)
                    self.completionContinuation = nil
                }
            }
            if let error, self.completionContinuation != nil {
                let current = self.transcription.withLock { $0 }
                if current.isEmpty {
                    self.completionContinuation?.resume(throwing: SpeechEngineError.transcriptionFailed(error.localizedDescription))
                } else {
                    self.completionContinuation?.resume(returning: current)
                }
                self.completionContinuation = nil
            }
        }
    }

    /// Build a fresh AVAudioEngine and tap feeding the given recognition request.
    /// Fresh engine each (re)start so it binds the current default input device.
    private func startAudioCapture(inputDeviceID: AudioDeviceID?, request: SFSpeechAudioBufferRecognitionRequest, onAudioLevel: @escaping @Sendable (Float) -> Void) throws {
        let engine = AVAudioEngine()
        self.audioEngine = engine

        if let deviceID = inputDeviceID {
            AudioDeviceManager.setInputDevice(deviceID, on: engine)
        }

        // Pass nil format to let Core Audio negotiate the correct format.
        // Skip initial buffers to avoid hardware startup transients that
        // SFSpeechRecognizer can misinterpret as speech (e.g. "no").
        var buffersToSkip = 3
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            if buffersToSkip > 0 {
                buffersToSkip -= 1
            } else {
                request.append(buffer)
            }

            // Compute RMS for audio level metering
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return }
            let samples = channelData[0]
            var sum: Float = 0
            for i in 0..<frames {
                let s = samples[i]
                sum += s * s
            }
            let rms = sqrtf(sum / Float(frames))
            onAudioLevel(rms)
        }

        engine.prepare()
        try engine.start()
    }

    /// Rebuild the audio engine on the new device, keeping the recognition
    /// request (and therefore the transcript so far) alive.
    func restartAudioCapture(inputDeviceID: AudioDeviceID?) async {
        guard let request = recognitionRequest, let onAudioLevel else { return }
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        try? startAudioCapture(inputDeviceID: inputDeviceID, request: request, onAudioLevel: onAudioLevel)
    }

    /// Poll until the deadline; resolve with the latest partial only if the
    /// recognizer still hasn't delivered a final result by then.
    private func armFallback(deadline: Date) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.completionContinuation != nil else { return }
            if Date() >= deadline {
                let fallback = self.transcription.withLock { $0 }
                self.completionContinuation?.resume(returning: fallback)
                self.completionContinuation = nil
            } else {
                self.armFallback(deadline: deadline)
            }
        }
    }

    func stopAndTranscribe() async throws -> String {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()

        let current = transcription.withLock { $0 }

        if let task = recognitionTask, task.state == .running || task.state == .starting {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                self.completionContinuation = continuation

                // Hang guard, not a deadline: the recognizer's final result
                // routinely contains last words that never appeared in any
                // partial, so bailing early silently chops the tail. 10s is
                // long enough for slow finalization (long dictations, cold
                // model) while still recovering from a genuinely hung task.
                armFallback(deadline: Date().addingTimeInterval(10))
            }

            recognitionTask?.cancel()
            recognitionTask = nil
            recognitionRequest = nil
            return result
        }

        recognitionTask = nil
        recognitionRequest = nil
        return current
    }

    func cancel() async {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        transcription.withLock { $0 = "" }
        if let continuation = completionContinuation {
            continuation.resume(returning: "")
            completionContinuation = nil
        }
    }
}

enum SpeechEngineError: LocalizedError {
    case engineUnavailable
    case permissionDenied
    case microphonePermissionDenied
    case recordingFailed
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            "Speech recognition is not available on this device."
        case .permissionDenied:
            "Speech recognition permission was denied. Enable it in System Settings > Privacy & Security."
        case .microphonePermissionDenied:
            "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .recordingFailed:
            "Failed to start audio recording."
        case .transcriptionFailed(let message):
            "Transcription failed: \(message)"
        }
    }
}
