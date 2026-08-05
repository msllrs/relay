// Standalone test harness for SelfCorrectionResolver (XCTest needs Xcode,
// which this machine doesn't have). Run with:
//   cat Relay/Models/WordRules.swift Relay/Services/SelfCorrectionResolver.swift \
//       RelayTests/self-correction-harness.swift > /tmp/scr-test.swift \
//       && swift -enable-bare-slash-regex /tmp/scr-test.swift
// Exits non-zero on failure.

import Foundation

var failures = 0
func expect(_ name: String, _ input: String, _ expected: String) {
    let got = SelfCorrectionResolver.resolve(input)
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)\n      input:    \(input)\n      expected: \(expected)\n      got:      \(got)")
        failures += 1
    }
}

// Word-anchored replacement — the repair re-speaks "pixels"
expect("scratch-that with word anchor",
       "Change the padding to 20 pixels, actually scratch that, 8 pixels",
       "Change the padding to 8 pixels")

// Bare-number swap stays in place
expect("no-wait number swap",
       "meet at 3 no wait 4",
       "meet at 4")

expect("spelled-number swap with hesitation",
       "make the font size fourteen, uh no wait, sixteen",
       "make the font size sixteen")

// Determiner anchor
expect("actually-no with determiner anchor",
       "use the blue button, actually no, the red one",
       "use the red one")

// Proper-noun swap via weak cue
expect("i-mean proper noun swap",
       "send it to John, I mean, Jane",
       "send it to Jane")

// Weak cue with no confident alignment must not touch the text
expect("i-mean as genuine filler is untouched",
       "This is fine, I mean it works",
       "This is fine, I mean it works")

// Cue as its own sentence reaches back into the previous sentence
expect("sentence-initial scratch-that",
       "Set the padding to 20 pixels. Scratch that. Use 8 pixels.",
       "Set the padding. Use 8 pixels.")

// Trailing retraction drops the last sentence, keeps earlier ones
expect("trailing retraction",
       "Use dark blue for the header. Set the padding to 20. Scratch that.",
       "Use dark blue for the header.")

// Trailing retraction drops only the last clause
expect("trailing retraction at clause",
       "I like the header, change padding to 20, scratch that",
       "I like the header")

expect("changed-my-mind full clause replacement",
       "put it on the left, changed my mind, put it on the right",
       "put it on the right")

expect("make-that number swap",
       "order one coffee, make that two",
       "order two coffee")

// Same-arity tail swap when nothing aligns
expect("arity fallback",
       "turn it left, scratch that, right",
       "turn it right")

// Restart discards everything before the cue
expect("start-over restart",
       "Tell them the meeting moved to Thursday. Actually, let me start over. The meeting is cancelled.",
       "The meeting is cancelled.")

// Two corrections in one utterance
expect("multiple corrections",
       "set margin to 4, no wait, 8, and color to red, scratch that, blue",
       "set margin to 8, and color to blue")

// Ref markers survive, even inside the deleted span
expect("ref markers preserved",
       "use the value from [ref:1] scratch that from [ref:2]",
       "use the value [ref:1] from [ref:2]")

// Cue at the very start of a dictation
expect("cue at start",
       "Scratch that, set padding to 8",
       "set padding to 8")

// No cue → identity
expect("no cue is identity",
       "just a normal sentence about padding",
       "just a normal sentence about padding")

// Phrases that merely contain cue words are not corrections
expect("no-wait-time false positive",
       "there's no wait time at the restaurant",
       "there's no wait time at the restaurant")

expect("actually-no-one false positive",
       "actually no one likes it",
       "actually no one likes it")

expect("dont-forget-that false positive",
       "don't forget that the API is rate limited",
       "don't forget that the API is rate limited")

// Live mode: trailing retractions wait for the repair still being spoken
func expectLive(_ name: String, _ input: String, _ expected: String) {
    let got = SelfCorrectionResolver.resolve(input, mode: .live)
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)\n      input:    \(input)\n      expected: \(expected)\n      got:      \(got)")
        failures += 1
    }
}

expectLive("live defers trailing retraction",
           "Change the padding to 20 pixels, scratch that",
           "Change the padding to 20 pixels, scratch that")

expectLive("live resolves completed correction",
           "Change the padding to 20 pixels, scratch that, 8 pixels",
           "Change the padding to 8 pixels")

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
