// Standalone test harness for WordRules (XCTest needs Xcode,
// which this machine doesn't have). Run with:
//   cat Relay/Models/WordRules.swift RelayTests/word-rules-harness.swift > /tmp/wr-test.swift \
//       && swift -enable-bare-slash-regex /tmp/wr-test.swift
// Exits non-zero on failure.

import Foundation

var failures = 0
func expect(
    _ name: String,
    _ input: String,
    removals: [String] = [],
    remappings: [(String, String)] = [],
    _ expected: String
) {
    let got = WordRules.apply(
        input,
        removals: removals.map { WordRemovalRule(pattern: $0) },
        remappings: remappings.map { WordRemappingRule(match: $0.0, replacement: $0.1) }
    )
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name)\n      input:    \(input)\n      expected: \(expected)\n      got:      \(got)")
        failures += 1
    }
}

// B-17: wildcard removal rules must not destroy ref markers through the shield
expect("wildcard .+ removal keeps ref markers",
       "hello [ref:1] world",
       removals: [".+"],
       "hello [ref:1] world")

expect("wildcard \\S+ removal keeps ref markers",
       "check [ref:1] and [ref:2] please",
       removals: ["\\S+"],
       "check [ref:1] and [ref:2] please")

// Literal removals still apply and markers survive
expect("literal removal preserves ref markers",
       "um hello [ref:1] world",
       removals: ["um+"],
       "hello [ref:1] world")

expect("removal with no markers still applies",
       "um so um hello",
       removals: ["um+"],
       "so hello")

// B-31: replacement-to-empty gets the same punctuation cleanup as removals
expect("replacement to empty repairs punctuation",
       "keep this foo bar, thanks",
       remappings: [("foo bar", "")],
       "keep this, thanks")

expect("replacement to empty collapses doubled spaces",
       "one filler two",
       remappings: [("filler", "")],
       "one two")

// Non-empty replacements still substitute normally
expect("plain replacement",
       "send it to jon",
       remappings: [("jon", "John")],
       "send it to John")

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll tests passed")
