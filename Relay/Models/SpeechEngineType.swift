import Foundation

enum SpeechEngineType: String, CaseIterable, Identifiable {
    case native
    case whisperKit
    case parakeet
    case speechAnalyzer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: "Native"
        case .whisperKit: "Whisper"
        case .parakeet: "Parakeet"
        case .speechAnalyzer: "Apple v2"
        }
    }

    var description: String {
        switch self {
        case .native: "macOS built-in (no download)"
        case .whisperKit: "WhisperKit (~142MB download)"
        case .parakeet: "Parakeet via FluidAudio (~download)"
        case .speechAnalyzer: "Apple SpeechAnalyzer (macOS 26+)"
        }
    }

    /// Cases usable on this system — SpeechAnalyzer needs macOS 26.
    static var availableCases: [SpeechEngineType] {
        allCases.filter { $0 != .speechAnalyzer || SpeechAnalyzerEngine.isSupported }
    }

    // MARK: - UserDefaults persistence

    private static let defaultsKey = "selectedSpeechEngine"

    static var stored: SpeechEngineType {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let engine = SpeechEngineType(rawValue: raw) else {
            return .native
        }
        return engine
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}
