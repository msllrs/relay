import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var stack = ContextStack()
    @Published var isMonitoring = false
    @Published var showCopiedConfirmation = false
    @Published var clearStackOnCopy: Bool {
        didSet { UserDefaults.standard.set(clearStackOnCopy, forKey: "clearStackOnCopy") }
    }
    @Published var alwaysOnMonitoring: Bool {
        didSet { UserDefaults.standard.set(alwaysOnMonitoring, forKey: "alwaysOnMonitoring") }
    }
    @Published var maxMicOnRecord: Bool {
        didSet { UserDefaults.standard.set(maxMicOnRecord, forKey: "maxMicOnRecord") }
    }
    @Published var hotkeyStartsDictation: Bool {
        didSet { UserDefaults.standard.set(hotkeyStartsDictation, forKey: "hotkeyStartsDictation") }
    }
    @Published var pushToTalk: Bool {
        didSet { UserDefaults.standard.set(pushToTalk, forKey: "pushToTalk") }
    }
    @Published var cleanDictation: Bool {
        didSet { UserDefaults.standard.set(cleanDictation, forKey: "cleanDictation") }
    }
    @Published var captureClipboardOnStart: Bool {
        didSet { UserDefaults.standard.set(captureClipboardOnStart, forKey: "captureClipboardOnStart") }
    }
    @Published var promptFormat: PromptFormat {
        didSet { UserDefaults.standard.set(promptFormat.rawValue, forKey: "promptFormat") }
    }
    @Published var selectedInputDeviceID: UInt32 {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceID, forKey: "selectedInputDeviceID")
            voiceManager.inputDeviceID = selectedInputDeviceID == 0 ? nil : selectedInputDeviceID
        }
    }
    @Published var itemJustAdded = false
    @Published var isRecording = false
    @Published var displayTranscription = ""
    let isDemo = ProcessInfo.processInfo.environment["RELAY_DEMO"] == "1"

    /// Accumulated transcription text from previous dictation sessions (before the current one).
    private var frozenTranscription = ""

    /// Number of non-voiceNote items in the stack when a dictation session started (for clean dictation).
    private var clipboardItemCountAtSessionStart = 0

    /// ID of the placeholder voice note added when recording starts.
    private var activeVoiceNoteID: UUID?

    /// Tracks clipboard items that arrived during an active dictation session.
    private struct PendingRef {
        let itemID: UUID
        let charOffset: Int
    }
    private var pendingRefs: [PendingRef] = []

    let voiceManager = VoiceManager()
    private var clipboardMonitor: ClipboardMonitor?
    private(set) var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()

    /// The change count to ignore (set after we write to the pasteboard)
    var lastWrittenChangeCount: Int?

    init() {
        self.clearStackOnCopy = UserDefaults.standard.bool(forKey: "clearStackOnCopy")
        self.alwaysOnMonitoring = UserDefaults.standard.bool(forKey: "alwaysOnMonitoring")
        self.hotkeyStartsDictation = UserDefaults.standard.bool(forKey: "hotkeyStartsDictation")
        self.pushToTalk = UserDefaults.standard.bool(forKey: "pushToTalk")
        self.cleanDictation = UserDefaults.standard.bool(forKey: "cleanDictation")
        // Default to true if key has never been set
        if UserDefaults.standard.object(forKey: "captureClipboardOnStart") == nil {
            self.captureClipboardOnStart = true
        } else {
            self.captureClipboardOnStart = UserDefaults.standard.bool(forKey: "captureClipboardOnStart")
        }
        if UserDefaults.standard.object(forKey: "maxMicOnRecord") == nil {
            self.maxMicOnRecord = true
        } else {
            self.maxMicOnRecord = UserDefaults.standard.bool(forKey: "maxMicOnRecord")
        }
        self.promptFormat = PromptFormat(rawValue: UserDefaults.standard.string(forKey: "promptFormat") ?? "") ?? .xml
        let storedDeviceID = UInt32(UserDefaults.standard.integer(forKey: "selectedInputDeviceID"))
        // Reset to system default if the stored device is no longer available
        if storedDeviceID != 0 && !AudioDeviceManager.inputDevices().contains(where: { $0.id == storedDeviceID }) {
            self.selectedInputDeviceID = 0
        } else {
            self.selectedInputDeviceID = storedDeviceID
            if storedDeviceID != 0 {
                voiceManager.inputDeviceID = storedDeviceID
            }
        }
        clipboardMonitor = ClipboardMonitor(appState: self)
        hotkeyManager = HotkeyManager(appState: self)

        // Forward stack changes so SwiftUI picks them up
        stack.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward voiceManager changes so SwiftUI picks them up
        voiceManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Mirror voiceManager.isRecording so SwiftUI can track it
        voiceManager.$isRecording
            .assign(to: &$isRecording)

        // Rebuild display transcription as partial results stream in
        voiceManager.$partialTranscription
            .sink { [weak self] _ in self?.rebuildDisplayTranscription() }
            .store(in: &cancellables)

        // Stop Esc/keyUp monitors when recording ends
        voiceManager.$isRecording
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.hotkeyManager?.stopEscMonitor()
                self?.hotkeyManager?.stopKeyUpMonitor()
            }
            .store(in: &cancellables)

        if ProcessInfo.processInfo.environment["RELAY_DEMO"] == "1" {
            populateDemoStack()
            startMonitoring()
        } else if alwaysOnMonitoring {
            startMonitoring()
        }
    }

    func populateDemoStack() {
        let items: [ClipboardItem] = [
            ClipboardItem(contentType: .code, textContent: """
                func fibonacci(_ n: Int) -> Int {
                    guard n > 1 else { return n }
                    return fibonacci(n - 1) + fibonacci(n - 2)
                }
                """),
            ClipboardItem(contentType: .json, textContent: """
                {"user": {"id": 42, "name": "Ada Lovelace", "roles": ["admin", "editor"]}}
                """),
            ClipboardItem(contentType: .terminal, textContent: """
                $ swift build
                Building for debugging...
                [42/42] Linking Relay
                Build complete! (3.81s)
                """),
            ClipboardItem(contentType: .url, textContent: "https://example.com/api/v1/users"),
            ClipboardItem(contentType: .error, textContent: """
                Traceback (most recent call last):
                  File "app.py", line 12, in <module>
                    result = process(data)
                  File "app.py", line 8, in process
                    return data["missing_key"]
                KeyError: 'missing_key'
                """),
            ClipboardItem(contentType: .diff, textContent: """
                diff --git a/Sources/App.swift b/Sources/App.swift
                @@ -10,3 +10,5 @@ struct App {
                     let name: String
                +    let version: Int
                +    let isEnabled: Bool
                 }
                """),
            ClipboardItem(contentType: .agentation, textContent: """
                The sidebar navigation is hard to scan — consider grouping items under section headers and adding icons for quick visual recognition.
                """),
            ClipboardItem(contentType: .text, textContent: """
                The quick brown fox jumps over the lazy dog. This is a plain text paragraph that exercises wrapping and truncation in the context stack preview.
                """),
            ClipboardItem(contentType: .file, textContent: "/Users/demo/Projects/relay/Sources/App.swift"),
            ClipboardItem(contentType: .voiceNote, textContent: "Take this code snippet and refactor it to use async await instead of completion handlers"),
        ]
        for item in items {
            stack.add(item)
        }

        // Set a sample transcription with ref markers for demo display
        let demoTranscription = "Take this code snippet [ref:1] and refactor it to use async await instead of completion handlers. Also check the API response [ref:2] and make sure the build output [ref:3] looks correct. Here's the endpoint [ref:4] that's throwing the error [ref:5] and the diff [ref:6] with the proposed fix."
        frozenTranscription = demoTranscription
        displayTranscription = demoTranscription
    }

    func startMonitoring() {
        isMonitoring = true
        if captureClipboardOnStart {
            clipboardMonitor?.captureCurrentClipboard()
        }
        clipboardMonitor?.start()
    }

    func stopMonitoring() {
        isMonitoring = false
        clipboardMonitor?.stop()
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    /// Called by HotkeyManager when the keyboard shortcut is pressed.
    func hotkeyTriggered() {
        if isMonitoring && voiceManager.isRecording {
            // Already recording → stop, save transcription, stop monitoring
            finishDictationAndStop()
        } else if hotkeyStartsDictation && !isMonitoring {
            // Start monitoring + begin dictation
            startMonitoring()
            clipboardItemCountAtSessionStart = stack.items.filter { $0.contentType != .voiceNote }.count
            pendingRefs = []
            // Reserve a placeholder in the stack so the voice note keeps its position
            let placeholder = ClipboardItem(contentType: .voiceNote, textContent: "")
            activeVoiceNoteID = placeholder.id
            stack.add(placeholder)
            voiceManager.startRecording()
            // Install Esc monitor to cancel
            hotkeyManager?.startEscMonitor { [weak self] in
                self?.cancelDictation()
            }
            // Install keyUp monitor for push-to-talk
            if pushToTalk {
                hotkeyManager?.startKeyUpMonitor { [weak self] in
                    self?.finishDictationAndStop()
                }
            }
        } else {
            toggleMonitoring()
        }
    }

    func finishDictationAndStop() {
        hotkeyManager?.stopEscMonitor()
        hotkeyManager?.stopKeyUpMonitor()
        let itemCountBefore = clipboardItemCountAtSessionStart
        let isPushToTalk = pushToTalk
        let refs = pendingRefs
        pendingRefs = []
        let voiceNoteID = activeVoiceNoteID
        activeVoiceNoteID = nil
        voiceManager.stopRecording { [weak self] transcription in
            guard let self else { return }
            // Clean dictation: if push-to-talk and no clipboard items were added during session,
            // copy raw transcription directly instead of adding to stack
            let currentClipboardCount = self.stack.items.filter { $0.contentType != .voiceNote }.count
            if isPushToTalk && self.cleanDictation && currentClipboardCount == itemCountBefore {
                // Remove the placeholder since we're copying raw
                if let id = voiceNoteID { self.stack.remove(id: id) }
                self.frozenTranscription = ""
                self.displayTranscription = ""
                self.copyRawTranscription(transcription)
            } else if let id = voiceNoteID {
                let markedText = self.insertRefMarkers(into: transcription, refs: refs)
                self.stack.update(id: id, textContent: markedText)
                self.freezeCurrentSession(markedText)
            } else {
                let markedText = self.insertRefMarkers(into: transcription, refs: refs)
                let item = ClipboardItem(contentType: .voiceNote, textContent: markedText)
                self.stack.add(item)
                self.freezeCurrentSession(markedText)
            }
        }
        stopMonitoring()
    }

    func cancelDictation() {
        hotkeyManager?.stopEscMonitor()
        hotkeyManager?.stopKeyUpMonitor()
        pendingRefs = []
        // Restore display to frozen text (discard current session only)
        displayTranscription = frozenTranscription
        if let id = activeVoiceNoteID {
            stack.remove(id: id)
            activeVoiceNoteID = nil
        }
        voiceManager.cancelRecording()
        stopMonitoring()
    }

    private func copyRawTranscription(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount

        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedConfirmation = false
        }
    }

    private func insertRefMarkers(into text: String, refs: [PendingRef]) -> String {
        guard !refs.isEmpty else { return text }

        // Build a map of non-voice-note indices (1-based)
        var nonVoiceIndex = 0
        var indexByID: [UUID: Int] = [:]
        for item in stack.items {
            if item.contentType != .voiceNote {
                nonVoiceIndex += 1
                indexByID[item.id] = nonVoiceIndex
            }
        }

        var markers: [(charOffset: Int, refText: String)] = []
        for ref in refs {
            if let idx = indexByID[ref.itemID] {
                markers.append((ref.charOffset, " [ref:\(idx)]"))
            }
        }

        guard !markers.isEmpty else { return text }

        // Sort by offset descending so insertions don't shift earlier positions
        markers.sort { $0.charOffset > $1.charOffset }

        var result = text
        for marker in markers {
            let clampedOffset = min(marker.charOffset, result.count)
            let insertionOffset = snapToWordBoundary(in: result, near: clampedOffset)
            let insertionIndex = result.index(result.startIndex, offsetBy: insertionOffset)
            result.insert(contentsOf: marker.refText, at: insertionIndex)
        }
        return result
    }

    /// Snap a character offset to the nearest word boundary, preferring the end of the current word.
    private func snapToWordBoundary(in text: String, near offset: Int) -> Int {
        guard !text.isEmpty, offset > 0, offset < text.count else { return offset }

        let index = text.index(text.startIndex, offsetBy: offset)

        // If we're already at a space, we're at a boundary
        if text[index] == " " { return offset }

        // Scan forward to find the end of the current word
        var end = index
        while end < text.endIndex, text[end] != " " {
            end = text.index(after: end)
        }
        return text.distance(from: text.startIndex, to: end)
    }

    /// If the stack is just a single voice note, auto-copy raw text to clipboard.
    private func autoCopyIfVoiceOnly() {
        guard stack.items.count == 1,
              stack.items[0].contentType == .voiceNote,
              let text = stack.items[0].textContent, !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount
        stack.clear()
        frozenTranscription = ""
        displayTranscription = ""
        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedConfirmation = false
        }
    }

    func notifyItemAdded() {
        itemJustAdded = true
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            itemJustAdded = false
        }
    }

    /// Freeze the completed session text into the accumulated transcription.
    private func freezeCurrentSession(_ markedText: String) {
        if frozenTranscription.isEmpty {
            frozenTranscription = markedText
        } else {
            frozenTranscription += " " + markedText
        }
        displayTranscription = frozenTranscription
        autoCopyIfVoiceOnly()
    }

    /// Record a reference marker for a clipboard item captured during dictation.
    func recordRefMarker(for itemID: UUID) {
        guard voiceManager.isRecording else { return }
        // Use current transcription length so the ref appears after all spoken text so far
        let partial = voiceManager.partialTranscription
        // Place at end of current text (not at the raw offset, which can be 0 before speech starts)
        let offset = partial.isEmpty ? Int.max : partial.count
        pendingRefs.append(PendingRef(itemID: itemID, charOffset: offset))
        rebuildDisplayTranscription()
    }

    /// Rebuild `displayTranscription` by splicing pending ref markers into live partial text.
    private func rebuildDisplayTranscription() {
        guard voiceManager.isRecording else { return }
        let currentSession = insertRefMarkers(
            into: voiceManager.partialTranscription,
            refs: pendingRefs
        )
        if frozenTranscription.isEmpty {
            displayTranscription = currentSession
        } else {
            displayTranscription = frozenTranscription + " " + currentSession
        }
    }

    /// Remove a ref by its 1-based index: strip the marker from transcription text,
    /// remove the stack item, and renumber remaining refs.
    func removeRef(_ refIndex: Int) {
        let nonVoiceItems = stack.items.filter { $0.contentType != .voiceNote }
        guard refIndex >= 1, refIndex <= nonVoiceItems.count else { return }
        let itemToRemove = nonVoiceItems[refIndex - 1]

        withAnimation(.snappy(duration: 0.25)) {
            stack.remove(id: itemToRemove.id)

            // Remove from pending refs if still recording
            pendingRefs.removeAll { $0.itemID == itemToRemove.id }

            // Strip the [ref:N] marker and renumber higher refs
            frozenTranscription = stripAndRenumberRef(in: frozenTranscription, removedIndex: refIndex)
            // Also update voice note textContent that contains ref markers
            for item in stack.items where item.contentType == .voiceNote {
                if let text = item.textContent {
                    stack.update(id: item.id, textContent: stripAndRenumberRef(in: text, removedIndex: refIndex))
                }
            }

            // Rebuild display: if recording, include live session; otherwise use frozen text
            if voiceManager.isRecording {
                rebuildDisplayTranscription()
            } else {
                displayTranscription = frozenTranscription
            }
        }
    }

    /// Remove `[ref:N]` for the given index and decrement all higher ref numbers.
    private func stripAndRenumberRef(in text: String, removedIndex: Int) -> String {
        // Single-pass replacement: match any [ref:N], remove if N == removedIndex, decrement if N > removedIndex
        let pattern = /\ ?\[ref:(\d+)\]/
        var result = ""
        var remaining = text[...]

        while let match = remaining.firstMatch(of: pattern) {
            // Append text before the match
            result += remaining[remaining.startIndex..<match.range.lowerBound]

            if let n = Int(match.output.1) {
                if n == removedIndex {
                    // Strip this ref entirely
                } else if n > removedIndex {
                    result += " [ref:\(n - 1)]"
                } else {
                    result += String(remaining[match.range])
                }
            }

            remaining = remaining[match.range.upperBound...]
        }
        // Append any remaining text
        result += remaining
        return result
    }

    func clearAll() {
        stack.clear()
        frozenTranscription = ""
        displayTranscription = ""
    }

    func copyPromptToClipboard() {
        // If the only item is a voice note, just copy the raw text
        let onlyVoiceNote = stack.items.count == 1
            && stack.items[0].contentType == .voiceNote
        let prompt = onlyVoiceNote
            ? (stack.items[0].textContent ?? "")
            : PromptComposer.compose(items: stack.items, format: promptFormat)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount

        if clearStackOnCopy {
            clearAll()
        }

        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedConfirmation = false
        }
    }
}
