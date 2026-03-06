import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var stack = ContextStack()
    @Published var isMonitoring = false
    @Published var taskIntent = ""
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
    @Published var selectedInputDeviceID: UInt32 {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceID, forKey: "selectedInputDeviceID")
            voiceManager.inputDeviceID = selectedInputDeviceID == 0 ? nil : selectedInputDeviceID
        }
    }
    @Published var itemJustAdded = false
    @Published var isRecording = false

    /// Number of non-voiceNote items in the stack when a dictation session started (for clean dictation).
    private var clipboardItemCountAtSessionStart = 0

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
        let storedDeviceID = UInt32(UserDefaults.standard.integer(forKey: "selectedInputDeviceID"))
        self.selectedInputDeviceID = storedDeviceID
        if storedDeviceID != 0 {
            voiceManager.inputDeviceID = storedDeviceID
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

        // Stop Esc/keyUp monitors when recording ends
        voiceManager.$isRecording
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.hotkeyManager?.stopEscMonitor()
                self?.hotkeyManager?.stopKeyUpMonitor()
            }
            .store(in: &cancellables)

        if alwaysOnMonitoring {
            startMonitoring()
        }
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

    private func finishDictationAndStop() {
        hotkeyManager?.stopEscMonitor()
        hotkeyManager?.stopKeyUpMonitor()
        let itemCountBefore = clipboardItemCountAtSessionStart
        let isPushToTalk = pushToTalk
        let refs = pendingRefs
        pendingRefs = []
        voiceManager.stopRecording { [weak self] transcription in
            guard let self else { return }
            // Clean dictation: if push-to-talk and no clipboard items were added during session,
            // copy raw transcription directly instead of adding to stack
            let currentClipboardCount = self.stack.items.filter { $0.contentType != .voiceNote }.count
            if isPushToTalk && self.cleanDictation && currentClipboardCount == itemCountBefore {
                self.copyRawTranscription(transcription)
            } else {
                let markedText = self.insertRefMarkers(into: transcription, refs: refs)
                let item = ClipboardItem(contentType: .voiceNote, textContent: markedText)
                self.stack.add(item)
            }
        }
        stopMonitoring()
    }

    private func cancelDictation() {
        hotkeyManager?.stopEscMonitor()
        hotkeyManager?.stopKeyUpMonitor()
        pendingRefs = []
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

        var markers: [(charOffset: Int, refText: String)] = []
        for ref in refs {
            if let idx = stack.items.firstIndex(where: { $0.id == ref.itemID }) {
                markers.append((ref.charOffset, " [ref:\(idx + 1)]"))
            }
        }

        guard !markers.isEmpty else { return text }

        // Sort by offset descending so insertions don't shift earlier positions
        markers.sort { $0.charOffset > $1.charOffset }

        var result = text
        for marker in markers {
            let clampedOffset = min(marker.charOffset, result.count)
            let insertionIndex = result.index(result.startIndex, offsetBy: clampedOffset)
            result.insert(contentsOf: marker.refText, at: insertionIndex)
        }
        return result
    }

    func notifyItemAdded() {
        itemJustAdded = true
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            itemJustAdded = false
        }
    }

    /// Record a reference marker for a clipboard item captured during dictation.
    func recordRefMarker(for itemID: UUID) {
        guard voiceManager.isRecording else { return }
        let offset = voiceManager.partialTranscription.count
        pendingRefs.append(PendingRef(itemID: itemID, charOffset: offset))
    }

    func copyPromptToClipboard() {
        let prompt = PromptComposer.compose(task: taskIntent, items: stack.items)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount

        if clearStackOnCopy {
            stack.clear()
        }

        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedConfirmation = false
        }
    }
}
