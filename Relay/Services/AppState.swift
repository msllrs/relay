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
    @Published var captureClipboardOnStart: Bool {
        didSet { UserDefaults.standard.set(captureClipboardOnStart, forKey: "captureClipboardOnStart") }
    }
    @Published var autoCopyDictation: Bool {
        didSet { UserDefaults.standard.set(autoCopyDictation, forKey: "autoCopyDictation") }
    }
    @Published var autoCopyComposedPrompt: Bool {
        didSet { UserDefaults.standard.set(autoCopyComposedPrompt, forKey: "autoCopyComposedPrompt") }
    }
    @Published var autoPasteAfterCopy: Bool {
        didSet { UserDefaults.standard.set(autoPasteAfterCopy, forKey: "autoPasteAfterCopy") }
    }
    @Published var promptFormat: PromptFormat {
        didSet { UserDefaults.standard.set(promptFormat.rawValue, forKey: "promptFormat") }
    }
    @Published var voiceNotePosition: VoiceNotePosition {
        didSet { UserDefaults.standard.set(voiceNotePosition.rawValue, forKey: "voiceNotePosition") }
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
    private var demoScenarioIndex = 0
    private static let demoScenarioCount = 2

    /// Accumulated transcription text from previous dictation sessions (before the current one).
    private var frozenTranscription = ""

    /// Number of characters in `partialTranscription` to skip (set when clearing mid-recording).
    private var transcriptionTrimOffset = 0

    /// ID of the placeholder voice note added when recording starts.
    private var activeVoiceNoteID: UUID?

    /// Tracks clipboard items that arrived during an active dictation session.
    private struct PendingRef {
        let itemID: UUID
        /// Seconds since recording started when this ref was captured.
        let timeOffset: TimeInterval
    }
    private var pendingRefs: [PendingRef] = []
    private var recordingStartTime: Date?
    private var copiedConfirmationTask: Task<Void, Never>?
    private var clearAfterCopyTask: Task<Void, Never>?

    let voiceManager = VoiceManager()
    private var clipboardMonitor: ClipboardMonitor?
    private(set) var hotkeyManager: HotkeyManager?
    private var cancellables = Set<AnyCancellable>()

    /// The change count to ignore (set after we write to the pasteboard)
    var lastWrittenChangeCount: Int?

    init() {
        self.clearStackOnCopy = UserDefaults.standard.bool(forKey: "clearStackOnCopy")
        self.alwaysOnMonitoring = UserDefaults.standard.bool(forKey: "alwaysOnMonitoring")
        if UserDefaults.standard.object(forKey: "hotkeyStartsDictation") == nil {
            self.hotkeyStartsDictation = true
        } else {
            self.hotkeyStartsDictation = UserDefaults.standard.bool(forKey: "hotkeyStartsDictation")
        }
        self.pushToTalk = UserDefaults.standard.bool(forKey: "pushToTalk")
        self.captureClipboardOnStart = UserDefaults.standard.bool(forKey: "captureClipboardOnStart")
        self.autoCopyDictation = UserDefaults.standard.bool(forKey: "autoCopyDictation")
        self.autoCopyComposedPrompt = UserDefaults.standard.bool(forKey: "autoCopyComposedPrompt")
        self.autoPasteAfterCopy = UserDefaults.standard.bool(forKey: "autoPasteAfterCopy")
        if UserDefaults.standard.object(forKey: "maxMicOnRecord") == nil {
            self.maxMicOnRecord = true
        } else {
            self.maxMicOnRecord = UserDefaults.standard.bool(forKey: "maxMicOnRecord")
        }
        self.promptFormat = PromptFormat(rawValue: UserDefaults.standard.string(forKey: "promptFormat") ?? "") ?? .markdown
        self.voiceNotePosition = VoiceNotePosition(rawValue: UserDefaults.standard.string(forKey: "voiceNotePosition") ?? "") ?? .top
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
        let scenario = demoScenarioIndex % Self.demoScenarioCount
        demoScenarioIndex += 1

        switch scenario {
        case 0: populateDemoShort()
        case 1: populateDemoLong()
        default: break
        }
    }

    private func populateDemoShort() {
        let items: [ClipboardItem] = [
            ClipboardItem(contentType: .agentation, textContent: """
                The page transition feels abrupt — the hero section snaps in without easing. Try a staggered fade-in with 60ms delay between elements and ease-out-cubic over 400ms. The SVG logo also pops in at full scale which feels jarring, consider scaling from 0.9 with opacity.
                """),
            ClipboardItem(contentType: .error, textContent: """
                TypeError: Cannot read properties of undefined (reading 'getBBox')
                    at SVGAnimator.init (src/lib/animator.ts:47:28)
                    at MountTransition.onMount (src/components/Hero.svelte:12:9)
                    at flush (node_modules/svelte/internal/index.js:89:5)
                """),
            ClipboardItem(contentType: .diff, textContent: """
                @@ -8,7 +8,11 @@ export function stagger(node, { delay = 60 }) {
                   return {
                     duration: 400,
                -    easing: linear,
                +    easing: cubicOut,
                     css: (t) => `
                -      opacity: ${t}
                +      opacity: ${t};
                +      transform: translateY(${(1 - t) * 12}px)
                     `
                """),
            ClipboardItem(contentType: .file, textContent: "src/components/Hero.svelte"),
            ClipboardItem(contentType: .image),
            ClipboardItem(contentType: .terminal, textContent: """
                $ npm run build
                vite v5.4.2 building for production...
                ✓ 43 modules transformed
                dist/assets/index-Dk4zR91e.js  24.8 kB │ gzip: 8.12 kB
                ✓ built in 820ms
                """),
            ClipboardItem(contentType: .voiceNote, textContent: "OK so agentation flagged the page transition as too abrupt and the SVG logo pop-in, I've got the stagger fix with cubic easing in this diff but the animator is throwing a getBBox error on mount, need to defer the SVG init until after the DOM is ready"),
        ]
        for item in items {
            stack.add(item)
        }

        let demoTranscription = "OK so [ref:1] the transition feels way too abrupt and the SVG logo just pops in, I've got this diff [ref:3] with a stagger fix using cubic easing but [ref:2] it's throwing a getBBox error when it tries to mount so I need to update [ref:4] to defer the SVG init until the DOM is ready, here's the current state [ref:5] and yeah [ref:6] build is clean so we're good there"
        frozenTranscription = demoTranscription
        displayTranscription = demoTranscription
    }

    private func populateDemoLong() {
        let items: [ClipboardItem] = [
            ClipboardItem(contentType: .code, textContent: """
                func handleAuth(_ request: Request) async throws -> Response {
                    guard let token = request.headers.bearerAuthorization else {
                        throw Abort(.unauthorized)
                    }
                    let payload = try request.jwt.verify(token.token, as: UserPayload.self)
                    let user = try await User.find(payload.userID, on: request.db)
                    return try await user.toResponse()
                }
                """),
            ClipboardItem(contentType: .error, textContent: """
                FATAL: password authentication failed for user "relay_prod"
                    at Connection.parseE (node_modules/pg/lib/connection.js:614:13)
                    at Connection.parseMessage (node_modules/pg/lib/connection.js:413:19)
                """),
            ClipboardItem(contentType: .url, textContent: "https://developer.apple.com/documentation/authenticationservices"),
            ClipboardItem(contentType: .file, textContent: "Sources/App/Controllers/AuthController.swift"),
            ClipboardItem(contentType: .json, textContent: """
                {
                  "access_token": "eyJhbGciOiJIUzI1NiIs...",
                  "token_type": "bearer",
                  "expires_in": 3600,
                  "refresh_token": "dGhpcyBpcyBhIHJlZnJl..."
                }
                """),
            ClipboardItem(contentType: .diff, textContent: """
                @@ -12,6 +12,8 @@ struct AuthController {
                     func login(_ req: Request) async throws -> TokenResponse {
                +        let rateLimiter = req.application.rateLimiter
                +        try await rateLimiter.check(req.remoteAddress)
                         let credentials = try req.content.decode(LoginRequest.self)
                         guard let user = try await User.query(on: req.db)
                """),
            ClipboardItem(contentType: .terminal, textContent: """
                $ swift test --filter AuthTests
                Test Suite 'AuthTests' started at 2026-03-09 10:42:18
                Test Case 'testLoginSuccess' passed (0.234 seconds)
                Test Case 'testLoginInvalidPassword' passed (0.112 seconds)
                Test Case 'testTokenRefresh' FAILED (0.089 seconds)
                Test Case 'testRateLimiting' passed (1.203 seconds)
                """),
            ClipboardItem(contentType: .image),
            ClipboardItem(contentType: .text, textContent: "Need to rotate the prod DB credentials before deploying the auth changes — current password was last rotated 90+ days ago."),
            ClipboardItem(contentType: .voiceNote, textContent: "Walking through the auth refactor with rate limiting and JWT refresh token rotation"),
        ]
        for item in items {
            stack.add(item)
        }

        let demoTranscription = "Alright so I'm working on this auth refactor [ref:4] and the main issue is the login handler [ref:1] needs rate limiting before we go to prod, I've added that in this diff [ref:6] with the rate limiter middleware. But we're also hitting [ref:2] this postgres auth failure in staging which is a separate issue, [ref:9] we need to rotate those credentials before deploying. I've been reading through [ref:3] the Apple auth services docs for the SSO integration that's coming next sprint. The JWT response shape [ref:5] looks good but [ref:7] the token refresh test is failing, need to dig into that. Here's the current test output and [ref:8] a screenshot of the auth flow diagram I sketched out. Overall the rate limiting and credential rotation are the blockers, the refresh token bug is lower priority but should be fixed before merge. Actually let me walk through the flow in more detail. So when a user hits the login endpoint [ref:1] we first check the rate limiter [ref:6] which tracks attempts per IP address using a sliding window of 60 seconds. If they exceed 10 attempts we return a 429 with a retry-after header. Then we validate credentials against the database and if everything checks out we mint a new JWT [ref:5] with a 1 hour expiry plus a refresh token that lasts 30 days. The refresh flow is where things get tricky because [ref:7] the test expects the old refresh token to be invalidated after use but right now we're not doing token rotation properly so the same refresh token works multiple times which is a security issue. I need to add a token family tracking mechanism so we can detect reuse and invalidate the whole family if someone tries to replay an old token. Also [ref:3] the Apple SSO integration is going to need a separate auth provider abstraction because right now everything assumes username and password but with Sign in with Apple we get an identity token that we need to verify against Apple's public keys and then create or link a local user account"
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
            pendingRefs = []
            transcriptionTrimOffset = 0
            recordingStartTime = Date()
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
        let refs = pendingRefs
        pendingRefs = []
        let voiceNoteID = activeVoiceNoteID
        activeVoiceNoteID = nil
        let trimOffset = transcriptionTrimOffset
        transcriptionTrimOffset = 0
        voiceManager.stopRecording { [weak self] fullTranscription in
            guard let self else { return }
            let transcription = trimOffset > 0
                ? String(fullTranscription.dropFirst(min(trimOffset, fullTranscription.count)))
                    .trimmingCharacters(in: .whitespaces)
                : fullTranscription

            // Nothing new was said after a clear — remove the empty placeholder
            if transcription.isEmpty, let id = voiceNoteID {
                self.stack.remove(id: id)
                return
            }

            if let id = voiceNoteID {
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

    private func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount
    }

    private func flashCopiedConfirmation() {
        copiedConfirmationTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showCopiedConfirmation = true
        }
        copiedConfirmationTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                showCopiedConfirmation = false
            }
        }
    }

    private nonisolated func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
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

        // Convert time offsets to character positions proportionally.
        // This works for all engines: Native streams text continuously so the
        // proportion is accurate, while Parakeet delivers text in chunks so
        // time-based positioning distributes chips correctly.
        let totalElapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 1
        let textLength = text.count

        var markers: [(charOffset: Int, refText: String)] = []
        for ref in refs {
            if let idx = indexByID[ref.itemID] {
                let charOffset: Int
                if totalElapsed > 0 && textLength > 0 {
                    charOffset = min(Int((ref.timeOffset / totalElapsed) * Double(textLength)), textLength)
                } else {
                    charOffset = textLength
                }
                markers.append((charOffset, " [ref:\(idx)]"))
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

    /// Add an item to the stack, record a ref marker if recording, and flash the badge.
    func addItem(_ item: ClipboardItem) {
        let wasEmpty = displayTranscription.isEmpty && !stack.hasNonVoiceItems
        if wasEmpty {
            withAnimation(.easeInOut(duration: 0.25)) {
                stack.add(item)
            }
        } else {
            stack.add(item)
        }
        recordRefMarker(for: item.id)
        notifyItemAdded()
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

        // Auto-copy after dictation: composed prompt takes priority when both are on
        if autoCopyComposedPrompt {

            copyPromptToClipboard()
        } else if autoCopyDictation {

            let rawText = frozenTranscription.replacing(/\s?\[ref:\d+\]/, with: "")
            writeToClipboard(rawText)
            flashCopiedConfirmation()
        }

        if (autoCopyDictation || autoCopyComposedPrompt) && autoPasteAfterCopy {
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                simulatePaste()
            }
        }
    }

    /// Record a reference marker for a clipboard item captured during dictation.
    func recordRefMarker(for itemID: UUID) {
        guard voiceManager.isRecording else { return }
        let elapsed = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        pendingRefs.append(PendingRef(itemID: itemID, timeOffset: elapsed))
        rebuildDisplayTranscription()
    }

    /// Rebuild `displayTranscription` by splicing pending ref markers into live partial text.
    private func rebuildDisplayTranscription() {
        guard voiceManager.isRecording else { return }
        let full = voiceManager.partialTranscription
        let trimmed = full.count > transcriptionTrimOffset
            ? String(full.dropFirst(transcriptionTrimOffset)).trimmingCharacters(in: .whitespaces)
            : ""
        let currentSession = insertRefMarkers(into: trimmed, refs: pendingRefs)
        let newText = frozenTranscription.isEmpty
            ? currentSession
            : frozenTranscription + " " + currentSession

        // Animate the structural transition when content first appears,
        // so the popover height grows smoothly instead of snapping.
        let wasEmpty = displayTranscription.isEmpty
        if wasEmpty && !newText.isEmpty {
            withAnimation(.easeInOut(duration: 0.25)) {
                displayTranscription = newText
            }
        } else {
            displayTranscription = newText
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
        pendingRefs = []

        // If recording, add a fresh placeholder and skip already-transcribed text
        if voiceManager.isRecording {
            transcriptionTrimOffset = voiceManager.partialTranscription.count
            let placeholder = ClipboardItem(contentType: .voiceNote, textContent: "")
            activeVoiceNoteID = placeholder.id
            stack.add(placeholder)
        } else {
            activeVoiceNoteID = nil
        }
    }

    func copyPromptToClipboard() {
        // If recording, snapshot the live transcription into the voice note
        // so the composer includes the in-progress text.
        if voiceManager.isRecording, let id = activeVoiceNoteID {
            let full = voiceManager.partialTranscription
            let trimmed = full.count > transcriptionTrimOffset
                ? String(full.dropFirst(transcriptionTrimOffset)).trimmingCharacters(in: .whitespaces)
                : ""
            let markedText = insertRefMarkers(into: trimmed, refs: pendingRefs)
            stack.update(id: id, textContent: markedText)
        }

        // If the only item is a voice note, just copy the raw text
        let onlyVoiceNote = stack.items.count == 1
            && stack.items[0].contentType == .voiceNote
        let prompt = onlyVoiceNote
            ? (stack.items[0].textContent ?? "")
            : PromptComposer.compose(items: stack.items, format: promptFormat, voiceNotePosition: voiceNotePosition)
        writeToClipboard(prompt)

        flashCopiedConfirmation()

        if clearStackOnCopy {
            // Delay the clear so the Copied banner can fully appear before content collapses.
            // This prevents the banner, divider, and transcription from overlapping mid-animation.
            clearAfterCopyTask?.cancel()
            clearAfterCopyTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    clearAll()
                }
            }
        }
    }
}
