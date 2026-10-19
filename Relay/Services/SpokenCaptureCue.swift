import Foundation

/// Watches a live transcript for spoken capture cues ("look at this") and
/// reports each new one once. Streaming engines revise their partial text as
/// you speak, so a cue can appear, vanish, and reappear; tracking the highest
/// count seen means a revision never fires a second capture for the same cue.
///
/// Cues are short phrases rather than single words: every capture takes a slot
/// in the context stack, and bare "look" or "now" turn up constantly in
/// ordinary dictation.
struct SpokenCaptureCue {
    static let phrases = [
        "look at this",
        "look at that",
        "look here",
        "check this out",
    ]

    private var highestCount = 0

    /// Number of cues in `transcript` not reported before. Pass the whole
    /// current-session transcript each time it changes.
    mutating func newCues(in transcript: String) -> Int {
        let count = Self.count(in: transcript)
        defer { highestCount = max(highestCount, count) }
        return max(0, count - highestCount)
    }

    /// Start over, e.g. for a new session or after the transcript was cleared.
    mutating func reset() {
        highestCount = 0
    }

    /// Whole-word, case- and punctuation-insensitive cue occurrences.
    static func count(in transcript: String) -> Int {
        let words = transcript.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
        let cues = phrases.map { $0.split(separator: " ").map(String.init) }
        var total = 0
        var i = 0
        while i < words.count {
            if let match = cues.first(where: { cue in
                i + cue.count <= words.count && Array(words[i..<i + cue.count]) == cue
            }) {
                total += 1
                i += match.count
            } else {
                i += 1
            }
        }
        return total
    }
}
