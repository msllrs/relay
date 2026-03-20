import SwiftUI

// MARK: - Settings Page

struct SettingsPage: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool
    @ObservedObject var voiceManager: VoiceManager
    @ObservedObject var updaterManager: UpdaterManager

    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

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
                    .animation(.easeInOut(duration: 0.25), value: showSettings)

                Spacer()

                SettingsGearButton(showSettings: $showSettings)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            VStack(alignment: .leading, spacing: 8) {
                voiceSection
                behaviorSection
                afterDictationSection
                promptSection
                shortcutSection
                footerSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Sections

    private var voiceSection: some View {
        SettingsSection("Voice") {
            SettingsRow("Engine") {
                HStack(spacing: 6) {
                    Picker("Engine", selection: $voiceManager.selectedEngineType) {
                        ForEach(SpeechEngineType.allCases) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
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
                    ForEach(AudioDeviceManager.inputDevices()) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
            }

            SettingsToggle("Max mic volume on record", isOn: $appState.maxMicOnRecord)
        }
    }

    private var behaviorSection: some View {
        SettingsSection("Behavior") {
            SettingsToggle("Push-to-talk", isOn: $appState.pushToTalk)
            SettingsToggle("Capture clipboard on start", isOn: $appState.captureClipboardOnStart)
            SettingsToggle("Keep popover pinned", isOn: $appState.pinPopover)
            SettingsToggle("Show recording overlay", isOn: $appState.showRecordingOverlay)
            SettingsToggle("Clear after copying", isOn: $appState.clearStackOnCopy)
        }
    }

    private var afterDictationSection: some View {
        SettingsSection("After dictation") {
            SettingsToggle("Auto-copy", isOn: $appState.autoCopy)

            if appState.autoCopy {
                SettingsToggle("Auto-paste to focused input", isOn: $appState.autoPasteAfterCopy)
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

            SettingsRow("Transcript") {
                Picker("Transcript", selection: $appState.transcriptEnhancement) {
                    ForEach(TranscriptEnhancement.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
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
            Divider()

            HStack(spacing: 4) {
                if let version = Self.appVersion {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
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
            Divider()

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
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
            Spacer()
            content
        }
        .frame(minHeight: 24)
    }
}

// MARK: - Settings Toggle

private struct SettingsToggle: View {
    let label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(label) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

// MARK: - Shortcut Recorder

private struct ShortcutRecorderButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var currentShortcut = KeyboardShortcutModel.load()

    private var isDefault: Bool { currentShortcut == .default }

    var body: some View {
        HStack(spacing: 4) {
            if !isDefault {
                Button {
                    let shortcut = KeyboardShortcutModel.default
                    appState.hotkeyManager?.suspendMonitors()
                    appState.hotkeyManager?.updateShortcut(shortcut)
                    appState.hotkeyManager?.resumeMonitors()
                    currentShortcut = shortcut
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to default (\(KeyboardShortcutModel.default.displayString))")
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
                    appState.hotkeyManager?.updateShortcut(shortcut)
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
