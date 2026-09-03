import Foundation

/// What a finished SFSpeechRecognizer task means for the session. Apple's
/// recognizer reports a session that simply contained no speech as an error
/// (kAFAssistantErrorDomain 1110, "No speech detected"), and a cancelled
/// request as 216. Neither is a failure worth showing the user — the session
/// just produced no text.
enum RecognitionOutcome: Equatable {
    case text(String)
    case failed(String)

    static let assistantErrorDomain = "kAFAssistantErrorDomain"
    static let noSpeechCode = 1110
    static let cancelledCode = 216

    static func resolve(transcript: String, error: (any Error)?) -> RecognitionOutcome {
        guard let error else { return .text(transcript) }
        // Anything the recognizer managed to hear beats an error at the tail.
        if !transcript.isEmpty { return .text(transcript) }
        if isBenign(error) { return .text("") }
        return .failed(error.localizedDescription)
    }

    static func isBenign(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == assistantErrorDomain
            && (nsError.code == noSpeechCode || nsError.code == cancelledCode)
    }
}
