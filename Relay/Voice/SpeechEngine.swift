import CoreAudio
import Foundation

/// Protocol for speech-to-text engines.
/// Implementations: NativeSpeechEngine, WhisperKitEngine, FluidAudioEngine
protocol SpeechEngine: AnyObject, Sendable {
    /// Whether this engine is available on the current system.
    var isAvailable: Bool { get }

    /// Whether a model download is required before first use.
    var needsModelDownload: Bool { get }

    /// Whether this engine handles microphone permission requests internally.
    /// When true, VoiceManager skips its own requestRecordPermission call.
    var handlesPermissionInternally: Bool { get }

    /// Download the required model. No-op if already downloaded.
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Start streaming speech recognition using a specific input device.
    /// Pass `nil` for `inputDeviceID` to use the system default.
    func startStreaming(inputDeviceID: AudioDeviceID?, onPartialResult: @escaping @Sendable (String) -> Void, onAudioLevel: @escaping @Sendable (Float) -> Void) async throws

    /// Stop recording and return the final transcription.
    func stopAndTranscribe() async throws -> String

    /// Cancel recording without transcribing. Discards all captured audio.
    func cancel() async
}
