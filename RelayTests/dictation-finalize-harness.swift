// Standalone test harness for DictationFinalizePolicy (XCTest needs Xcode,
// which this machine doesn't have). Run with:
//   cat Relay/Services/DictationFinalizePolicy.swift RelayTests/dictation-finalize-harness.swift \
//       > /tmp/dfp-test.swift && swift /tmp/dfp-test.swift
// Exits non-zero on failure.
//
// Reproduces the stale-finalize race: transcript finalization is async (the
// self-correction model pass can take seconds), and a finalize Task that
// lands after the world moved on must not stomp the new session. Symptoms
// when it does: the previous dictation's text reappears in the popover, the
// auto-copy fires mid-recording, and clear-on-copy wipes the live session.

import Foundation

var failures = 0
func expect(_ name: String, _ context: DictationFinalizePolicy.Context,
            _ expected: DictationFinalizePolicy.Action) {
    let got = DictationFinalizePolicy.decide(context)
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name): expected \(expected), got \(got)")
        failures += 1
    }
}

// The ordinary case: nothing changed while the transcript finalized.
expect("uninterrupted finish delivers",
       .init(generationAtStop: 1, generationNow: 1,
             isRecording: false, placeholderStillInStack: true),
       .deliver)

// The reported bug: user started a new recording before the previous
// session's (slow) finalize landed. Delivering would re-freeze old text into
// the display and auto-copy a half-finished new session.
expect("new recording started → accumulate, never deliver",
       .init(generationAtStop: 1, generationNow: 2,
             isRecording: true, placeholderStillInStack: true),
       .accumulate)

// User started AND stopped a newer recording while this one finalized; the
// newer session's own finalize owns delivery for both.
expect("newer session finished → accumulate",
       .init(generationAtStop: 1, generationNow: 2,
             isRecording: false, placeholderStillInStack: true),
       .accumulate)

// The stack was cleared (Clear Stack, or clear-on-copy from a newer session)
// while finalizing: resurrecting the text would be the "previous recording
// wasn't cleared" bug. Capture history is the safety net.
expect("cleared while finalizing → history only",
       .init(generationAtStop: 1, generationNow: 2,
             isRecording: false, placeholderStillInStack: false),
       .historyOnly)

expect("cleared mid-new-recording → history only",
       .init(generationAtStop: 1, generationNow: 3,
             isRecording: true, placeholderStillInStack: false),
       .historyOnly)

// Defensive: recording flag alone forces accumulate even if the generation
// looks current — delivery must never race a live session.
expect("live recording always blocks delivery",
       .init(generationAtStop: 2, generationNow: 2,
             isRecording: true, placeholderStillInStack: true),
       .accumulate)

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
