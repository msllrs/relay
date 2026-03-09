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
    private var demoScenarioIndex = 0
    private static let demoScenarioCount = 2

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
        writeToClipboard(text)
        flashCopiedConfirmation()
    }

    private func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount
    }

    private func flashCopiedConfirmation() {
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
        writeToClipboard(text)
        stack.clear()
        frozenTranscription = ""
        displayTranscription = ""
        flashCopiedConfirmation()
    }

    /// Add an item to the stack, record a ref marker if recording, and flash the badge.
    func addItem(_ item: ClipboardItem) {
        stack.add(item)
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
        writeToClipboard(prompt)

        if clearStackOnCopy {
            clearAll()
        } else {
            flashCopiedConfirmation()
        }
    }
}
