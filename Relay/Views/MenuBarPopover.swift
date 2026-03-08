import SwiftUI

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                // Settings header with back arrow
                HStack {
                    Button {
                        showSettings = false
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.plain)

                    Text("Settings")
                        .font(.headline)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                SettingsPage(voiceManager: appState.voiceManager)
            } else {
                MainPage(showSettings: $showSettings)
            }
        }
        .frame(width: 360)
        .modifier(OptionKeyTracker())
        .animation(.easeInOut(duration: 0.2), value: appState.showCopiedConfirmation)
    }
}

// MARK: - Main Page

private struct MainPage: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool

    private var shortcutDisplay: String {
        KeyboardShortcutModel.load().displayString
    }

    private var hasContent: Bool {
        !appState.stack.isEmpty || !appState.displayTranscription.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Relay")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .onTapGesture {
                        guard appState.isDemo else { return }
                        appState.clearAll()
                        appState.populateDemoStack()
                    }

                Spacer()

                if appState.isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Prompt pill (idle or recording)
            PromptPillView(
                isRecording: appState.isRecording,
                audioLevel: appState.voiceManager.audioLevel,
                shortcutDisplay: shortcutDisplay,
                onStop: { appState.finishDictationAndStop() }
            )
            .padding(.top, 2)

            // Transcription text with inline chips
            if !appState.displayTranscription.isEmpty {
                TranscriptionTextView(
                    text: appState.displayTranscription,
                    items: appState.stack.items,
                    onRemoveRef: { appState.removeRef($0) }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Divider
            Rectangle()
                .fill(Color(white: 0.624).opacity(0.14)) // #9F9F9F at 14%
                .frame(height: 1)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            // Footer menu
            VStack(spacing: 0) {
                if appState.showCopiedConfirmation {
                    menuRow(label: "Copied!", shortcut: nil)
                        .foregroundStyle(.green)
                } else if hasContent && !appState.isRecording {
                    menuButton(label: "Copy Prompt", shortcut: nil) {
                        appState.copyPromptToClipboard()
                    }

                    menuButton(label: "Clear Stack", shortcut: nil) {
                        appState.clearAll()
                    }
                }

                menuButton(label: "Settings...", shortcut: "⌘,") {
                    showSettings = true
                }

                menuButton(label: "Quit Relay", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func menuButton(label: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            menuRow(label: label, shortcut: shortcut)
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    @ViewBuilder
    private func menuRow(label: String, shortcut: String?) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            if let shortcut {
                Text(shortcut)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// A button style that highlights on hover like native menu items.
private struct MenuRowButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

// MARK: - Settings Page

private struct SettingsPage: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var voiceManager: VoiceManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Voice Engine")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Engine", selection: $voiceManager.selectedEngineType) {
                    ForEach(SpeechEngineType.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.segmented)

                if voiceManager.currentEngineNeedsDownload {
                    HStack {
                        if voiceManager.isDownloading {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: voiceManager.downloadProgress)
                                    .frame(maxWidth: .infinity)
                                Text(voiceManager.downloadProgress < 0.3
                                     ? "Downloading models\u{2026}"
                                     : voiceManager.downloadProgress < 0.9
                                     ? "Compiling CoreML models (first run)\u{2026}"
                                     : "Initializing\u{2026}")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text("\(Int(voiceManager.downloadProgress * 100))%")
                                .font(.caption)
                                .monospacedDigit()
                        } else {
                            Text("Model download required")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Download") {
                                Task {
                                    await voiceManager.downloadModelIfNeeded()
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                Divider()

                Text("Input Device")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Device", selection: $appState.selectedInputDeviceID) {
                    Text("System Default").tag(UInt32(0))
                    ForEach(AudioDeviceManager.inputDevices()) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()

                Divider()

                Toggle("Always-on monitoring", isOn: $appState.alwaysOnMonitoring)
                    .font(.caption)

                Toggle("Clear stack after copying", isOn: $appState.clearStackOnCopy)
                    .font(.caption)

                Toggle("Max mic volume on record", isOn: $appState.maxMicOnRecord)
                    .font(.caption)

                Toggle("Hotkey starts dictation", isOn: $appState.hotkeyStartsDictation)
                    .font(.caption)

                Toggle("Push-to-talk", isOn: $appState.pushToTalk)
                    .font(.caption)

                if appState.pushToTalk {
                    Toggle("Clean dictation (copy to clipboard)", isOn: $appState.cleanDictation)
                        .font(.caption)
                        .padding(.leading, 12)
                }

                Toggle("Capture clipboard on start", isOn: $appState.captureClipboardOnStart)
                    .font(.caption)

                Divider()

                Text("Prompt Format")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Format", selection: $appState.promptFormat) {
                    ForEach(PromptFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Divider()

                HStack {
                    Text("Keyboard shortcut")
                        .font(.caption)
                    Spacer()
                    ShortcutRecorderButton()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Shortcut Recorder

private struct ShortcutRecorderButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var displayString = KeyboardShortcutModel.load().displayString

    var body: some View {
        Button(isRecording ? "Press shortcut..." : displayString) {
            appState.hotkeyManager?.suspendMonitors()
            isRecording = true
        }
        .font(.caption.monospaced())
        .controlSize(.small)
        .background {
            if isRecording {
                ShortcutCaptureView { shortcut in
                    appState.hotkeyManager?.updateShortcut(shortcut)
                    displayString = shortcut.displayString
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
