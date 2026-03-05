import SwiftUI

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var voiceManager = VoiceManager()
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
            VoiceNoteButton(voiceManager: voiceManager) { transcription in
                let item = ClipboardItem(contentType: .voiceNote, textContent: transcription)
                appState.stack.add(item)
            }

            Divider()

            // Context stack or empty state
            if appState.stack.isEmpty {
                EmptyStateView()
            } else {
                ContextStackView(stack: appState.stack)
            }

            Divider()

            // Settings panel (collapsible)
            if showSettings {
                SettingsSection(voiceManager: voiceManager)
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
                        ProgressView(value: voiceManager.downloadProgress)
                            .frame(maxWidth: .infinity)
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
