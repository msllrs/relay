import Foundation

/// Voice-activity gate with hysteresis for auto-stop: quiet must be sustained
/// (`hangoverDuration`) before the silence countdown starts, and speech must be
/// sustained (`onsetDuration`) before it resets — so a door slam doesn't keep
/// the session alive and a breath pause doesn't end it. Pure logic, no clocks
/// of its own: callers pass `now` in.
struct SilenceGate {
    /// Sustained speech required to clear a running silence countdown.
    var onsetDuration: TimeInterval = 0.12
    /// Sustained quiet required before silence officially starts.
    var hangoverDuration: TimeInterval = 0.25

    private(set) var silenceStartedAt: Date?
    private var speechCandidateSince: Date?
    private var quietCandidateSince: Date?

    /// Feed one level sample. Returns how long confirmed silence has lasted.
    mutating func process(isQuiet: Bool, at now: Date = Date()) -> TimeInterval {
        if isQuiet {
            speechCandidateSince = nil
            if silenceStartedAt == nil {
                if let since = quietCandidateSince {
                    if now.timeIntervalSince(since) >= hangoverDuration {
                        silenceStartedAt = since
                        quietCandidateSince = nil
                    }
                } else {
                    quietCandidateSince = now
                }
            }
        } else {
            quietCandidateSince = nil
            if silenceStartedAt != nil {
                if let since = speechCandidateSince {
                    if now.timeIntervalSince(since) >= onsetDuration {
                        silenceStartedAt = nil
                        speechCandidateSince = nil
                    }
                } else {
                    speechCandidateSince = now
                }
            }
        }
        guard let started = silenceStartedAt else { return 0 }
        return now.timeIntervalSince(started)
    }

    mutating func reset() {
        silenceStartedAt = nil
        speechCandidateSince = nil
        quietCandidateSince = nil
    }
}
