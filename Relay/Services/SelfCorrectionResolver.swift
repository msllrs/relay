import Foundation

/// Resolves spoken self-corrections in finished transcripts:
/// "change the padding to 20 pixels, scratch that, 8 pixels"
/// → "change the padding to 8 pixels".
///
/// Deterministic and entirely on-device. The model is the classic
/// reparandum–interregnum–repair split from disfluency research: a cue phrase
/// ("scratch that") marks the interregnum, the repair is what follows, and the
/// reparandum — the words to delete — is found by aligning the repair's words
/// against the words spoken just before the cue. When no alignment exists the
/// resolver falls back to progressively blunter edits (same-word-count tail
/// swap, then clause deletion) for unambiguous cues, and leaves the text
/// untouched for ambiguous ones like "I mean". [ref:N] markers survive every
/// edit, including markers inside a deleted span.
enum SelfCorrectionResolver {

    enum Mode {
        /// Finished transcript: every edit applies, including trailing
        /// retractions ("…scratch that." with nothing after).
        case full
        /// Streaming partials: trailing retractions are deferred, because the
        /// repair is usually still being spoken — resolving early would blow
        /// away a clause that alignment could scope precisely a moment later.
        case live
    }

    // MARK: - Cues

    private enum CueKind {
        /// "start over" — everything before the cue is discarded.
        case restart
        /// "scratch that" — unmistakably a correction; falls back to blunt
        /// edits when the repair can't be aligned.
        case strong
        /// "I mean" — often plain filler; only acts on a confident alignment,
        /// otherwise the text is left exactly as spoken.
        case weak
    }

    private struct CueMatch {
        let kind: CueKind
        let range: Range<String.Index>
    }

    /// Hesitations that often lead into a correction ("oh, actually, scratch
    /// that") — swallowed as part of the cue so they don't survive the edit.
    private static let cuePrefix = #"(?:(?:oh|okay|ok|ah|uh+|um+|er|hmm+|no|wait|yeah|nah|sorry|actually)[,!]?\s+){0,2}"#

    private static let restartBodies = [
        #"(?:let\s+me\s+|let'?s\s+|lemme\s+)?start\s+(?:over|again)"#,
        #"scratch\s+all\s+(?:of\s+)?th(?:at|is)"#,
        #"forget\s+(?:all\s+(?:of\s+)?th(?:at|is)|everything)"#,
        #"let\s+me\s+rephrase(?:\s+that)?"#,
        #"let\s+me\s+try\s+(?:that\s+)?again"#,
    ]

    private static let strongBodies = [
        #"scratch\s+that"#,
        #"strike\s+that"#,
        #"cross\s+that\s+out"#,
        // "no wait time" / "no wait list" are nouns, not corrections
        #"no,?\s+wait(?!\s+(?:time|times|list|lists|period)\b)"#,
        #"wait,?\s+no\b"#,
        // "actually no one came" is not a correction
        #"actually,?\s+no\b(?!\s+one\b)"#,
        #"no,?\s+actually\b"#,
        #"h(?:ang|old)\s+on,?\s+no\b"#,
        #"or\s+rather\b"#,
        #"change\s+that\s+to\b"#,
        #"changed?\s+my\s+mind"#,
        #"never\s?mind(?:\s+that)?\b"#,
        #"(?<!don't\s)(?<!dont\s)(?<!won't\s)(?<!wont\s)forget\s+that\b"#,
    ]

    private static let weakBodies = [
        #"i\s+mean[t]?\b"#,
        #"make\s+that\b"#,
    ]

    // Compiled once — resolve() runs on every streaming partial while the
    // live setting is on.
    private static let cueRegexes: [(CueKind, NSRegularExpression)] = {
        func assemble(_ bodies: [String], prefixed: Bool) -> String {
            let body = "(?:" + bodies.joined(separator: "|") + ")"
            return #"\b"# + (prefixed ? cuePrefix : "") + body
        }
        let patterns: [(CueKind, String)] = [
            (.restart, assemble(restartBodies, prefixed: true)),
            (.strong, assemble(strongBodies, prefixed: true)),
            (.weak, assemble(weakBodies, prefixed: false)),
        ]
        return patterns.compactMap { kind, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (kind, $0) }
        }
    }()

    // MARK: - Public

    /// Cheap gate: does the text contain any correction cue at all? Callers
    /// use this to skip the (slower) model-assisted path for the overwhelming
    /// majority of dictations that contain no correction.
    static func containsCue(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return cueRegexes.contains { _, regex in
            regex.firstMatch(in: text, range: range) != nil
        }
    }

    static func resolve(_ text: String, mode: Mode = .full) -> String {
        guard containsCue(text) else { return text }

        // Shield ref markers behind sentinels so no edit can mangle them.
        let sentinelChar: Character = "\u{FFFC}"
        var refs: [String] = []
        var working = text
        while let match = working.firstMatch(of: /\[ref:\d+\]/) {
            refs.append(String(working[match.range]))
            working.replaceSubrange(match.range, with: String(sentinelChar))
        }

        var searchFrom = working.startIndex
        var iterations = 0
        while iterations < 6, let cue = firstCue(in: working, from: searchFrom) {
            iterations += 1
            if let edited = apply(cue, to: working, sentinel: sentinelChar, mode: mode) {
                working = edited
                searchFrom = working.startIndex
            } else {
                // Ambiguous weak cue — leave it as spoken, look past it.
                searchFrom = cue.range.upperBound
            }
        }

        working = WordRules.cleanup(working)
        while let last = working.last, last == "," || last == ";" || last == " " {
            working.removeLast()
        }

        for ref in refs {
            if let range = working.range(of: String(sentinelChar)) {
                working.replaceSubrange(range, with: ref)
            }
        }
        return working
    }

    // MARK: - Cue search

    private static func firstCue(in text: String, from index: String.Index) -> CueMatch? {
        let searchRange = NSRange(index..<text.endIndex, in: text)
        var best: CueMatch?
        for (kind, regex) in cueRegexes {
            guard let match = regex.firstMatch(in: text, range: searchRange),
                  let range = Range(match.range, in: text)
            else { continue }
            if let current = best {
                let earlier = range.lowerBound < current.range.lowerBound
                let longerAtSameSpot = range.lowerBound == current.range.lowerBound
                    && range.upperBound > current.range.upperBound
                if earlier || longerAtSameSpot {
                    best = CueMatch(kind: kind, range: range)
                }
            } else {
                best = CueMatch(kind: kind, range: range)
            }
        }
        return best
    }

    // MARK: - Applying one cue

    /// Returns the edited text, or nil when a weak cue couldn't be resolved
    /// confidently and the text should stay untouched.
    private static func apply(_ cue: CueMatch, to text: String, sentinel: Character, mode: Mode) -> String? {
        // Pre: everything before the cue, minus the pause punctuation that
        // usually precedes it ("...20 pixels, scratch that").
        var pre = String(text[..<cue.range.lowerBound])
        while let last = pre.last, last.isWhitespace || last == "," || last == ";" {
            pre.removeLast()
        }

        // Post: everything after, minus the pause punctuation that follows.
        var post = String(text[cue.range.upperBound...])
        while let first = post.first, first.isWhitespace || first == "," || first == ";" || first == ":" || first == "." {
            post.removeFirst()
        }

        var preTokens = pre.split(whereSeparator: \.isWhitespace).map(String.init)

        if cue.kind == .restart {
            // Discard everything spoken so far; keep any ref markers alive.
            let kept = preTokens.flatMap { $0.filter { $0 == sentinel } }.map(String.init)
            return (kept + [post]).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }

        // The repair: the first few words after the cue, stopping at a
        // sentence boundary.
        var repair: [String] = []
        for token in post.split(whereSeparator: \.isWhitespace).prefix(8) {
            repair.append(String(token))
            if endsSentence(String(token)) { break }
        }

        // The region the reparandum can live in: the current sentence, or the
        // previous one when the cue opens a sentence of its own
        // ("...20 pixels. Scratch that. 8 pixels.").
        var regionStart = 0
        if let terminator = preTokens.lastIndex(where: endsSentence) {
            if terminator == preTokens.count - 1 {
                let previous = preTokens[..<terminator].lastIndex(where: endsSentence)
                regionStart = previous.map { $0 + 1 } ?? 0
            } else {
                regionStart = terminator + 1
            }
        }
        regionStart = max(regionStart, preTokens.count - 12)
        regionStart = max(regionStart, 0)

        if repair.isEmpty {
            // Trailing retraction ("...scratch that."): unambiguous cues drop
            // the last clause; ambiguous ones stay untouched. Deferred while
            // streaming — see Mode.live.
            guard cue.kind == .strong, mode == .full else { return nil }
            deleteClause(&preTokens, regionStart: regionStart, sentinel: sentinel)
            return assemble(preTokens, post: post)
        }

        // 1. Word alignment: the repair usually re-speaks a word from the
        //    reparandum ("to 20 pixels" → "8 pixels" aligns on "pixels").
        for j in 0..<min(3, repair.count) {
            let anchor = normalize(repair[j])
            guard !anchor.isEmpty else { continue }
            guard let i = preTokens[regionStart...].lastIndex(where: { normalize($0) == anchor }) else { continue }
            let start = i - j
            guard start >= regionStart, preTokens.count - start <= repair.count + 4 else { continue }
            deleteSuffix(&preTokens, from: start, sentinel: sentinel)
            return assemble(preTokens, post: post)
        }

        // 2. Number alignment: "meet at 3, no wait, 4" — swap the last number.
        if let j = (0..<min(3, repair.count)).first(where: { isNumber(repair[$0]) }),
           let i = preTokens[regionStart...].lastIndex(where: { isNumber($0) }) {
            if repair.count == 1 {
                return substitute(&preTokens, at: i, post: post, sentinel: sentinel)
            }
            let start = i - j
            if start >= regionStart, preTokens.count - start <= repair.count + 4 {
                deleteSuffix(&preTokens, from: start, sentinel: sentinel)
                return assemble(preTokens, post: post)
            }
        }

        // 3. Proper-noun swap: "send it to John, I mean, Jane".
        if repair.count == 1, isProperNoun(repair[0]),
           let last = preTokens.indices.last, last >= regionStart, isProperNoun(preTokens[last]) {
            return substitute(&preTokens, at: last, post: post, sentinel: sentinel)
        }

        guard cue.kind == .strong else { return nil }

        // 4. Same-arity tail swap: replace as many trailing words as the
        //    repair has ("turn it left, scratch that, right").
        if repair.count <= 4, preTokens.count - regionStart > repair.count {
            deleteSuffix(&preTokens, from: preTokens.count - repair.count, sentinel: sentinel)
            return assemble(preTokens, post: post)
        }

        // 5. Clause replacement: drop everything back to the last comma.
        deleteClause(&preTokens, regionStart: regionStart, sentinel: sentinel)
        return assemble(preTokens, post: post)
    }

    // MARK: - Edits

    /// Delete tokens[from...], keeping ref-marker sentinels from the deleted
    /// span and re-attaching sentence-final punctuation to the survivor
    /// ("...padding. Scratch that. 8 pixels." must keep the first period).
    private static func deleteSuffix(_ tokens: inout [String], from: Int, sentinel: Character) {
        guard from < tokens.count else { return }
        let deleted = tokens[from...]
        tokens.removeSubrange(from...)

        let keptSentinels = String(deleted.joined().filter { $0 == sentinel })
        if let terminal = deleted.last?.last, ".!?".contains(terminal),
           let survivor = tokens.last, let survivorLast = survivor.last,
           !".!?".contains(survivorLast) {
            tokens[tokens.count - 1] = survivor + String(terminal)
        }
        if !keptSentinels.isEmpty {
            tokens.append(keptSentinels)
        }
    }

    /// Delete the last clause: everything after the last comma in the region,
    /// or the whole region when it has no comma.
    private static func deleteClause(_ tokens: inout [String], regionStart: Int, sentinel: Character) {
        guard regionStart < tokens.count else { return }
        let region = tokens[regionStart..<(tokens.count - 1)]
        if let comma = region.lastIndex(where: { $0.hasSuffix(",") || $0.hasSuffix(";") }) {
            deleteSuffix(&tokens, from: comma + 1, sentinel: sentinel)
        } else {
            deleteSuffix(&tokens, from: regionStart, sentinel: sentinel)
        }
    }

    /// Replace tokens[i] with the repair word, consuming it from post:
    /// "order one coffee, make that two" → "order two coffee".
    private static func substitute(_ tokens: inout [String], at i: Int, post: String, sentinel: Character) -> String {
        var postTokens = post.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !postTokens.isEmpty else { return assemble(tokens, post: post) }
        let replacement = postTokens.removeFirst()
        let displacedSentinels = String(tokens[i].filter { $0 == sentinel })
        tokens[i] = displacedSentinels + replacement
        return assemble(tokens, post: postTokens.joined(separator: " "))
    }

    private static func assemble(_ tokens: [String], post: String) -> String {
        let pre = tokens.joined(separator: " ")
        if pre.isEmpty { return post }
        if post.isEmpty { return pre }
        return pre + " " + post
    }

    // MARK: - Token classification

    private static func normalize(_ token: String) -> String {
        token.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    private static func endsSentence(_ token: String) -> Bool {
        var trimmed = token
        while let last = trimmed.last, "\"')]”’".contains(last) {
            trimmed.removeLast()
        }
        guard let last = trimmed.last else { return false }
        return ".!?…".contains(last)
    }

    private static let spelledNumbers: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
        "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
        "thousand",
    ]

    private static func isNumber(_ token: String) -> Bool {
        let normalized = normalize(token)
        guard !normalized.isEmpty else { return false }
        if normalized.allSatisfy(\.isNumber) { return true }
        return spelledNumbers.contains(normalized)
    }

    /// Mid-sentence capitalized word — a decent proper-noun signal in
    /// dictated text. "I" and its contractions are excluded.
    private static func isProperNoun(_ token: String) -> Bool {
        let normalized = token.filter { $0.isLetter || $0 == "'" }
        guard let first = normalized.first, first.isUppercase, normalized.count >= 2 else { return false }
        return !normalized.lowercased().hasPrefix("i'")
    }
}
