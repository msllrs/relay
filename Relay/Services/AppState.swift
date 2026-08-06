import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

/// A line in the rolling capture history shown in settings.
struct CaptureHistoryEntry: Identifiable, Equatable, Codable {
    var id = UUID()
    let contentType: ContentType
    /// Single-line summary for the settings list.
    let preview: String
    let textContent: String?
    let imagePath: String?
    let timestamp: Date
    /// For voice notes: the app that was focused when dictation happened.
    var sourceAppName: String?
}

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
    /// Opt-out (default on): short chirps when recording starts and stops.
    @Published var recordingSounds: Bool {
        didSet { UserDefaults.standard.set(recordingSounds, forKey: "recordingSounds") }
    }
    @Published var recordingSoundTheme: RecordingSoundTheme {
        didSet {
            UserDefaults.standard.set(recordingSoundTheme.rawValue, forKey: "recordingSoundTheme")
            soundFeedback.setTheme(recordingSoundTheme)
            // Immediate audition when picking from the settings menu
            soundFeedback.playStart()
        }
    }
    /// Opt-in: lower the system output volume while recording so music or
    /// video audio doesn't bleed into the transcript.
    @Published var duckAudioOnRecord: Bool {
        didSet { UserDefaults.standard.set(duckAudioOnRecord, forKey: "duckAudioOnRecord") }
    }
    /// Output volume before ducking, for restore. Nil when not ducked.
    private var preDuckOutputVolume: Float?
    /// Opt-in: end the dictation automatically after ~3s of silence, once
    /// some speech has been transcribed. Ignored in push-to-talk (the held
    /// key already defines the session length).
    @Published var autoStopOnSilence: Bool {
        didSet { UserDefaults.standard.set(autoStopOnSilence, forKey: "autoStopOnSilence") }
    }
    /// Seconds of sustained silence before auto-stop ends the session.
    @Published var autoStopSilenceDuration: Double {
        didSet { UserDefaults.standard.set(autoStopSilenceDuration, forKey: "autoStopSilenceDuration") }
    }
    /// Loudest level seen this session — silence is judged relative to it,
    /// so the detector adapts to mic gain and distance.
    private var sessionPeakLevel: Float = 0
    private var silenceGate = SilenceGate()
    @Published var hotkeyStartsDictation: Bool {
        didSet { UserDefaults.standard.set(hotkeyStartsDictation, forKey: "hotkeyStartsDictation") }
    }
    @Published var pushToTalk: Bool {
        didSet { UserDefaults.standard.set(pushToTalk, forKey: "pushToTalk") }
    }
    @Published var captureClipboardOnStart: Bool {
        didSet { UserDefaults.standard.set(captureClipboardOnStart, forKey: "captureClipboardOnStart") }
    }
    /// Opt-out (default on): screenshots taken while recording are added to
    /// the stack automatically, saving users from needing to know that ⌃
    /// sends a capture to the clipboard.
    @Published var captureScreenshotsWhileRecording: Bool {
        didSet { UserDefaults.standard.set(captureScreenshotsWhileRecording, forKey: "captureScreenshotsWhileRecording") }
    }
    @Published var autoCopy: Bool {
        didSet { UserDefaults.standard.set(autoCopy, forKey: "autoCopy") }
    }
    @Published var autoPasteAfterCopy: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteAfterCopy, forKey: "autoPasteAfterCopy")
            if autoPasteAfterCopy && !AXIsProcessTrusted() {
                promptForAccessibility()
            }
        }
    }
    /// Opt-in: holding ⇧ while the auto-paste lands also presses Return,
    /// submitting the pasted prompt (e.g. into a chat input).
    @Published var sendAfterPasteWithShift: Bool {
        didSet { UserDefaults.standard.set(sendAfterPasteWithShift, forKey: "sendAfterPasteWithShift") }
    }
    /// Opt-in: put whatever was on the clipboard before dictation back after
    /// the auto-paste lands. Off by default — keeping the prompt on the
    /// clipboard is Relay's normal contract.
    @Published var restoreClipboardAfterPaste: Bool {
        didSet { UserDefaults.standard.set(restoreClipboardAfterPaste, forKey: "restoreClipboardAfterPaste") }
    }
    @Published var pinPopover: Bool {
        didSet { UserDefaults.standard.set(pinPopover, forKey: "pinPopover") }
    }
    @Published var showRecordingOverlay: Bool {
        didSet { UserDefaults.standard.set(showRecordingOverlay, forKey: "showRecordingOverlay") }
    }
    /// Opt-out (default on): close the popover shortly after copying, once the
    /// Copied confirmation has had a moment to flash.
    @Published var closePopoverOnCopy: Bool {
        didSet { UserDefaults.standard.set(closePopoverOnCopy, forKey: "closePopoverOnCopy") }
    }
    /// Signals the app delegate to close the popover (it owns the NSPopover).
    let popoverCloseRequests = PassthroughSubject<Void, Never>()
    /// Opt-in: show Relay in the Dock and app switcher. Off means menu bar only
    /// (the LSUIElement default).
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyDockVisibility()
        }
    }
    /// Opt-in: left-clicking the menu bar icon starts/stops recording instead of
    /// opening the popover (right-click still opens it).
    @Published var startRecordingOnMenubarClick: Bool {
        didSet { UserDefaults.standard.set(startRecordingOnMenubarClick, forKey: "startRecordingOnMenubarClick") }
    }
    /// Opt-in: register as a login item. The SMAppService registration is the
    /// source of truth (visible in System Settings > General > Login Items),
    /// so this isn't persisted to UserDefaults.
    @Published var launchAtLogin: Bool {
        didSet {
            // Guard against the revert-on-failure below re-entering didSet.
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Launch at login toggle failed: %@", error.localizedDescription)
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }
    @Published var promptFormat: PromptFormat {
        didSet { UserDefaults.standard.set(promptFormat.rawValue, forKey: "promptFormat") }
    }
    @Published var voiceNotePosition: VoiceNotePosition {
        didSet { UserDefaults.standard.set(voiceNotePosition.rawValue, forKey: "voiceNotePosition") }
    }
    @Published var transcriptEnhancement: TranscriptEnhancement {
        didSet { UserDefaults.standard.set(transcriptEnhancement.rawValue, forKey: "transcriptEnhancement") }
    }
    /// Opt-in: resolve spoken self-corrections ("…20 pixels, scratch that,
    /// 8 pixels") in finished transcripts. Heuristic on-device pass
    /// everywhere; Apple's on-device model handles fuzzier phrasing when
    /// available. Entirely local either way.
    @Published var resolveSelfCorrections: Bool {
        didSet { UserDefaults.standard.set(resolveSelfCorrections, forKey: "resolveSelfCorrections") }
    }
    /// Custom dictionary: user-defined filler removals and word replacements,
    /// applied to every finished transcript before enhancement.
    @Published var wordRemovals: [WordRemovalRule] = WordRules.loadRemovals() {
        didSet { WordRules.save(removals: wordRemovals) }
    }
    @Published var wordRemappings: [WordRemappingRule] = WordRules.loadRemappings() {
        didSet { WordRules.save(remappings: wordRemappings) }
    }
    /// Terms the speech engines are biased toward recognizing.
    @Published var vocabularyTerms: [String] = VocabularyStore.load() {
        didSet { VocabularyStore.save(vocabularyTerms) }
    }
    /// Opt-in: after auto-paste, watch the target field and learn vocabulary
    /// from words the user manually corrects. Entirely on-device.
    @Published var learnFromCorrections: Bool {
        didSet {
            UserDefaults.standard.set(learnFromCorrections, forKey: "learnFromCorrections")
            CorrectionLearner.shared.isEnabled = learnFromCorrections
        }
    }
    @Published var selectedInputDeviceID: UInt32 {
        didSet {
            UserDefaults.standard.set(selectedInputDeviceID, forKey: "selectedInputDeviceID")
            let deviceID = selectedInputDeviceID == 0 ? nil : selectedInputDeviceID
            voiceManager.inputDeviceID = deviceID
            voiceManager.inputDeviceSwitched()
            PreRollAudioService.shared.deviceChanged(to: deviceID)
        }
    }
    /// Opt-in: keep the mic warm while idle so recordings include ~0.45s of
    /// audio from before the hotkey landed. Shows the mic-in-use indicator
    /// permanently, hence off by default.
    @Published var warmCapturePreRoll: Bool {
        didSet {
            UserDefaults.standard.set(warmCapturePreRoll, forKey: "warmCapturePreRoll")
            PreRollAudioService.shared.setEnabled(
                warmCapturePreRoll,
                deviceID: selectedInputDeviceID == 0 ? nil : selectedInputDeviceID
            )
        }
    }
    /// Live list of input devices, refreshed on hotplug so the settings picker never goes stale.
    @Published var availableInputDevices: [AudioDevice] = AudioDeviceManager.inputDevices()
    private let audioDeviceMonitor = AudioDeviceMonitor()
    @Published var mcpBridgeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(mcpBridgeEnabled, forKey: "mcpBridgeEnabled")
            if mcpBridgeEnabled {
                mcpBridgeWriter?.start()
            } else {
                mcpBridgeWriter?.stop()
            }
        }
    }
    private var mcpBridgeWriter: MCPBridgeWriter?
    /// Opt-in: allow relay:// URL commands (used by Siri Shortcuts) to control recording.
    @Published var siriActivationEnabled: Bool {
        didSet { UserDefaults.standard.set(siriActivationEnabled, forKey: "siriActivationEnabled") }
    }
    @Published var annotationEnabled: Bool {
        didSet { UserDefaults.standard.set(annotationEnabled, forKey: "annotationEnabled") }
    }
    @Published var annotateWhileRecording: Bool {
        didSet { UserDefaults.standard.set(annotateWhileRecording, forKey: "annotateWhileRecording") }
    }
    @Published var annotationCaptureScope: CaptureScope {
        didSet { UserDefaults.standard.set(annotationCaptureScope.rawValue, forKey: "annotationCaptureScope") }
    }
    @Published var annotationAllowMultiple: Bool {
        didSet { UserDefaults.standard.set(annotationAllowMultiple, forKey: "annotationAllowMultiple") }
    }
    /// Rolling history of the last 20 captures, newest first. In-memory only —
    /// clipboard contents can include secrets, so this is deliberately never
    /// persisted to disk.
    /// Loaded from disk at launch and saved on every change, so history
    /// survives quits and updates.
    @Published private(set) var captureHistory: [CaptureHistoryEntry] = CaptureHistoryStore.default.load() {
        didSet { CaptureHistoryStore.default.save(captureHistory) }
    }
    /// Rolling history of composed prompt outputs — what actually left Relay
    /// via copy or auto-paste — newest first, capped at 20.
    @Published private(set) var outputHistory: [CaptureHistoryEntry] = CaptureHistoryStore.outputs.load() {
        didSet { CaptureHistoryStore.outputs.save(outputHistory) }
    }
    @Published var itemJustAdded = false
    @Published var isRecording = false
    /// Which popover page is showing. Lifted here (not view state) so the app
    /// delegate can open the popover straight to settings on right-click.
    @Published var showSettings = false
    /// True while the popover is on screen (maintained by the app delegate).
    @Published var popoverVisible = false

    /// Page-switch animation for the main/settings cross-fade. Nil while the
    /// popover is hidden, so opening straight to a page (right-click →
    /// settings) shows it settled instead of replaying the transition.
    var pageTransitionAnimation: Animation? {
        popoverVisible ? .easeInOut(duration: 0.25) : nil
    }
    @Published var displayTranscription = ""
    /// True when accessibility permission appears granted in TCC but global NSEvent
    /// monitors are silently broken — happens after an app update invalidates the binary hash.
    @Published var accessibilityBroken = false
    @Published var accessibilityNotGranted = false
    @Published var needsScreenRecordingPermission = false

    /// Sync the activation policy with the Show in Dock setting. LSUIElement
    /// already makes the app accessory at launch, so this only matters when the
    /// user has opted in or toggles the setting.
    func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        // Dropping back to accessory deactivates the app, which would close the
        // transient settings popover mid-toggle — re-activate to keep it open.
        if !showInDock {
            NSApp.activate()
        }
    }

    /// Request accessibility with the system prompt. Unlike manually adding the
    /// app in System Settings, this registers a proper TCC entry for the app's
    /// current code signature.
    func promptForAccessibility() {
        // Literal key instead of kAXTrustedCheckOptionPrompt — the global var
        // isn't concurrency-safe under Swift 6 strict checking.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Event posting (the ⌘V fallback and ⇧-send Return) is a separate TCC
        // gate that can hold a stale silent deny even while accessibility is
        // granted — request it explicitly.
        if !CGPreflightPostEventAccess() {
            _ = CGRequestPostEventAccess()
        }
    }

    /// Re-check AXIsProcessTrusted() and update the published flag.
    /// Call this when the settings view appears so the banner clears
    /// promptly after the user grants permission.
    func refreshAccessibilityStatus() {
        accessibilityNotGranted = !AXIsProcessTrusted()
    }

    /// Refresh the input-device list on hotplug. If the selected device
    /// disappeared, fall back to System Default so the picker never shows
    /// an empty selection — and recover any in-flight recording.
    private func handleAudioDevicesChanged() {
        let devices = AudioDeviceManager.inputDevices()
        availableInputDevices = devices
        if selectedInputDeviceID != 0, !devices.contains(where: { $0.id == selectedInputDeviceID }) {
            // didSet moves any in-flight recording over to the default.
            selectedInputDeviceID = 0
        }
    }
    let isDemo = ProcessInfo.processInfo.environment["RELAY_DEMO"] == "1"
    private var demoScenarioIndex = 0
    private static let demoScenarioCount = 2

    /// Accumulated transcription text from previous dictation sessions (before the current one).
    private var frozenTranscription = ""

    /// Bumped whenever the dictation world changes under a pending finalize
    /// (new session started, stack cleared). Finalize Tasks capture the value
    /// at stop and compare on landing to detect that they're stale.
    private var dictationGeneration = 0

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
    /// Strike-then-remove treatment for live self-corrections (display only).
    private let liveCorrectionAnimator = LiveCorrectionAnimator()
    let updaterManager = UpdaterManager()
    private let screenshotWatcher = ScreenshotWatcher()
    private let soundFeedback = SoundFeedback()
    private var clipboardMonitor: ClipboardMonitor?
    private(set) var hotkeyManager: HotkeyManager?
    private(set) var annotationManager: AnnotationManager?
    private var cancellables = Set<AnyCancellable>()

    /// The change count to ignore (set after we write to the pasteboard)
    var lastWrittenChangeCount: Int?

    /// Last frontmost app other than Relay — the auto-paste target, and where
    /// focus returns after the popover closes. `NSApp.deactivate()` alone
    /// doesn't reliably restore focus (popover, Siri/URL activation), so we
    /// re-activate this app explicitly.
    private(set) var lastExternalApp: NSRunningApplication?

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
        if UserDefaults.standard.object(forKey: "captureScreenshotsWhileRecording") == nil {
            self.captureScreenshotsWhileRecording = true
        } else {
            self.captureScreenshotsWhileRecording = UserDefaults.standard.bool(forKey: "captureScreenshotsWhileRecording")
        }
        if UserDefaults.standard.object(forKey: "autoCopy") != nil {
            self.autoCopy = UserDefaults.standard.bool(forKey: "autoCopy")
        } else {
            // Migrate: enable if either old toggle was on
            self.autoCopy = UserDefaults.standard.bool(forKey: "autoCopyDictation")
                || UserDefaults.standard.bool(forKey: "autoCopyComposedPrompt")
        }
        self.autoPasteAfterCopy = UserDefaults.standard.bool(forKey: "autoPasteAfterCopy")
        self.sendAfterPasteWithShift = UserDefaults.standard.bool(forKey: "sendAfterPasteWithShift")
        self.restoreClipboardAfterPaste = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")
        self.warmCapturePreRoll = UserDefaults.standard.bool(forKey: "warmCapturePreRoll")
        self.learnFromCorrections = UserDefaults.standard.bool(forKey: "learnFromCorrections")
        CorrectionLearner.shared.isEnabled = UserDefaults.standard.bool(forKey: "learnFromCorrections")
        self.pinPopover = UserDefaults.standard.bool(forKey: "pinPopover")
        self.showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        self.startRecordingOnMenubarClick = UserDefaults.standard.bool(forKey: "startRecordingOnMenubarClick")
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        if UserDefaults.standard.object(forKey: "showRecordingOverlay") == nil {
            self.showRecordingOverlay = true
        } else {
            self.showRecordingOverlay = UserDefaults.standard.bool(forKey: "showRecordingOverlay")
        }
        if UserDefaults.standard.object(forKey: "closePopoverOnCopy") == nil {
            self.closePopoverOnCopy = true
        } else {
            self.closePopoverOnCopy = UserDefaults.standard.bool(forKey: "closePopoverOnCopy")
        }
        if UserDefaults.standard.object(forKey: "maxMicOnRecord") == nil {
            self.maxMicOnRecord = true
        } else {
            self.maxMicOnRecord = UserDefaults.standard.bool(forKey: "maxMicOnRecord")
        }
        if UserDefaults.standard.object(forKey: "recordingSounds") == nil {
            self.recordingSounds = true
        } else {
            self.recordingSounds = UserDefaults.standard.bool(forKey: "recordingSounds")
        }
        self.recordingSoundTheme = RecordingSoundTheme(
            rawValue: UserDefaults.standard.string(forKey: "recordingSoundTheme") ?? ""
        ) ?? .circuit
        self.duckAudioOnRecord = UserDefaults.standard.bool(forKey: "duckAudioOnRecord")
        self.autoStopOnSilence = UserDefaults.standard.bool(forKey: "autoStopOnSilence")
        let storedSilenceDuration = UserDefaults.standard.double(forKey: "autoStopSilenceDuration")
        self.autoStopSilenceDuration = storedSilenceDuration > 0 ? storedSilenceDuration : 3.0
        self.promptFormat = PromptFormat(rawValue: UserDefaults.standard.string(forKey: "promptFormat") ?? "") ?? .markdown
        self.voiceNotePosition = VoiceNotePosition(rawValue: UserDefaults.standard.string(forKey: "voiceNotePosition") ?? "") ?? .top
        self.transcriptEnhancement = TranscriptEnhancement(rawValue: UserDefaults.standard.string(forKey: "transcriptEnhancement") ?? "") ?? .off
        self.resolveSelfCorrections = UserDefaults.standard.bool(forKey: "resolveSelfCorrections")
        self.mcpBridgeEnabled = UserDefaults.standard.bool(forKey: "mcpBridgeEnabled")
        self.siriActivationEnabled = UserDefaults.standard.bool(forKey: "siriActivationEnabled")
        self.annotationEnabled = UserDefaults.standard.bool(forKey: "annotationEnabled")
        if UserDefaults.standard.object(forKey: "annotateWhileRecording") == nil {
            self.annotateWhileRecording = true
        } else {
            self.annotateWhileRecording = UserDefaults.standard.bool(forKey: "annotateWhileRecording")
        }
        self.annotationCaptureScope = CaptureScope(rawValue: UserDefaults.standard.string(forKey: "annotationCaptureScope") ?? "") ?? .crop
        self.annotationAllowMultiple = UserDefaults.standard.bool(forKey: "annotationAllowMultiple")
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
        // Track device hotplug and default-input changes so the selection and
        // any in-flight recording stay valid when devices come and go.
        audioDeviceMonitor.onDevicesChanged = { [weak self] in
            self?.handleAudioDevicesChanged()
        }
        audioDeviceMonitor.onDefaultInputDeviceChanged = { [weak self] in
            guard let self else { return }
            // The selection always follows the system default — including from
            // "System Default" (0) — so external switches (System Settings,
            // Raycast's "Set Input Device", AirPods auto-switch) snap the picker
            // to the new concrete device. didSet handles persistence, the
            // picker, and moving any in-flight recording and warm capture over.
            if let newDefault = SystemAudioHelper.defaultInputDevice(),
               newDefault != self.selectedInputDeviceID,
               self.availableInputDevices.contains(where: { $0.id == newDefault }) {
                self.selectedInputDeviceID = newDefault
            } else {
                self.voiceManager.defaultInputDeviceChanged()
                // Warm capture on the system default follows it too.
                if self.selectedInputDeviceID == 0 {
                    PreRollAudioService.shared.deviceChanged(to: UInt32?.none)
                }
            }
        }
        audioDeviceMonitor.start()

        if warmCapturePreRoll {
            PreRollAudioService.shared.setEnabled(
                true,
                deviceID: selectedInputDeviceID == 0 ? nil : selectedInputDeviceID
            )
        }

        // Track the frontmost non-Relay app so auto-paste can hand focus back
        // to it. Observer lives for the app's lifetime (AppState never deallocates).
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = frontmost
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            MainActor.assumeIsolated {
                self.lastExternalApp = app
            }
        }

        clipboardMonitor = ClipboardMonitor(appState: self)
        hotkeyManager = HotkeyManager(appState: self)
        annotationManager = AnnotationManager(appState: self)
        mcpBridgeWriter = MCPBridgeWriter(appState: self)
        if mcpBridgeEnabled { mcpBridgeWriter?.start() }

        // Forward stack changes so SwiftUI picks them up
        stack.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward voiceManager changes so SwiftUI picks them up
        voiceManager.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward annotationManager changes (e.g. session active state)
        annotationManager?.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Stop the annotation key-up monitor whenever a session ends (covers the
        // Return/Esc finish paths that don't go through the release callback).
        annotationManager?.$isSessionActive
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in self?.hotkeyManager?.stopAnnotateKeyUpMonitor() }
            .store(in: &cancellables)

        // Mirror voiceManager.isRecording so SwiftUI can track it
        voiceManager.$isRecording
            .assign(to: &$isRecording)

        // Rebuild display transcription as partial results stream in
        voiceManager.$partialTranscription
            .sink { [weak self] _ in self?.rebuildDisplayTranscription() }
            .store(in: &cancellables)

        // Live self-correction strikethrough: rebuild when a strike hold
        // expires (there may be no new partial to trigger it), and start
        // each session with a clean slate.
        liveCorrectionAnimator.onNeedsRefresh = { [weak self] in
            self?.rebuildDisplayTranscription()
        }
        voiceManager.$isRecording
            .dropFirst()
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in self?.liveCorrectionAnimator.reset() }
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

        // didSet doesn't fire during init — apply the persisted theme now.
        soundFeedback.setTheme(recordingSoundTheme)

        // Start/stop chirps for eyes-free confirmation (Siri, Dock, hotkey).
        // Ducking is sequenced around them so the chirps stay audible: duck
        // shortly AFTER the start chirp, restore BEFORE the stop chirp.
        voiceManager.$isRecording
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] recording in
                guard let self else { return }
                if recording {
                    if self.recordingSounds {
                        self.soundFeedback.playStart()
                    }
                    if self.duckAudioOnRecord, let current = SystemAudioHelper.getOutputVolume() {
                        self.preDuckOutputVolume = current
                        Task { [weak self] in
                            try? await Task.sleep(for: .milliseconds(250))
                            guard let self, self.voiceManager.isRecording else { return }
                            SystemAudioHelper.setOutputVolume(current * 0.2)
                        }
                    }
                } else {
                    if let restore = self.preDuckOutputVolume {
                        SystemAudioHelper.setOutputVolume(restore)
                        self.preDuckOutputVolume = nil
                    }
                    if self.recordingSounds {
                        self.soundFeedback.playStop()
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-stop after sustained silence. Armed only once speech has been
        // transcribed, thresholded relative to the session's peak level, and
        // skipped for push-to-talk where the held key ends the session.
        voiceManager.$audioLevel
            .sink { [weak self] level in
                guard let self,
                      self.autoStopOnSilence,
                      !self.pushToTalk,
                      self.voiceManager.isRecording else {
                    self?.silenceGate.reset()
                    return
                }
                self.sessionPeakLevel = max(self.sessionPeakLevel, level)
                guard !self.voiceManager.partialTranscription.isEmpty else { return }

                let threshold = max(0.015, self.sessionPeakLevel * 0.15)
                let silentFor = self.silenceGate.process(isQuiet: level < threshold)
                if silentFor > self.autoStopSilenceDuration {
                    self.silenceGate.reset()
                    self.finishDictationAndStop()
                }
            }
            .store(in: &cancellables)

        // Ingest screenshots taken during a recording session
        screenshotWatcher.onScreenshot = { [weak self] url in
            guard let self, self.captureScreenshotsWhileRecording else { return }
            self.addItem(.fromFileURL(url))
        }
        voiceManager.$isRecording
            .removeDuplicates()
            .sink { [weak self] recording in
                guard let self else { return }
                if recording && self.captureScreenshotsWhileRecording {
                    self.screenshotWatcher.start()
                } else {
                    self.screenshotWatcher.stop()
                }
            }
            .store(in: &cancellables)

        // Arm/disarm the click-through annotation overlay around recording.
        voiceManager.$isRecording
            .dropFirst()
            .sink { [weak self] recording in
                guard let self else { return }
                if recording {
                    if self.annotationEnabled && self.annotateWhileRecording {
                        self.annotationManager?.armForRecording()
                    }
                } else {
                    self.annotationManager?.disarmForRecording()
                }
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

    /// Called by HotkeyManager when the annotation shortcut is pressed.
    /// Push-to-draw: begin a session and end (or commit) it when released.
    func annotateHotkeyTriggered() {
        guard annotationEnabled else { return }
        let wasActive = annotationManager?.isSessionActive == true
        annotationManager?.beginHold()
        guard annotationManager?.isSessionActive == true else { return }
        // Install the release monitor once per session. In multi mode it stays
        // armed across holds; each release commits a mark and the session lives
        // on until Return/Esc, so we only stop the monitor when the session ends.
        if !wasActive {
            hotkeyManager?.startAnnotateKeyUpMonitor { [weak self] in
                guard let self else { return }
                self.annotationManager?.finishHold()
                if self.annotationManager?.isSessionActive != true {
                    self.hotkeyManager?.stopAnnotateKeyUpMonitor()
                }
            }
        }
    }

    /// Called by HotkeyManager when the keyboard shortcut is pressed.
    func hotkeyTriggered() {
        if isMonitoring && voiceManager.isRecording {
            // Already recording → stop, save transcription, stop monitoring
            finishDictationAndStop()
        } else if hotkeyStartsDictation && !isMonitoring {
            startDictation()
        } else {
            toggleMonitoring()
        }
    }

    /// Start monitoring and begin a dictation session. Shared by the hotkey
    /// path and external triggers (relay:// URL commands).
    /// - Parameter installPushToTalkMonitor: push-to-talk only makes sense when
    ///   a key is physically held, so URL-triggered sessions pass false.
    func startDictation(installPushToTalkMonitor: Bool = true) {
        // Re-entrancy guard on the synchronous placeholder, not on
        // voiceManager.isRecording (which flips true only after the async
        // engine start): rapid triggers — e.g. queued URL commands delivered
        // in a burst — would otherwise stack placeholders and restart the
        // engine mid-session, killing the recording.
        guard activeVoiceNoteID == nil else { return }
        dictationGeneration += 1
        if !isMonitoring {
            startMonitoring()
        }
        pendingRefs = []
        transcriptionTrimOffset = 0
        recordingStartTime = Date()
        sessionPeakLevel = 0
        silenceGate.reset()
        // Reserve a placeholder in the stack so the voice note keeps its position
        let placeholder = ClipboardItem(contentType: .voiceNote, textContent: "")
        activeVoiceNoteID = placeholder.id
        stack.add(placeholder)
        voiceManager.startRecording()
        // Install Esc monitor to cancel
        hotkeyManager?.startEscMonitor { [weak self] in
            withAnimation(.easeInOut(duration: 0.25)) {
                self?.cancelDictation()
            }
        }
        // Install keyUp monitor for push-to-talk
        if installPushToTalkMonitor && pushToTalk {
            hotkeyManager?.startKeyUpMonitor { [weak self] in
                self?.finishDictationAndStop()
            }
        }
    }

    /// Handle a relay:// URL command (Siri Shortcuts, Raycast, scripts).
    /// Ignored unless the user has opted in via the Siri activation setting.
    func handleURLCommand(_ url: URL) {
        guard siriActivationEnabled else {
            NSLog("Ignoring URL command %@ — Siri activation is disabled in settings", url.absoluteString)
            return
        }
        switch url.host() {
        case "start-recording":
            guard !voiceManager.isRecording else { return }
            startDictation(installPushToTalkMonitor: false)
        case "stop-recording":
            guard voiceManager.isRecording else { return }
            finishDictationAndStop()
        case "toggle-recording":
            if voiceManager.isRecording {
                finishDictationAndStop()
            } else {
                startDictation(installPushToTalkMonitor: false)
            }
        case "paste-last-transcript":
            pasteLastTranscript()
        default:
            NSLog("Unknown URL command: %@", url.absoluteString)
        }
    }

    /// Re-copy the most recent dictation and paste it into the focused input.
    /// The recovery path when a paste failed or landed in the wrong window.
    func pasteLastTranscript() {
        guard let entry = captureHistory.first(where: { $0.contentType == .voiceNote }),
              let text = entry.textContent, !text.isEmpty else { return }
        writeToClipboard(text)
        if AXIsProcessTrusted() {
            autoPasteToFocusedInput()
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
        let generationAtStop = dictationGeneration
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

            let markedRaw = self.insertRefMarkers(into: transcription, refs: refs)
            Task { @MainActor [weak self] in
                guard let self else { return }
                var working = markedRaw
                // Self-corrections resolve before word rules and filler
                // stripping, which would otherwise eat cue words like
                // "actually". Gated on a cue so ordinary dictations skip it.
                if self.resolveSelfCorrections, SelfCorrectionResolver.containsCue(working) {
                    var resolved: String?
                    // AI Polish resolves corrections itself; don't spend a
                    // second model call when it's about to run anyway.
                    if self.transcriptEnhancement != .aiPolish {
                        resolved = await FoundationModelsEnhancer.resolveCorrections(working)
                    }
                    working = resolved ?? SelfCorrectionResolver.resolve(working)
                }
                let markedInput = WordRules.apply(
                    working,
                    removals: self.wordRemovals,
                    remappings: self.wordRemappings
                )
                let markedText = await TranscriptEnhancer.enhanceAsync(
                    markedInput,
                    level: self.transcriptEnhancement
                )
                // The awaits above can take seconds; the world may have moved
                // on (new recording, stack cleared). A stale finalize must not
                // re-freeze old text into the display or fire the auto-copy
                // chain against a half-finished new session.
                let stillPresent = voiceNoteID.map { id in self.stack.items.contains { $0.id == id } } ?? true
                let action = DictationFinalizePolicy.decide(.init(
                    generationAtStop: generationAtStop,
                    generationNow: self.dictationGeneration,
                    isRecording: self.voiceManager.isRecording,
                    placeholderStillInStack: stillPresent
                ))

                switch action {
                case .historyOnly:
                    // The item was cleared away mid-finalize — putting it back
                    // would undo the clear. History keeps the text recoverable.
                    self.recordInHistory(ClipboardItem(contentType: .voiceNote, textContent: markedText))
                case .accumulate:
                    // A newer session owns delivery: keep the text and the
                    // accumulated transcript current, but no freeze/auto-copy.
                    if let id = voiceNoteID {
                        self.stack.update(id: id, textContent: markedText)
                    } else {
                        self.stack.add(ClipboardItem(contentType: .voiceNote, textContent: markedText))
                    }
                    self.recordInHistory(ClipboardItem(contentType: .voiceNote, textContent: markedText))
                    self.appendToFrozenTranscription(markedText)
                case .deliver:
                    if let id = voiceNoteID {
                        self.stack.update(id: id, textContent: markedText)
                        self.recordInHistory(ClipboardItem(contentType: .voiceNote, textContent: markedText))
                    } else {
                        let item = ClipboardItem(contentType: .voiceNote, textContent: markedText)
                        self.stack.add(item)
                        self.recordInHistory(item)
                    }
                    self.freezeCurrentSession(markedText)
                }
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

    /// Session ID of the most recent clipboard write, for restore ownership checks.
    private var pasteSessionID: String = ""
    /// Clipboard contents captured just before an auto-paste write, restored
    /// after the paste lands when `restoreClipboardAfterPaste` is on.
    private var preWriteSnapshot: PasteboardHelper.Snapshot?

    private func writeToClipboard(_ text: String) {
        if restoreClipboardAfterPaste, autoCopy, autoPasteAfterCopy {
            preWriteSnapshot = PasteboardHelper.snapshot()
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteSessionID = UUID().uuidString
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(pasteSessionID, forType: PasteboardHelper.sessionMarkerType)
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
        recordInHistory(item)
    }

    /// Append a capture to the rolling history (newest first, capped at 20).
    private func recordInHistory(_ item: ClipboardItem) {
        let trimmed = item.textContent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview: String
        if let trimmed, !trimmed.isEmpty {
            let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
            preview = String(firstLine.prefix(100))
        } else if let path = item.imagePath {
            preview = "Image — \((path as NSString).lastPathComponent)"
        } else {
            return
        }
        let entry = CaptureHistoryEntry(
            contentType: item.contentType,
            preview: preview,
            textContent: item.textContent,
            imagePath: item.imagePath,
            timestamp: item.timestamp,
            sourceAppName: item.contentType == .voiceNote ? lastExternalApp?.localizedName : nil
        )
        captureHistory.insert(entry, at: 0)
        if captureHistory.count > 20 {
            captureHistory.removeLast(captureHistory.count - 20)
        }
    }

    /// Append a composed prompt to the output history (newest first, capped
    /// at 20). Copying the same prompt twice keeps one entry.
    private func recordOutputInHistory(_ prompt: String) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, outputHistory.first?.textContent != prompt else { return }
        // Prefer the first content line over structural markup (<context>, ## …)
        // so the preview reads as what was said, not how it was wrapped.
        let lines = trimmed.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let previewLine = lines.first { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("#") }
            ?? lines.first ?? trimmed
        let entry = CaptureHistoryEntry(
            contentType: .text,
            preview: String(previewLine.prefix(100)),
            textContent: prompt,
            imagePath: nil,
            timestamp: Date(),
            sourceAppName: lastExternalApp?.localizedName
        )
        outputHistory.insert(entry, at: 0)
        if outputHistory.count > 20 {
            outputHistory.removeLast(outputHistory.count - 20)
        }
    }

    /// Copy a history entry back to the clipboard.
    func copyHistoryEntry(_ entry: CaptureHistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let path = entry.imagePath, let image = NSImage(contentsOfFile: path) {
            pasteboard.writeObjects([image])
        } else if let text = entry.textContent {
            pasteboard.setString(text, forType: .string)
        }
        // Skip the monitor's next poll so the copy doesn't re-capture itself
        lastWrittenChangeCount = pasteboard.changeCount
    }

#if DEBUG
    /// Phase-0 debug hook: fabricate an annotation item from a generated test PNG
    /// to verify the annotation flows through the stack, prompt, and MCP bridge
    /// without any capture/overlay code.
    func debugAddTestAnnotation() {
        let size = NSSize(width: 200, height: 120)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        NSColor.white.set()
        let path = NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 160, height: 80))
        path.lineWidth = 6
        path.stroke()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString + ".png")
        guard (try? png.write(to: url)) != nil else { return }

        addItem(ClipboardItem(
            contentType: .annotation,
            textContent: AnnotationShape.circle.intentLabel,
            imagePath: url.path
        ))
    }

    /// Phase-1 debug hook: capture the real main screen and crop a fixed
    /// centered rect, exercising ScreenCaptureKit + the crop/save + coordinate
    /// math. Triggers the TCC prompt on first use.
    func debugCaptureScreenAnnotation() {
        let service = ScreenCaptureService()
        guard service.requestPermission() else {
            debugAddTestAnnotation() // fall back so the rest of the path is still testable
            return
        }
        guard let screen = NSScreen.main else { return }
        // A 400x300pt rect centered on screen, expressed in panel/screen-local points.
        let w: CGFloat = 400, h: CGFloat = 300
        let rectInPanel = CGRect(
            x: (screen.frame.width - w) / 2,
            y: (screen.frame.height - h) / 2,
            width: w, height: h
        )
        let pixelRect = ScreenCaptureService.toPixelRect(rectInPanel, screen: screen)
        Task {
            do {
                let full = try await service.captureFullScreen(of: screen)
                guard let path = service.cropAndSave(full, pixelRect: pixelRect) else { return }
                addItem(ClipboardItem(
                    contentType: .annotation,
                    textContent: AnnotationShape.circle.intentLabel,
                    imagePath: path
                ))
            } catch {
                NSLog("debugCaptureScreenAnnotation failed: \(error)")
            }
        }
    }
#endif

    func notifyItemAdded() {
        itemJustAdded = true
        Task {
            try? await Task.sleep(for: .seconds(2.0))
            itemJustAdded = false
        }
    }

    /// Append a finished session's text to the accumulated transcription and
    /// refresh the display without triggering delivery — used when the session
    /// finalized after a newer one already took over.
    private func appendToFrozenTranscription(_ markedText: String) {
        if frozenTranscription.isEmpty {
            frozenTranscription = markedText
        } else {
            frozenTranscription += " " + markedText
        }
        if voiceManager.isRecording {
            rebuildDisplayTranscription()   // splice live partial after the frozen text
        } else {
            displayTranscription = frozenTranscription
        }
    }

    /// Freeze the completed session text into the accumulated transcription.
    private func freezeCurrentSession(_ markedText: String) {
        appendToFrozenTranscription(markedText)
        displayTranscription = frozenTranscription

        // Auto-copy after dictation
        if autoCopy {
            copyPromptToClipboard()
        }

        if autoCopy && autoPasteAfterCopy {
            if AXIsProcessTrusted() {
                autoPasteToFocusedInput()
            } else {
                // Surface the missing permission instead of skipping silently —
                // the settings banner explains why nothing pasted.
                accessibilityNotGranted = true
            }
        }
    }

    /// Insert text by replacing the focused element's selection via the
    /// Accessibility API — superwhisper's primary technique. No clipboard or
    /// keystroke involved. Returns false when the focused element rejects
    /// AXSelectedText writes (some Electron apps and web views).
    private static func insertTextViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let element = focused as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    /// Hand focus back to the previously focused app, then insert the clipboard
    /// text into its focused input — direct AX insertion first, ⌘V fallback.
    private func autoPasteToFocusedInput() {
        // Re-activate the last external app explicitly — `deactivate()` alone
        // doesn't restore focus when recording was stopped from the popover or
        // Relay was activated by a Siri/URL command.
        if let target = lastExternalApp, !target.isTerminated {
            target.activate()
        } else {
            NSApp.deactivate()
        }
        Task { [weak self] in
            // Wait for focus to return to the previous app
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            // Make sure the pasteboard server has published our write before
            // any synthesized ⌘V can fire — pasting stale contents otherwise.
            if let target = self.lastWrittenChangeCount {
                await PasteboardHelper.waitForCommit(target: target)
            }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            if text.isEmpty || !Self.insertTextViaAccessibility(text) {
                self.simulatePaste()
            }
            if !text.isEmpty {
                CorrectionLearner.shared.observePaste(text: text)
            }
            // Holding ⇧ when the paste lands submits it (opt-in): give the
            // target a beat to process the insertion, then press Return.
            // CGEventSource, not NSEvent.modifierFlags — the latter is derived
            // from the app's own event stream, which is stale while Relay is a
            // backgrounded menu bar app.
            if self.sendAfterPasteWithShift,
               CGEventSource.flagsState(.combinedSessionState).contains(.maskShift) {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self.simulateReturn()
            }
            self.restoreClipboardIfRequested()
        }
    }

    /// Put the pre-dictation clipboard back after the paste has landed —
    /// but only if the pasteboard still carries our session marker. If the
    /// user copied something new while the paste was in flight, theirs wins.
    private func restoreClipboardIfRequested() {
        guard restoreClipboardAfterPaste, let snapshot = preWriteSnapshot else { return }
        preWriteSnapshot = nil
        let sessionID = pasteSessionID
        Task { [weak self] in
            // Give slower apps a window to read the pasted text before we
            // swap the previous contents back in.
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            guard PasteboardHelper.carriesSession(sessionID) else { return }
            // Skip the monitor's next poll so the restore isn't re-captured.
            self.lastWrittenChangeCount = PasteboardHelper.restore(snapshot)
        }
    }

    private nonisolated func simulateReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        // Clear flags so the physically held ⇧ doesn't turn this into
        // Shift+Return — a newline instead of a send in most chat inputs.
        keyDown?.flags = []
        keyUp?.flags = []
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
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
        var currentSession = insertRefMarkers(into: trimmed, refs: pendingRefs)
        if resolveSelfCorrections {
            currentSession = liveCorrectionAnimator.process(currentSession)
        }
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
        dictationGeneration += 1
        stack.clear()
        frozenTranscription = ""
        displayTranscription = ""
        pendingRefs = []
        // Trim-offset changes shift token positions, invalidating run keys.
        liveCorrectionAnimator.reset()

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

        // If the only meaningful items are voice notes (no context chips), just copy the raw text
        let nonEmptyVoiceNotes = stack.items.filter {
            $0.contentType == .voiceNote && !($0.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasNonVoiceItems = stack.items.contains { $0.contentType != .voiceNote }
        let onlyVoiceNotes = !nonEmptyVoiceNotes.isEmpty && !hasNonVoiceItems
        let prompt = onlyVoiceNotes
            ? nonEmptyVoiceNotes.compactMap(\.textContent).joined(separator: " ")
            : PromptComposer.compose(items: stack.items, format: promptFormat, voiceNotePosition: voiceNotePosition)
        writeToClipboard(prompt)
        recordOutputInHistory(prompt)

        flashCopiedConfirmation()

        if closePopoverOnCopy {
            // Delay past the Copied flash (and the 400ms clear-on-copy collapse)
            // so the popover doesn't vanish mid-animation.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard let self, self.closePopoverOnCopy else { return }
                self.popoverCloseRequests.send()
            }
        }

        if clearStackOnCopy {
            // Delay the clear so the Copied banner can fully appear before content collapses.
            // This prevents the banner, divider, and transcription from overlapping mid-animation.
            clearAfterCopyTask?.cancel()
            clearAfterCopyTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.clearAll()
                }
            }
        }
    }
}
