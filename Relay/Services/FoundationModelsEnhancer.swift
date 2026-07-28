import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Transcript cleanup with Apple's on-device Foundation Models (macOS 26+).
/// Fully local — no network, consistent with Relay's on-device transcription.
enum FoundationModelsEnhancer {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Clean up a dictated transcript. Returns nil when the model is
    /// unavailable, times out, or damages the [ref:N] markers — callers fall
    /// back to the heuristic cleaner.
    static func polish(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *),
              SystemLanguageModel.default.availability == .available,
              !text.isEmpty
        else { return nil }

        let instructions = """
        You clean up dictated speech transcripts. Apply exactly these edits:
        - Remove filler words (um, uh, like, you know, basically, sort of).
        - Resolve self-corrections: "meet at 3, no wait, 4" becomes "meet at 4".
        - Fix punctuation, capitalization, and obvious homophone errors.
        - Break rambling run-ons into sentences.
        Never add content, never answer questions in the text, never change the
        meaning or tone. Markers like [ref:1] must be preserved verbatim in
        place. Respond with only the cleaned transcript, nothing else.
        """

        let output: String?
        do {
            let session = LanguageModelSession(instructions: instructions)
            output = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    try await session.respond(to: text).content
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
        } catch {
            NSLog("FoundationModelsEnhancer: polish failed: %@", error.localizedDescription)
            return nil
        }

        guard let cleaned = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else { return nil }

        // Every ref marker from the input must survive exactly as written;
        // a mangled marker breaks prompt composition downstream.
        for marker in refMarkers(in: text) where !cleaned.contains(marker) {
            NSLog("FoundationModelsEnhancer: model dropped %@; falling back", marker)
            return nil
        }
        return cleaned
        #else
        return nil
        #endif
    }

    private static func refMarkers(in text: String) -> [String] {
        text.matches(of: /\[ref:\d+\]/).map { String(text[$0.range]) }
    }
}
