import SwiftUI

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 6) {
                    Text("Relay")
                        .font(.headline)
                    Circle()
                        .fill(appState.isMonitoring ? .green : .red)
                        .frame(width: 8, height: 8)
                }

                Spacer()

                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Task intent
            TaskIntentView(taskIntent: $appState.taskIntent)

            Divider()

            // Voice recording
            VoiceNoteButton(voiceManager: appState.voiceManager) { transcription in
                let item = ClipboardItem(contentType: .voiceNote, textContent: transcription)
                appState.stack.add(item)
            }

            Divider()

            // Context stack or empty state
            if appState.stack.isEmpty {
                EmptyStateView(isMonitoring: appState.isMonitoring)
            } else {
                ContextStackView(stack: appState.stack)
            }

            Divider()

            // Settings panel (collapsible)
            if showSettings {
                SettingsSection(voiceManager: appState.voiceManager)
                Divider()
            }

            // Footer actions
            HStack {
                if appState.stack.isNearLimit {
                    Text("\(appState.stack.count)/\(ContextStack.maxItems)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.showCopiedConfirmation {
                    Text("Copied!")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button("Copy Prompt") {
                    appState.copyPromptToClipboard()
                }
                .disabled(appState.stack.isEmpty)

                Button("Clear") {
                    appState.stack.clear()
                }
                .disabled(appState.stack.isEmpty)

                Button(appState.isMonitoring ? "Pause" : "Resume") {
                    appState.toggleMonitoring()
                }

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 360, height: 480)
        .animation(.easeInOut(duration: 0.2), value: appState.showCopiedConfirmation)
    }
}

// MARK: - Settings Section

private struct SettingsSection: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var voiceManager: VoiceManager

    var body: some View {
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

            Toggle("Always-on monitoring", isOn: $appState.alwaysOnMonitoring)
                .font(.caption)

            Toggle("Clear stack after copying", isOn: $appState.clearStackOnCopy)
                .font(.caption)

            Toggle("Max mic volume on record", isOn: $appState.maxMicOnRecord)
                .font(.caption)

            Toggle("Hotkey starts dictation", isOn: $appState.hotkeyStartsDictation)
                .font(.caption)

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

// MARK: - Shortcut Recorder

private struct ShortcutRecorderButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isRecording = false
    @State private var displayString = KeyboardShortcutModel.load().displayString

    var body: some View {
        Button(isRecording ? "Press shortcut..." : displayString) {
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
                } onCancel: {
                    isRecording = false
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
