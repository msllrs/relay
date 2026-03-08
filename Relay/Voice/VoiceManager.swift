import CoreAudio
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
    @Published var audioLevel: Float = 0
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var error: String?

    /// The input device to use for recording. `nil` means system default.
    var inputDeviceID: AudioDeviceID?

    private nonisolated(unsafe) var activeEngine: any SpeechEngine
    private var previousInputVolume: Float?

    init() {
        let type = SpeechEngineType.stored
        self.selectedEngineType = type
        self.activeEngine = Self.createEngine(for: type)
    }

    var currentEngineNeedsDownload: Bool {
        activeEngine.needsModelDownload
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

    func startRecording() {
        guard !isRecording else { return }
        error = nil
        partialTranscription = ""
        isRecording = true

        let engine = activeEngine
        // Fall back to system default if the selected device is no longer available
        var deviceID = inputDeviceID
        if let id = deviceID, !AudioDeviceManager.inputDevices().contains(where: { $0.id == id }) {
            deviceID = nil
        }
        Task {
            do {
                try await engine.startStreaming(inputDeviceID: deviceID, onPartialResult: { [weak self] partial in
                    Task { @MainActor in
                        self?.partialTranscription = partial
                    }
                }, onAudioLevel: { [weak self] level in
                    Task { @MainActor in
                        self?.audioLevel = level
                    }
                })
            } catch {
                self.error = error.localizedDescription
                self.isRecording = false
            }

            // Max mic volume after engine starts (so it doesn't interfere with audio session setup)
            if UserDefaults.standard.object(forKey: "maxMicOnRecord") == nil || UserDefaults.standard.bool(forKey: "maxMicOnRecord") {
                self.previousInputVolume = SystemAudioHelper.getInputVolume(deviceID: deviceID)
                SystemAudioHelper.setInputVolume(1.0, deviceID: deviceID)
            }
        }
    }

    func stopRecording(onComplete: @escaping @MainActor (String) -> Void) {
        guard isRecording else { return }

        let engine = activeEngine
        Task {
            do {
                let transcription = try await engine.stopAndTranscribe()
                self.restoreInputVolume()
                self.isRecording = false
                self.partialTranscription = ""
                self.audioLevel = 0
                if !transcription.isEmpty {
                    onComplete(transcription)
                }
            } catch {
                self.restoreInputVolume()
                self.error = error.localizedDescription
                self.isRecording = false
                self.audioLevel = 0
            }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        let engine = activeEngine
        Task {
            await engine.cancel()
            self.restoreInputVolume()
            self.isRecording = false
            self.partialTranscription = ""
            self.audioLevel = 0
        }
    }

    private func restoreInputVolume() {
        if let volume = previousInputVolume {
            SystemAudioHelper.setInputVolume(volume, deviceID: inputDeviceID)
            previousInputVolume = nil
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
