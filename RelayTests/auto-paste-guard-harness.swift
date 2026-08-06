// Standalone test harness for AutoPasteGuard (XCTest needs Xcode, which this
// machine doesn't have). Run with:
//   cat Relay/Services/AutoPasteGuard.swift RelayTests/auto-paste-guard-harness.swift \
//       > /tmp/apg-test.swift && swift /tmp/apg-test.swift
// Exits non-zero on failure.
//
// Reproduces the self-paste bug: a dictation finished while keyboard focus
// sat in Relay's own Settings window — in a dictionary rule's replacement
// text field — and auto-paste inserted the whole transcript into it. The
// poisoned rule then spliced old prompts into every later transcript
// (match "pixels" → an ever-growing blob of past dictations). Auto-paste
// must verify the focused element belongs to another process before
// inserting anything.

import Foundation

var failures = 0
func expect(_ name: String, _ got: AutoPasteGuard.Verdict, _ expected: AutoPasteGuard.Verdict) {
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name): expected \(expected), got \(got)")
        failures += 1
    }
}

// The reported bug: focus is inside Relay itself (Settings text field).
expect("focus in our own process is blocked",
       AutoPasteGuard.decide(focusedElementPID: 500, ownPID: 500),
       .blockSelfTarget)

// The normal case: focus is in the external target app.
expect("focus in another process proceeds",
       AutoPasteGuard.decide(focusedElementPID: 812, ownPID: 500),
       .proceed)

// Focused element unreadable: we can't prove the target isn't us — don't
// fire a blind ⌘V.
expect("unknown focus is blocked",
       AutoPasteGuard.decide(focusedElementPID: nil, ownPID: 500),
       .blockUnknownTarget)

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
