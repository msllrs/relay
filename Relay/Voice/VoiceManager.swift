import Foundation

/// Manages the active speech engine, recording state, and engine switching.
@MainActor
final class VoiceManager: ObservableObject {
    @Published var selectedEngineType: SpeechEngineType {
        didSet {
            selectedEngineType.save()
            updateActiveEngine()
        }
    }

    @Published var isRecording = false
    @Published var partialTranscription = ""
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var error: String?

    private nonisolated(unsafe) var activeEngine: any SpeechEngine

    init() {
        let type = SpeechEngineType.stored
        self.selectedEngineType = type
        self.activeEngine = Self.createEngine(for: type)
    }

    var currentEngineNeedsDownload: Bool {
        activeEngine.needsModelDownload
    }

    var currentEngineIsAvailable: Bool {
        activeEngine.isAvailable
    }

    func downloadModelIfNeeded() async {
        guard activeEngine.needsModelDownload else { return }
        isDownloading = true
        downloadProgress = 0
        error = nil

        let engine = activeEngine
        do {
            try await engine.downloadModel { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                }
            }
        } catch {
            self.error = error.localizedDescription
        }

        isDownloading = false
    }

    func toggleRecording(onComplete: @escaping @MainActor (String) -> Void) {
        if isRecording {
            stopRecording(onComplete: onComplete)
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        error = nil
        partialTranscription = ""
        isRecording = true

        let engine = activeEngine
        Task {
            do {
                try await engine.startStreaming { [weak self] partial in
                    Task { @MainActor in
                        self?.partialTranscription = partial
                    }
                }
            } catch {
                self.error = error.localizedDescription
                self.isRecording = false
            }
        }
    }

    private func stopRecording(onComplete: @escaping @MainActor (String) -> Void) {
        guard isRecording else { return }

        let engine = activeEngine
        Task {
            do {
                let transcription = try await engine.stopAndTranscribe()
                self.isRecording = false
                self.partialTranscription = ""
                if !transcription.isEmpty {
                    onComplete(transcription)
                }
            } catch {
                self.error = error.localizedDescription
                self.isRecording = false
            }
        }
    }

    private func updateActiveEngine() {
        activeEngine = Self.createEngine(for: selectedEngineType)
    }

    private static func createEngine(for type: SpeechEngineType) -> any SpeechEngine {
        switch type {
        case .native: NativeSpeechEngine()
        case .whisperKit: WhisperKitEngine()
        case .parakeet: FluidAudioEngine()
        }
    }
}
