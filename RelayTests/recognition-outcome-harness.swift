// Standalone test harness for RecognitionOutcome (XCTest needs Xcode, which
// this machine doesn't have). Run with:
//   cat Relay/Voice/RecognitionOutcome.swift RelayTests/recognition-outcome-harness.swift \
//       > /tmp/ro-test.swift && swift /tmp/ro-test.swift
// Exits non-zero on failure.
//
// Reproduces the lingering "Transcription failed: No speech detected" banner:
// ending a dictation without saying anything made SFSpeechRecognizer return
// kAFAssistantErrorDomain 1110, which the native engine surfaced as a failure.
// An empty session is an empty transcript, not an error.

import Foundation

var failures = 0
func expect(_ name: String, _ got: RecognitionOutcome, _ expected: RecognitionOutcome) {
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name): expected \(expected), got \(got)")
        failures += 1
    }
}

let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110,
                       userInfo: [NSLocalizedDescriptionKey: "No speech detected"])
let cancelled = NSError(domain: "kAFAssistantErrorDomain", code: 216, userInfo: nil)
let network = NSError(domain: "kAFAssistantErrorDomain", code: 1101,
                      userInfo: [NSLocalizedDescriptionKey: "Network unavailable"])
let other = NSError(domain: "SomeOtherDomain", code: 1110, userInfo: [NSLocalizedDescriptionKey: "Boom"])

expect("no error passes the transcript through",
       RecognitionOutcome.resolve(transcript: "hello", error: nil), .text("hello"))
expect("no speech with an empty transcript is an empty result, not a failure",
       RecognitionOutcome.resolve(transcript: "", error: noSpeech), .text(""))
expect("cancelled request with an empty transcript is an empty result",
       RecognitionOutcome.resolve(transcript: "", error: cancelled), .text(""))
expect("a real recognizer error with nothing heard is a failure",
       RecognitionOutcome.resolve(transcript: "", error: network), .failed("Network unavailable"))
expect("code 1110 in another domain is not treated as benign",
       RecognitionOutcome.resolve(transcript: "", error: other), .failed("Boom"))
expect("text heard before an error is kept",
       RecognitionOutcome.resolve(transcript: "keep this", error: network), .text("keep this"))

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nAll passed")
