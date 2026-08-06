import Foundation

/// Decides what a dictation-finalize Task may do when it finally lands.
///
/// Finalization is async and can take seconds (the self-correction pass may
/// await an on-device model call), so the world can change underneath it: the
/// user starts a new recording, or the stack gets cleared. A late finalize
/// that delivers anyway re-freezes old text into the display, auto-copies a
/// half-finished new session, and — with clear-on-copy — wipes the live
/// session's placeholder. This type encodes the staleness checks as a pure
/// decision so the race can be tested without an AppState.
enum DictationFinalizePolicy {
    struct Context {
        /// `dictationGeneration` captured when the session stopped.
        let generationAtStop: Int
        /// `dictationGeneration` at the moment the finalize Task runs.
        let generationNow: Int
        /// Whether a (newer) recording is live right now.
        let isRecording: Bool
        /// Whether this session's stack item still exists. Sessions that
        /// never had a placeholder count as present.
        let placeholderStillInStack: Bool
    }

    enum Action: Equatable {
        /// Update the stack item, freeze the display, run the auto-copy chain.
        case deliver
        /// Update the stack item and accumulated transcript, but a newer
        /// session owns display delivery and auto-copy.
        case accumulate
        /// The session's item was cleared away while finalizing; record the
        /// text in capture history only.
        case historyOnly
    }

    static func decide(_ context: Context) -> Action {
        // Cleared away entirely — resurrecting the text would undo the clear.
        if !context.placeholderStillInStack { return .historyOnly }
        // A newer session took over (or is live): keep the text, but delivery
        // and auto-copy belong to that session's own finalize.
        if context.isRecording || context.generationNow != context.generationAtStop { return .accumulate }
        return .deliver
    }
}
