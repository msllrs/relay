// Standalone test harness for ClipboardMonitor's duplicate suppression and
// text-item classification (XCTest needs Xcode, which this machine doesn't
// have). Run with:
//   cat Relay/Models/ContentType.swift Relay/Models/ClipboardItem.swift \
//       Relay/Models/ContextStack.swift Relay/Services/ContentClassifier.swift \
//       Relay/Services/ClipboardMonitor.swift RelayTests/clipboard-dedupe-harness.swift \
//       > /tmp/cbm-test.swift && swift /tmp/cbm-test.swift
// Exits non-zero on failure.
//
// Reproduces B-18: dedupe compared against the literal last stack item, which
// during a recording is the voice-note placeholder, so back-to-back identical
// copies both landed. Dedupe must compare against the most recent
// non-voice-note item (still one deep), text against text, image bytes
// against image bytes, with unreadable image files failing open.
//
// Also covers B-31 (classification vs truncation): content was classified on
// the full text but stored truncated at 10KB, so a big JSON's chip said JSON
// while its stored content no longer parsed. Type must match stored content.

import Foundation
import Combine

@MainActor
final class AppState {
    var isMonitoring = false
    var lastWrittenChangeCount: Int?
    let stack = ContextStack()
    func addItem(_ item: ClipboardItem) { stack.add(item) }
}

var failures = 0
func expect(_ name: String, _ got: Bool, _ expected: Bool) {
    if got == expected {
        print("PASS  \(name)")
    } else {
        print("FAIL  \(name): expected \(expected), got \(got)")
        failures += 1
    }
}

func textItem(_ text: String, _ type: ContentType = .text) -> ClipboardItem {
    ClipboardItem(contentType: type, textContent: text)
}

func imageItem(_ path: String) -> ClipboardItem {
    ClipboardItem(contentType: .image, imagePath: path)
}

let placeholder = ClipboardItem(contentType: .voiceNote, textContent: "")

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("clipboard-dedupe-harness", isDirectory: true)
try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
func writeTemp(_ bytes: [UInt8]) -> String {
    let url = tempDir.appendingPathComponent(UUID().uuidString + ".png")
    try! Data(bytes).write(to: url)
    return url.path
}

// MARK: - B-18: dedupe vs the placeholder

// The reported bug: copy "hello" twice during a recording. The placeholder
// sits last in the stack, so the second copy must still dedupe against the
// "hello" item beneath it.
expect("identical text behind placeholder is a duplicate",
       ClipboardMonitor.isDuplicate(textItem("hello"),
                                    inStack: [textItem("hello"), placeholder]),
       true)

expect("identical text with no placeholder is a duplicate",
       ClipboardMonitor.isDuplicate(textItem("hello"),
                                    inStack: [textItem("hello")]),
       true)

expect("different text is not a duplicate",
       ClipboardMonitor.isDuplicate(textItem("world"),
                                    inStack: [textItem("hello"), placeholder]),
       false)

expect("empty stack is not a duplicate",
       ClipboardMonitor.isDuplicate(textItem("hello"), inStack: []),
       false)

expect("stack holding only the placeholder is not a duplicate",
       ClipboardMonitor.isDuplicate(textItem("hello"), inStack: [placeholder]),
       false)

// The comparison stays one deep: only the most recent non-voice item counts.
expect("dedupe is one deep past the placeholder",
       ClipboardMonitor.isDuplicate(textItem("A"),
                                    inStack: [textItem("A"), textItem("B"), placeholder]),
       false)

// MARK: - B-18: type-crossing

let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]
let pathA = writeTemp(bytes)
let pathB = writeTemp(bytes)
let pathC = writeTemp([0x00, 0x01, 0x02])

expect("text never dedupes against an image",
       ClipboardMonitor.isDuplicate(textItem("hello"),
                                    inStack: [imageItem(pathA), placeholder]),
       false)

expect("image never dedupes against text",
       ClipboardMonitor.isDuplicate(imageItem(pathA),
                                    inStack: [textItem("hello"), placeholder]),
       false)

expect("byte-identical image behind placeholder is a duplicate",
       ClipboardMonitor.isDuplicate(imageItem(pathB),
                                    inStack: [imageItem(pathA), placeholder]),
       true)

expect("different image bytes are not a duplicate",
       ClipboardMonitor.isDuplicate(imageItem(pathC),
                                    inStack: [imageItem(pathA), placeholder]),
       false)

expect("unreadable image file fails open",
       ClipboardMonitor.isDuplicate(imageItem(tempDir.appendingPathComponent("missing.png").path),
                                    inStack: [imageItem(pathA), placeholder]),
       false)

// MARK: - B-31: classification matches stored (truncated) content

let smallJSON = #"{"key": "value"}"#
let small = ClipboardMonitor.textItem(from: smallJSON)
expect("small JSON is classified as JSON",
       small.contentType == .json && small.textContent == smallJSON,
       true)

let bigJSON = "{\"items\": [" +
    (0..<2000).map { "{\"index\": \($0), \"name\": \"item-\($0)\"}" }.joined(separator: ", ") +
    "]}"
let big = ClipboardMonitor.textItem(from: bigJSON)
expect("oversized JSON is stored truncated",
       big.textContent?.hasSuffix("[truncated]") == true,
       true)
expect("oversized JSON is not labeled JSON",
       big.contentType == .json,
       false)
expect("type always matches stored content",
       big.contentType == ContentClassifier.classify(text: big.textContent ?? ""),
       true)

try? FileManager.default.removeItem(at: tempDir)

print(failures == 0 ? "\nAll tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
