import Foundation

/// Decides whether auto-paste may insert into the currently focused UI
/// element. Exists because a dictation once finished while keyboard focus
/// sat in Relay's own Settings window — a dictionary rule's replacement
/// text field — and the transcript was pasted into the rule editor. The
/// poisoned rule then spliced old prompts into every later transcript, a
/// self-amplifying blob that grew with each dictation. The target must be
/// proven to belong to another process before anything is inserted.
///
/// Foundation-only by design so the standalone harness
/// (RelayTests/auto-paste-guard-harness.swift) can run it without Xcode.
enum AutoPasteGuard {
    enum Verdict: Equatable {
        case proceed
        /// Focus is inside Relay itself (e.g. a Settings text field) — pasting
        /// would write the transcript into our own UI.
        case blockSelfTarget
        /// The focused element's owner can't be determined; a blind ⌘V could
        /// land anywhere.
        case blockUnknownTarget
    }

    static func decide(focusedElementPID: pid_t?, ownPID: pid_t) -> Verdict {
        guard let pid = focusedElementPID else { return .blockUnknownTarget }
        return pid == ownPID ? .blockSelfTarget : .proceed
    }
}
