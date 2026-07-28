import AVFoundation
import Foundation
import Speech
import Synchronization

/// Uses macOS built-in SFSpeechRecognizer for on-device transcription.
final class NativeSpeechEngine: SpeechEngine, @unchecked Sendable {
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var capture: (any AudioCaptureSource)?
    private let transcription = Mutex("")
    private var completionContinuation: CheckedContinuation<String, any Error>?

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
        transcription.withLock { $0 = "" }

        // Skip initial buffers to avoid hardware startup transients that
        // SFSpeechRecognizer can misinterpret as speech (e.g. "no").
        // Warm-capture pre-roll: audio from just before the hotkey landed.
        if let preRollBuffer = PCM16kMonoConverter.makeBuffer(from: PreRollAudioService.shared.drainPreRoll()) {
            request.append(preRollBuffer)
        }

        let buffersToSkip = Mutex(3)
        // SFSpeechAudioBufferRecognitionRequest isn't marked Sendable but append(_:)
        // is safe to call from the capture queue (it's fed from audio threads by design).
        struct SendableRequest: @unchecked Sendable { let request: SFSpeechAudioBufferRecognitionRequest }
        let sendableRequest = SendableRequest(request: request)
        let captureSource = AudioCaptureSourceFactory.make()
        self.capture = captureSource
        try captureSource.start(deviceID: inputDeviceID, onBuffer: { buffer in
            let skip = buffersToSkip.withLock { remaining -> Bool in
                if remaining > 0 {
                    remaining -= 1
                    return true
                }
                return false
            }
            if !skip {
                sendableRequest.request.append(buffer)
            }
        }, onLevel: onAudioLevel)

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

    /// Move capture to the new device, keeping the recognition request (and
    /// therefore the transcript so far) alive.
    func restartAudioCapture(inputDeviceID: AudioDeviceID?) async {
        guard recognitionRequest != nil else { return }
        capture?.switchDevice(to: inputDeviceID)
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
        capture?.stop()
        capture = nil
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
        capture?.stop()
        capture = nil
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
