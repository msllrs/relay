import SwiftUI

// MARK: - Settings Page

private struct SettingsScrollEdges: Equatable {
    var canScrollUp: Bool
    var canScrollDown: Bool
}

struct SettingsPage: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool
    @ObservedObject var voiceManager: VoiceManager
    @ObservedObject var updaterManager: UpdaterManager
    @State private var canScrollUp = false
    @State private var canScrollDown = false

    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    private static let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    /// The scrollable sections, shared by the scroller and its blurred twins.
    private var sectionsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            voiceSection
            shortcutSection
            behaviorSection
            applicationSection
            afterDictationSection
            promptSection
            dictionarySection
            integrationSection
            annotationSection
            historySection
        }
        .padding(.horizontal, 16)
    }

    private var dictionarySection: some View {
        SettingsSection("Dictionary") {
            DictionaryEditor()
            SettingsToggle(
                "Learn from corrections",
                help: "After auto-paste, Relay checks the field once and adds words you've fixed twice to the Boost vocabulary. Entirely on-device.",
                isOn: $appState.learnFromCorrections
            )
        }
    }


    /// Cap the sections scroll area so a growing settings list doesn't push the
    /// popover off screen. The footer stays pinned below the scroll area.
    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(560, screenHeight * 0.85 - 160)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .scaleEffect(showSettings ? 1 : 0.85, anchor: .leading)
                    .blur(radius: showSettings ? 0 : 3)
                    .opacity(showSettings ? 1 : 0)
                    .offset(y: 1)
                    .animation(appState.pageTransitionAnimation, value: showSettings)

                Spacer()

                SettingsGearButton(showSettings: $showSettings)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Sections scroll once they exceed the max height; sized to content
            // below that so the popover height morph keeps working.
            ScrollView(.vertical, showsIndicators: false) {
                sectionsContent
            }
            .onScrollGeometryChange(for: SettingsScrollEdges.self) { geo in
                let overflow = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return SettingsScrollEdges(
                    canScrollUp: geo.contentOffset.y > 5,
                    canScrollDown: overflow > 5
                )
            } action: { _, edges in
                canScrollUp = edges.canScrollUp
                canScrollDown = edges.canScrollDown
            }
            // Tall, soft edge fades. A true progressive BLUR here is not
            // achievable with public APIs — every approach fails inside an
            // NSPopover with AppKit-backed controls: SwiftUI Material samples
            // behind the window, NSVisualEffectView can't backdrop-sample
            // SwiftUI siblings, .blur()/.clipped() don't apply to platform
            // views (compositor corruption), and cacheDisplay snapshots break
            // the popover's vibrancy. Verified 2026-07-20; don't retry.
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: canScrollUp ? 36 : 0)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: canScrollDown ? 36 : 0)
                }
                .animation(.easeOut(duration: 0.12), value: canScrollUp)
                .animation(.easeOut(duration: 0.12), value: canScrollDown)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: maxScrollHeight)
            .fixedSize(horizontal: false, vertical: true)

            // Footer pinned below the scroll area — no top padding, so the
            // bottom edge blur hugs the footer divider.
            footerSection
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .onChange(of: showSettings) {
            if showSettings {
                appState.refreshAccessibilityStatus()
            }
        }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        SettingsSection("Voice") {
            SettingsRow("Engine") {
                HStack(spacing: 6) {
                    // Menu picker, not segmented — four engines crush the row
                    // label into wrapping at this popover width.
                    Picker("Engine", selection: $voiceManager.selectedEngineType) {
                        ForEach(SpeechEngineType.availableCases) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .disabled(voiceManager.isRecording)

                    if voiceManager.currentEngineNeedsDownload || voiceManager.isDownloading || voiceManager.downloadComplete {
                        EngineDownloadButton(voiceManager: voiceManager)
                    } else if appState.isDemo {
                        EngineDownloadButton(voiceManager: voiceManager, demo: true)
                    }
                }
            }

            SettingsRow("Input") {
                Picker("Input", selection: $appState.selectedInputDeviceID) {
                    Text("System Default").tag(UInt32(0))
                    ForEach(appState.availableInputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
            }

            SettingsToggle(
                "Max mic volume on record",
                help: "Raises input volume to maximum while recording, then restores your previous level.",
                isOn: $appState.maxMicOnRecord
            )
            SettingsToggle(
                "Instant start (keeps mic warm)",
                help: "Keeps the mic armed while idle so recordings include the half-second before you hit the shortcut — first words never get clipped. macOS shows the mic indicator the whole time.",
                isOn: $appState.warmCapturePreRoll
            )
            SettingsToggle("Start/stop sounds", isOn: $appState.recordingSounds)

            if appState.recordingSounds {
                SettingsRow("Sound") {
                    Picker("Sound", selection: $appState.recordingSoundTheme) {
                        ForEach(RecordingSoundTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .labelsHidden()
                    // Menu pickers size to content; without trailing alignment
                    // the flexible frame centers them off the right edge.
                    .frame(maxWidth: 140, alignment: .trailing)
                }
            }
            SettingsToggle(
                "Duck system audio while recording",
                help: "Lowers output volume during recording so playback doesn't bleed into the mic, then restores it.",
                isOn: $appState.duckAudioOnRecord
            )
        }
    }

    private var behaviorSection: some View {
        SettingsSection("Behavior") {
            SettingsToggle("Push-to-talk", isOn: $appState.pushToTalk)
            SettingsToggle("Auto-stop after silence", isOn: $appState.autoStopOnSilence)

            if appState.autoStopOnSilence {
                SettingsRow("After") {
                    Picker("After", selection: $appState.autoStopSilenceDuration) {
                        Text("1.5s").tag(1.5)
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }
            }
            SettingsToggle(
                "Capture clipboard on start",
                help: "Whatever is on the clipboard when recording starts is added as a context item.",
                isOn: $appState.captureClipboardOnStart
            )
            SettingsToggle("Add screenshots taken while recording", isOn: $appState.captureScreenshotsWhileRecording)
            SettingsToggle("Keep popover pinned", isOn: $appState.pinPopover)
            SettingsToggle("Show recording overlay", isOn: $appState.showRecordingOverlay)
            SettingsToggle("Clear after copying", isOn: $appState.clearStackOnCopy)
            SettingsToggle("Close popover after copying", isOn: $appState.closePopoverOnCopy)
        }
    }

    private var applicationSection: some View {
        SettingsSection("Application") {
            SettingsToggle("Launch at login", isOn: $appState.launchAtLogin)
            SettingsToggle("Show in Dock", isOn: $appState.showInDock)
            SettingsToggle("Start recording on menu bar click", isOn: $appState.startRecordingOnMenubarClick)
        }
    }

    private var afterDictationSection: some View {
        SettingsSection("After dictation") {
            SettingsToggle("Auto-copy", isOn: $appState.autoCopy)

            if appState.autoCopy {
                SettingsToggle("Auto-paste to focused input", isOn: $appState.autoPasteAfterCopy)

                if appState.autoPasteAfterCopy {
                    SettingsToggle(
                        "Hold ⇧ to send after paste",
                        help: "Holding Shift when the paste lands also presses Return — dictate straight into a chat and send it.",
                        isOn: $appState.sendAfterPasteWithShift
                    )
                    SettingsToggle(
                        "Restore clipboard after paste",
                        help: "Puts whatever was on the clipboard before dictation back after the paste lands. Anything you copy in the meantime wins.",
                        isOn: $appState.restoreClipboardAfterPaste
                    )
                }
            }
        }
    }

    private var promptSection: some View {
        SettingsSection("Prompt") {
            SettingsRow("Format") {
                Picker("Format", selection: $appState.promptFormat) {
                    ForEach(PromptFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsRow("Voice note") {
                Picker("Voice note", selection: $appState.voiceNotePosition) {
                    ForEach(VoiceNotePosition.allCases) { position in
                        Text(position.label).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsRow(
                "Transcript",
                help: "Raw is verbatim. Clean strips filler words. Formatted also fixes capitalization and punctuation. AI Polish uses Apple's on-device model to resolve self-corrections too — nothing leaves your Mac. It needs Apple Intelligence turned on in System Settings."
            ) {
                Picker("Transcript", selection: $appState.transcriptEnhancement) {
                    ForEach(TranscriptEnhancement.allCases) { level in
                        if level == .aiPolish && !FoundationModelsEnhancer.isAvailable {
                            // Visible but disabled beats hidden: the feature is
                            // discoverable and the label says what's missing.
                            Text("AI Polish (needs Apple Intelligence)")
                                .tag(level)
                                .selectionDisabled()
                        } else {
                            Text(level.label).tag(level)
                        }
                    }
                }
                .labelsHidden()
            }

            SettingsToggle(
                "Fix self-corrections",
                help: "Resolves spoken corrections: \"padding 20 pixels, scratch that, 8 pixels\" becomes \"padding 8 pixels\". Understands cues like \"scratch that\", \"no wait\", \"I mean\", and \"start over\". Runs on-device — with Apple Intelligence it uses Apple's local model for trickier phrasing; without it, a built-in heuristic. Nothing leaves your Mac.",
                isOn: $appState.resolveSelfCorrections
            )
        }
    }

    private var integrationSection: some View {
        SettingsSection("Integration") {
            SettingsToggle("MCP bridge for Claude Code", isOn: $appState.mcpBridgeEnabled)

            SettingsToggle("Siri voice activation", isOn: $appState.siriActivationEnabled)

            if appState.siriActivationEnabled {
                SiriSetupHint()
            }
        }
    }

    private var annotationSection: some View {
        SettingsSection("Annotation") {
            SettingsToggle("Draw-on-screen annotation", isOn: $appState.annotationEnabled)

            if appState.annotationEnabled {
                SettingsToggle("Annotate while recording", isOn: $appState.annotateWhileRecording)

                SettingsRow("Capture") {
                    Picker("Capture", selection: $appState.annotationCaptureScope) {
                        ForEach(CaptureScope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                SettingsToggle("Allow multiple annotations", isOn: $appState.annotationAllowMultiple)

                SettingsRow("Annotation shortcut") {
                    ShortcutRecorderButton(
                        initial: KeyboardShortcutModel.load(
                            key: KeyboardShortcutModel.annotateDefaultsKey,
                            fallback: .annotateDefault
                        ),
                        defaultShortcut: .annotateDefault,
                        onUpdate: { state, shortcut in
                            state.hotkeyManager?.updateAnnotateShortcut(shortcut)
                        }
                    )
                }

                if appState.needsScreenRecordingPermission {
                    ScreenRecordingNotGrantedBanner()
                }
            }
        }
    }

    private var historySection: some View {
        SettingsSection("History") {
            CaptureHistoryList()
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsDivider()
            SettingsRow("Keyboard shortcut") {
                ShortcutRecorderButton()
            }
            if appState.accessibilityBroken {
                AccessibilityBrokenBanner()
            } else if appState.accessibilityNotGranted {
                AccessibilityNotGrantedBanner()
            }
        }
    }

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsDivider()

            HStack(spacing: 4) {
                if let version = Self.appVersion {
                    // Links to the tagged release so the notes are one click away
                    HoverLink("v\(version)", url: "https://github.com/msllrs/relay/releases/tag/v\(version)")
                        .help("Release notes")
                    #if DEBUG
                    // Dev builds show the build number so it's obvious which
                    // iteration is running.
                    if let build = Self.buildNumber {
                        Text("(\(build))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    #endif
                }
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                HoverLink("@msllrs", url: "https://x.com/msllrs")
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                HoverLink("GitHub", url: "https://github.com/msllrs/relay")
                Spacer()
                Button("Check for Updates") {
                    updaterManager.checkForUpdates()
                }
                .font(.caption)
                .controlSize(.small)
                .disabled(!updaterManager.canCheckForUpdates)
            }

            Button("Quit Relay") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Settings Divider

/// Explicit hairline matching the main page footer's rule. `Divider()` inside
/// the popover sometimes resolves its separator color against the wrong
/// appearance (showing dark-mode color in light mode and vice versa); a fixed
/// mid-gray at low opacity reads correctly in both.
private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(white: 0.624).opacity(0.14))
            .frame(height: 1)
    }
}

// MARK: - Settings Section

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsDivider()

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            content
        }
    }
}

// MARK: - Settings Row

private struct SettingsRow<Content: View>: View {
    let label: String
    /// Short explanation shown as a tooltip behind an info icon — for
    /// settings whose label alone doesn't explain what they do.
    var help: String?
    @ViewBuilder let content: Content

    init(_ label: String, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.help = help
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12))
            if let help {
                Image(systemName: "info.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .help(help)
            }
            Spacer()
            content
        }
        .frame(minHeight: 24)
    }
}

// MARK: - Settings Toggle

private struct SettingsToggle: View {
    let label: String
    var help: String?
    @Binding var isOn: Bool

    init(_ label: String, help: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.help = help
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(label, help: help) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

// MARK: - Dictionary Editor

/// Word removal and replacement rules with a live preview. The preview runs
/// the exact same applier as the transcript pipeline, so what you see is what
/// dictation does.
private struct DictionaryEditor: View {
    @EnvironmentObject var appState: AppState
    @State private var mode: Mode = .replace
    @State private var previewInput = ""

    private enum Mode: String, CaseIterable {
        case remove = "Remove"
        case replace = "Replace"
        case boost = "Boost"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .remove:
                ForEach($appState.wordRemovals) { $rule in
                    HStack(spacing: 6) {
                        Toggle("", isOn: $rule.isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        TextField("word or regex", text: $rule.pattern)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        deleteButton { appState.wordRemovals.removeAll { $0.id == rule.id } }
                    }
                }
                addButton("Add removal") {
                    appState.wordRemovals.append(WordRemovalRule())
                }
            case .replace:
                ForEach($appState.wordRemappings) { $rule in
                    HStack(spacing: 6) {
                        Toggle("", isOn: $rule.isEnabled)
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                        TextField("match", text: $rule.match)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        TextField("replacement", text: $rule.replacement)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                        deleteButton { appState.wordRemappings.removeAll { $0.id == rule.id } }
                    }
                }
                addButton("Add replacement") {
                    appState.wordRemappings.append(WordRemappingRule())
                }
            case .boost:
                Text("Names and jargon the speech engines should recognize.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                ForEach(appState.vocabularyTerms.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        TextField("term", text: Binding(
                            get: { appState.vocabularyTerms.indices.contains(index) ? appState.vocabularyTerms[index] : "" },
                            set: { newValue in
                                if appState.vocabularyTerms.indices.contains(index) {
                                    appState.vocabularyTerms[index] = newValue
                                }
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        deleteButton {
                            if appState.vocabularyTerms.indices.contains(index) {
                                appState.vocabularyTerms.remove(at: index)
                            }
                        }
                    }
                }
                addButton("Add term") {
                    appState.vocabularyTerms.append("")
                }
            }

            TextField("Try it: type here to preview your rules", text: $previewInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            if !previewInput.isEmpty {
                Text(WordRules.apply(previewInput, removals: appState.wordRemovals, remappings: appState.wordRemappings))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func deleteButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func addButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: "plus")
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Capture History

/// Disclosure list of recent captures or composed LLM outputs; clicking a
/// row copies it back to the clipboard.
private struct CaptureHistoryList: View {
    @EnvironmentObject var appState: AppState
    @State private var expanded = false
    @State private var showingOutputs = false
    @State private var copiedID: UUID?

    private var entries: [CaptureHistoryEntry] {
        showingOutputs ? appState.outputHistory : appState.captureHistory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(showingOutputs ? "Copied prompts" : "Recent captures")
                        .font(.system(size: 12))
                    Spacer()
                    Text("\(entries.count)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 24)

            if expanded {
                Picker("History", selection: $showingOutputs) {
                    Text("Captures").tag(false)
                    Text("LLM output").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180)
                .padding(.bottom, 2)

                if entries.isEmpty {
                    Text(showingOutputs ? "No prompts copied yet" : "Nothing captured yet")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 4)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            CaptureHistoryRow(entry: entry, copied: copiedID == entry.id) {
                                appState.copyHistoryEntry(entry)
                                copiedID = entry.id
                                Task {
                                    try? await Task.sleep(for: .seconds(1.2))
                                    if copiedID == entry.id { copiedID = nil }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
    }
}

private struct CaptureHistoryRow: View {
    let entry: CaptureHistoryEntry
    let copied: Bool
    let onCopy: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 6) {
                Circle()
                    .fill(entry.contentType.chipColor)
                    .frame(width: 5, height: 5)
                Text(entry.preview)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(hovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if let app = entry.sourceAppName {
                    Text("→ \(app)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(successGreen)
                    .opacity(copied ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(hovered ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Click to copy")
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}

// MARK: - Shortcut Recorder

private struct ShortcutRecorderButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var currentShortcut: KeyboardShortcutModel

    private let defaultShortcut: KeyboardShortcutModel
    private let onUpdate: (AppState, KeyboardShortcutModel) -> Void

    /// Defaults to the dictation shortcut for backwards compatibility.
    init(
        initial: KeyboardShortcutModel = KeyboardShortcutModel.load(),
        defaultShortcut: KeyboardShortcutModel = .default,
        onUpdate: @escaping (AppState, KeyboardShortcutModel) -> Void = { state, shortcut in
            state.hotkeyManager?.updateShortcut(shortcut)
        }
    ) {
        self._currentShortcut = State(initialValue: initial)
        self.defaultShortcut = defaultShortcut
        self.onUpdate = onUpdate
    }

    private var isDefault: Bool { currentShortcut == defaultShortcut }

    private func apply(_ shortcut: KeyboardShortcutModel) {
        appState.hotkeyManager?.suspendMonitors()
        onUpdate(appState, shortcut)
        appState.hotkeyManager?.resumeMonitors()
        currentShortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 4) {
            if !isDefault {
                Button {
                    apply(defaultShortcut)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default (\(defaultShortcut.displayString))")
                .transition(.scale.combined(with: .opacity))
            }

            Button(isRecording ? "Press shortcut..." : currentShortcut.displayString) {
                appState.hotkeyManager?.suspendMonitors()
                isRecording = true
            }
            .font(.caption.monospaced())
            .controlSize(.small)
        }
        .animation(.easeInOut(duration: 0.2), value: isDefault)
        .background {
            if isRecording {
                ShortcutCaptureView { shortcut in
                    onUpdate(appState, shortcut)
                    currentShortcut = shortcut
                    isRecording = false
                    appState.hotkeyManager?.resumeMonitors()
                } onCancel: {
                    isRecording = false
                    appState.hotkeyManager?.resumeMonitors()
                }
            }
        }
    }
}

// MARK: - Siri Setup Hint

/// One-time setup instructions shown when Siri voice activation is enabled.
/// Dev builds register the relay-dev:// scheme, so derive it from the bundle ID
/// to keep the instructions accurate for whichever build is running.
private struct SiriSetupHint: View {
    private static var urlScheme: String {
        Bundle.main.bundleIdentifier == "com.msllrs.relay.dev" ? "relay-dev" : "relay"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("In Shortcuts, create a shortcut named \u{201C}Start Relay\u{201D} with the \u{201C}Open URLs\u{201D} action pointing at \(Self.urlScheme)://start-recording — then say \u{201C}Hey Siri, Start Relay\u{201D}. Use \(Self.urlScheme)://stop-recording to finish hands-free.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Shortcuts") {
                if let url = URL(string: "shortcuts://") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.system(size: 11))
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Accessibility Broken Banner

private struct AccessibilityBrokenBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Hotkey needs attention")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text("After updating Relay, macOS requires you to re-grant accessibility. Open Settings, remove Relay, re-add it, and toggle it back on.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding(.top, 1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Accessibility Not Granted Banner

private struct AccessibilityNotGrantedBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Accessibility not enabled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Enable Relay in Accessibility settings to use keyboard shortcuts like push-to-talk and escape to cancel.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding(.top, 1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Screen Recording Not Granted Banner

private struct ScreenRecordingNotGrantedBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Screen Recording not enabled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                Text("Enable Relay in Screen Recording settings so annotations can capture the region you draw on. You may need to relaunch Relay after granting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Screen Recording Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11))
                .controlSize(.small)
                .padding(.top, 1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Shortcut Capture

/// NSViewRepresentable that captures the next keyDown event with modifier flags.
private struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (KeyboardShortcutModel) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {}
}

private final class ShortcutCaptureNSView: NSView {
    var onCapture: ((KeyboardShortcutModel) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape cancels
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        // Require at least one modifier
        guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option) else {
            return
        }

        let shortcut = KeyboardShortcutModel(
            keyCode: event.keyCode,
            modifiers: modifiers.rawValue
        )
        onCapture?(shortcut)
    }
}

// MARK: - Hover Link

/// A text link that turns the URL chip blue on hover and uses a pointer cursor.
private struct HoverLink: View {
    let label: String
    let url: String
    @State private var isHovered = false

    init(_ label: String, url: String) {
        self.label = label
        self.url = url
    }

    var body: some View {
        Link(label, destination: URL(string: url)!)
            .font(.caption)
            .foregroundStyle(isHovered ? ContentType.url.chipColor : Color.secondary.opacity(0.6))
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

// MARK: - Engine Download Button

private enum DownloadPhase: Equatable {
    case idle
    case downloading
    case done
    case error
}

private extension View {
    func phaseVisibility(_ visible: Bool) -> some View {
        self
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible ? 1 : 0.5)
            .blur(radius: visible ? 0 : 4)
    }
}

private struct EngineDownloadButton: View {
    @ObservedObject var voiceManager: VoiceManager
    var demo = false

    private var phase: DownloadPhase {
        if voiceManager.downloadComplete { return .done }
        if voiceManager.isDownloading { return .downloading }
        if voiceManager.error != nil { return .error }
        return .idle
    }

    var body: some View {
        let iconSize: CGFloat = 12

        Button {
            guard phase == .idle || phase == .error else { return }
            voiceManager.error = nil
            Task {
                if demo {
                    await voiceManager.simulateDownload()
                } else {
                    await voiceManager.downloadModelIfNeeded()
                }
            }
        } label: {
            ZStack {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: iconSize))
                    .phaseVisibility(phase == .idle)

                SpinnerIcon(size: iconSize)
                    .phaseVisibility(phase == .downloading)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(successGreen)
                    .phaseVisibility(phase == .done)

                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: iconSize))
                    .foregroundStyle(.red)
                    .phaseVisibility(phase == .error)
            }
            .animation(.easeInOut(duration: 0.3), value: phase)
            .frame(width: 24, height: 24)
            .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(phase == .error ? "Download failed. Click to retry." : "Download model")
    }
}

private struct SpinnerIcon: View {
    let size: CGFloat
    @State private var spinning = false

    var body: some View {
        Image(size: CGSize(width: size, height: size)) { ctx in
            let center = CGPoint(x: size / 2, y: size / 2)
            let rayCount = 8
            let innerR = size * 0.2
            let outerR = size * 0.46
            let rayWidth = size * 0.14

            for i in 0..<rayCount {
                let angle = Angle.degrees(Double(i) / Double(rayCount) * 360 - 90)
                let cos = cos(angle.radians)
                let sin = sin(angle.radians)
                let start = CGPoint(x: center.x + innerR * cos, y: center.y + innerR * sin)
                let end = CGPoint(x: center.x + outerR * cos, y: center.y + outerR * sin)

                var path = Path()
                path.move(to: start)
                path.addLine(to: end)

                let opacity = 0.25 + 0.75 * (Double(i) / Double(rayCount - 1))
                ctx.opacity = opacity
                ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: rayWidth, lineCap: .round))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(spinning ? 360 : 0))
        .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spinning)
        .onAppear { spinning = true }
    }
}
