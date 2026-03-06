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

    var isAvailable: Bool {
        guard let recognizer = speechRecognizer else { return false }
        return recognizer.isAvailable
    }

    var needsModelDownload: Bool { false }

    init(locale: Locale = .current) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
    }

    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        progress(1.0)
    }

    func startStreaming(onPartialResult: @escaping @Sendable (String) -> Void) async throws {
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

        // Fresh engine each session so it picks up the current default input device
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Pass nil format to let Core Audio negotiate the correct format
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        try engine.start()

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

    func stopAndTranscribe() async throws -> String {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recognitionRequest?.endAudio()

        let current = transcription.withLock { $0 }

        if let task = recognitionTask, task.state == .running || task.state == .starting {
            let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                self.completionContinuation = continuation

                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.completionContinuation != nil else { return }
                    let fallback = self.transcription.withLock { $0 }
                    self.completionContinuation?.resume(returning: fallback)
                    self.completionContinuation = nil
                }
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
    case recordingFailed
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable:
            "Speech recognition is not available on this device."
        case .permissionDenied:
            "Speech recognition permission was denied. Enable it in System Settings > Privacy & Security."
        case .recordingFailed:
            "Failed to start audio recording."
        case .transcriptionFailed(let message):
            "Transcription failed: \(message)"
        }
    }
}
