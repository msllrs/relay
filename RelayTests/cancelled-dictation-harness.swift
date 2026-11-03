// Standalone test harness for CancelledDictationPolicy (XCTest needs Xcode,
// which this machine doesn't have). Run with:
//   cat Relay/Services/CancelledDictationPolicy.swift RelayTests/cancelled-dictation-harness.swift > /tmp/cd-test.swift && swift /tmp/cd-test.swift
// Exits non-zero on failure.

import Foundation

var failures = 0
func check(_ name: String, _ actual: String?, _ expected: String?) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        print("FAIL \(name): expected \(expected ?? "nil"), got \(actual ?? "nil")")
        failures += 1
    }
}

check("quick cancel is discarded",
      CancelledDictationPolicy.textToKeep(transcript: "make the header", elapsed: 1.2), nil)
check("just under the threshold is discarded",
      CancelledDictationPolicy.textToKeep(transcript: "make the header", elapsed: 2.99), nil)
check("at the threshold is kept",
      CancelledDictationPolicy.textToKeep(transcript: "make the header", elapsed: 3), "make the header")
check("long cancel keeps trimmed text",
      CancelledDictationPolicy.textToKeep(transcript: "  make the header sticky \n", elapsed: 20), "make the header sticky")
check("nothing said is discarded however long",
      CancelledDictationPolicy.textToKeep(transcript: "", elapsed: 20), nil)
check("whitespace only is discarded",
      CancelledDictationPolicy.textToKeep(transcript: "  \n ", elapsed: 20), nil)

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All cancelled dictation checks passed")
