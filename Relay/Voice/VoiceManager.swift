import ApplicationServices
import AVFoundation
import CoreAudio
import Foundation
import SwiftUI

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
    @Published var downloadComplete = false
    @Published var error: String?

    /// The input device to use for recording. `nil` means system default.
    var inputDeviceID: AudioDeviceID?

    private nonisolated(unsafe) var activeEngine: any SpeechEngine
    private var previousInputVolume: Float?

    /// Cached engine instances so downloaded models survive engine switching.
    private var engineCache: [SpeechEngineType: any SpeechEngine] = [:]

    init() {
        let type = SpeechEngineType.stored
        self.selectedEngineType = type
        let engine = Self.createEngine(for: type)
        self.activeEngine = engine
        self.engineCache[type] = engine
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
            isDownloading = false
            return
        }

        isDownloading = false
        downloadComplete = true
        try? await Task.sleep(for: .seconds(1.5))
        downloadComplete = false
    }

    /// Fake download cycle for tuning the animation in demo mode.
    func simulateDownload() async {
        isDownloading = true
        downloadProgress = 0
        error = nil
        downloadComplete = false

        try? await Task.sleep(for: .seconds(2))

        isDownloading = false
        downloadComplete = true
        try? await Task.sleep(for: .seconds(1.5))
        downloadComplete = false
    }

    func startRecording() {
        guard !isRecording else { return }

        // Ensure Accessibility is granted before requesting mic permission.
        // On first launch both prompts fire at once and macOS hides one behind the other.
        if !AXIsProcessTrusted() {
            error = "Accessibility permission required. Grant it in System Settings > Privacy & Security > Accessibility, then try again."
            return
        }

        error = nil
        partialTranscription = ""
        withAnimation(.easeInOut(duration: 0.25)) {
            isRecording = true
        }

        let engine = activeEngine
        // Fall back to system default if the selected device is no longer available
        var deviceID = inputDeviceID
        if let id = deviceID, !AudioDeviceManager.inputDevices().contains(where: { $0.id == id }) {
            deviceID = nil
        }
        Task {
            do {
                // Request mic permission before engines that don't handle it internally.
                // WhisperKit and NativeSpeechEngine call requestRecordPermission themselves;
                // calling it again from here causes a crash (double CheckedContinuation resume on macOS 26).
                if !engine.handlesPermissionInternally {
                    let micGranted = await AVAudioApplication.requestRecordPermission()
                    guard micGranted else {
                        throw SpeechEngineError.microphonePermissionDenied
                    }
                }

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
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.isRecording = false
                }
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

        withAnimation(.easeInOut(duration: 0.25)) {
            isRecording = false
        }
        audioLevel = 0

        let engine = activeEngine
        Task {
            do {
                let transcription = try await engine.stopAndTranscribe()
                self.restoreInputVolume()
                self.partialTranscription = ""
                if !transcription.isEmpty {
                    onComplete(transcription)
                }
            } catch {
                self.restoreInputVolume()
                self.error = error.localizedDescription
            }
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        let engine = activeEngine
        Task {
            await engine.cancel()
            self.restoreInputVolume()
            withAnimation(.easeInOut(duration: 0.25)) {
                self.isRecording = false
            }
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
        if let cached = engineCache[selectedEngineType] {
            activeEngine = cached
        } else {
            let engine = Self.createEngine(for: selectedEngineType)
            engineCache[selectedEngineType] = engine
            activeEngine = engine
        }
    }

    private static func createEngine(for type: SpeechEngineType) -> any SpeechEngine {
        switch type {
        case .native: NativeSpeechEngine()
        case .whisperKit: WhisperKitEngine()
        case .parakeet: FluidAudioEngine()
        }
    }
}
