// Standalone test harness for TranscriptEnhancer (XCTest needs Xcode,
// which this machine doesn't have). Run with:
//   cat Relay/Services/FoundationModelsEnhancer.swift Relay/Services/TranscriptEnhancer.swift \
//       RelayTests/transcript-enhancer-harness.swift > /tmp/te-test.swift \
//       && swift -enable-bare-slash-regex /tmp/te-test.swift
// Exits non-zero on failure.

import Foundation

var failures = 0
func expect(_ name: String, _ input: String, level: TranscriptEnhancement = .formatted, _ expected: String) {
    let got = TranscriptEnhancer.enhance(input, level: level)
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)\n      input:    \(input)\n      expected: \(expected)\n      got:      \(got)")
        failures += 1
    }
}

// B-31: a transcript ending in a ref marker gets its period before the marker
expect("trailing period before final ref marker",
       "check [ref:1]",
       "Check. [ref:1]")

expect("trailing period before final marker after multiple markers",
       "compare [ref:1] with [ref:2]",
       "Compare [ref:1] with. [ref:2]")

// No double period when the sentence already ends before the marker
expect("no double period before final ref marker",
       "done. [ref:1]",
       "Done. [ref:1]")

// Plain text still gets its trailing period
expect("trailing period on plain text",
       "the code needs refactoring",
       "The code needs refactoring.")

expect("no double trailing period on plain text",
       "the code needs refactoring.",
       "The code needs refactoring.")

// Mid-text markers are untouched
expect("mid-text ref marker preserved",
       "check [ref:1] and fix it",
       "Check [ref:1] and fix it.")

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll tests passed")
