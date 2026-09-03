import AppKit

/// Recognises a modifier key tapped twice in quick succession with nothing
/// else pressed in between — the "double-tap ⌘" style of shortcut. Carbon's
/// hotkey API can't express a bare modifier, so this is a pure state machine
/// over (modifier flags, timestamp) that NSEvent monitors and the shortcut
/// recorder feed from `flagsChanged` events.
///
/// Fires on the second press (not its release) so a double-tap can also be
/// held for push-to-talk.
struct ModifierDoubleTapDetector: Sendable {
    /// Modifiers that can be double-tapped on their own.
    static let tappable: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, .function]
    /// The second press must land within this long after the first release.
    static let window: TimeInterval = 0.35

    /// Restrict to one modifier (the configured shortcut), or nil to accept
    /// whichever single modifier is tapped (the recorder).
    let modifier: NSEvent.ModifierFlags?

    private enum State {
        case idle
        case firstDown(NSEvent.ModifierFlags)
        case released(NSEvent.ModifierFlags, at: TimeInterval)
        /// A chord was formed; wait for every modifier to lift before a new
        /// tap can begin, so ⌘⇧ then re-pressing ⌘ isn't read as ⌘ ⌘.
        case blocked
    }
    private var state = State.idle

    init(modifier: NSEvent.ModifierFlags? = nil) {
        self.modifier = modifier
    }

    /// Feed a `flagsChanged` event. Returns the modifier when a double tap
    /// completes, nil otherwise.
    mutating func flagsChanged(_ raw: NSEvent.ModifierFlags, at time: TimeInterval) -> NSEvent.ModifierFlags? {
        let flags = raw.intersection(.deviceIndependentFlagsMask)
        let held = Self.tappable.filter { flags.contains($0) }

        switch state {
        case .idle:
            if let only = soleTap(held) { state = .firstDown(only) }

        case .firstDown(let mod):
            if held.isEmpty {
                state = .released(mod, at: time)
            } else if held != [mod] {
                state = .blocked // a second modifier joined — that's a chord
            }

        case .released(let mod, let releasedAt):
            if held.isEmpty { return nil }
            if held == [mod], time - releasedAt <= Self.window {
                state = .idle
                return mod
            }
            // Too slow, or a different modifier: treat as a fresh first tap.
            state = soleTap(held).map { .firstDown($0) } ?? .idle

        case .blocked:
            if held.isEmpty { state = .idle }
        }
        return nil
    }

    /// Any ordinary key press breaks the sequence: ⌘C then ⌘ is a chord
    /// followed by a tap, not a double tap.
    mutating func keyDown() {
        state = .idle
    }

    mutating func reset() {
        state = .idle
    }

    private func soleTap(_ held: [NSEvent.ModifierFlags]) -> NSEvent.ModifierFlags? {
        guard held.count == 1, let only = held.first else { return nil }
        if let modifier, only != modifier { return nil }
        return only
    }
}
