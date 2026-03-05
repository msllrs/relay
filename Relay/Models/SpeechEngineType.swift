import Foundation

enum SpeechEngineType: String, CaseIterable, Identifiable {
    case native
    case whisperKit
    case parakeet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: "Native"
        case .whisperKit: "Whisper"
        case .parakeet: "Parakeet"
        }
    }

    var description: String {
        switch self {
        case .native: "macOS built-in (no download)"
        case .whisperKit: "WhisperKit (~142MB download)"
        case .parakeet: "Parakeet via FluidAudio (~download)"
        }
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
