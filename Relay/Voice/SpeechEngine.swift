import Foundation

/// Protocol for speech-to-text engines.
/// Implementations: NativeSpeechEngine, WhisperKitEngine, FluidAudioEngine
protocol SpeechEngine: AnyObject, Sendable {
    /// Whether this engine is available on the current system.
    var isAvailable: Bool { get }

    /// Whether a model download is required before first use.
    var needsModelDownload: Bool { get }

    /// Download the required model. No-op if already downloaded.
    func downloadModel(progress: @escaping @Sendable (Double) -> Void) async throws

    /// Start streaming speech recognition. Calls back with partial results.
    func startStreaming(onPartialResult: @escaping @Sendable (String) -> Void) async throws

    /// Stop recording and return the final transcription.
    func stopAndTranscribe() async throws -> String
}
