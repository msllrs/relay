// Standalone test harness for SpokenCaptureCue (XCTest needs Xcode, which this
// machine doesn't have). Run with:
//   cat Relay/Services/SpokenCaptureCue.swift RelayTests/spoken-capture-cue-harness.swift > /tmp/scc-test.swift && swift /tmp/scc-test.swift
// Exits non-zero on failure.

import Foundation

var failures = 0
func check(_ name: String, _ actual: Int, _ expected: Int) {
    if actual == expected {
        print("PASS \(name)")
    } else {
        print("FAIL \(name): expected \(expected), got \(actual)")
        failures += 1
    }
}

// MARK: count

check("finds a cue", SpokenCaptureCue.count(in: "so look at this button"), 1)
check("ignores case and punctuation", SpokenCaptureCue.count(in: "Look, at this! And LOOK HERE."), 2)
check("counts each occurrence", SpokenCaptureCue.count(in: "look at this and then look at that"), 2)
check("bare look or now don't count", SpokenCaptureCue.count(in: "now it looks off, look closer"), 0)
check("whole words only", SpokenCaptureCue.count(in: "overlook here is fine, look at thistle"), 0)
check("check this out", SpokenCaptureCue.count(in: "check this out"), 1)
check("empty transcript", SpokenCaptureCue.count(in: ""), 0)

// MARK: newCues across streaming partials

var cue = SpokenCaptureCue()
check("partial before the cue", cue.newCues(in: "the header"), 0)
check("cue appears", cue.newCues(in: "the header look at this"), 1)
check("same cue in a longer partial doesn't refire", cue.newCues(in: "the header look at this badge"), 0)
check("revision drops the cue", cue.newCues(in: "the header looked at this badge"), 0)
check("cue returns after revision without refiring", cue.newCues(in: "the header look at this badge"), 0)
check("a second cue fires", cue.newCues(in: "the header look at this badge and look here"), 1)
check("two cues in one partial both fire", cue.newCues(in: "the header look at this badge and look here look at that check this out"), 2)
cue.reset()
check("reset starts the count over", cue.newCues(in: "look here"), 1)

if failures > 0 {
    print("\(failures) failure(s)")
    exit(1)
}
print("All spoken capture cue checks passed")
