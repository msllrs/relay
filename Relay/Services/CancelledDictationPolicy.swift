import Foundation

/// Decides whether a cancelled dictation is worth keeping in capture history.
///
/// Esc cancels a recording, but Esc is also what you press to dismiss
/// something in another app while you talk, so a long dictation can vanish by
/// accident. A quick cancel is almost always deliberate ("never mind"), so only
/// sessions that ran past a short threshold are kept — in history only, never
/// in the stack, so the cancel still does what it says.
enum CancelledDictationPolicy {
    /// Cancels sooner than this after starting are treated as deliberate.
    static let minimumDuration: TimeInterval = 3

    /// The text to record in history, or nil to discard the session.
    static func textToKeep(transcript: String, elapsed: TimeInterval) -> String? {
        guard elapsed >= minimumDuration else { return nil }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
