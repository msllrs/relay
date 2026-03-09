import Carbon.HIToolbox
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
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var handled = false
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async {
                        let item = ClipboardItem.fromFileURL(url)
                        appState.stack.add(item)
                        appState.recordRefMarker(for: item.id)
                        appState.notifyItemAdded()
                    }
                }
                handled = true
            }
            return handled
        }
    }
}

// MARK: - Main Page

private struct MainPage: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool
    @State private var shortcutDisplay = KeyboardShortcutModel.load().displayString

    private var hasContent: Bool {
        if appState.isRecording {
            return !appState.displayTranscription.isEmpty
        }
        return !appState.stack.isEmpty || !appState.displayTranscription.isEmpty
    }

    var body: some View {
        let hasContent = hasContent

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

                SettingsGearButton(showSettings: $showSettings)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .transaction { $0.animation = nil }

            // Prompt pill (idle or recording)
            PromptPillView(
                isRecording: appState.isRecording,
                audioLevel: appState.voiceManager.audioLevel,
                shortcutDisplay: shortcutDisplay,
                onStart: { appState.hotkeyTriggered() },
                onStop: { appState.finishDictationAndStop() }
            )
            .padding(.top, 2)
            .padding(.bottom, hasContent || appState.showCopiedConfirmation || !appState.displayTranscription.isEmpty ? 0 : 16)
            .transaction { $0.animation = nil }

            // Transcription text with inline chips
            if !appState.displayTranscription.isEmpty {
                TranscriptionTextView(
                    text: appState.displayTranscription,
                    items: appState.stack.items,
                    isRecording: appState.isRecording,
                    onRemoveRef: { appState.removeRef($0) }
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, hasContent ? 0 : 16)
            }

            // Footer: divider + action buttons
            FooterView(
                hasContent: hasContent,
                showCopiedConfirmation: appState.showCopiedConfirmation,
                onCopy: { appState.copyPromptToClipboard() },
                onClear: { appState.clearAll() }
            )
        }
        .background(PopoverKeyHandler(actions: {
            var actions: [Int: () -> Void] = [
                kVK_ANSI_Comma: { showSettings = true },
                kVK_ANSI_Q: { NSApplication.shared.terminate(nil) },
            ]
            if hasContent {
                actions[kVK_ANSI_C] = { appState.copyPromptToClipboard() }
                actions[kVK_Delete] = { appState.clearAll() }
            }
            return actions
        }()))
    }
}

// MARK: - Settings Gear

/// Gear icon in the header. Click to open settings, option-click to quit.
private struct SettingsGearButton: View {
    @Binding var showSettings: Bool
    @State private var isHovered = false
    @Environment(\.optionKeyHeld) private var optionHeld

    var body: some View {
        Button {
            if optionHeld {
                NSApplication.shared.terminate(nil)
            } else {
                showSettings = true
            }
        } label: {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
                .scaleEffect(optionHeld ? 1 : 0.5)
                .blur(radius: optionHeld ? 0 : 3)
                .opacity(optionHeld ? 1 : 0)
                .overlay {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .scaleEffect(optionHeld ? 0.5 : 1)
                        .blur(radius: optionHeld ? 3 : 0)
                        .opacity(optionHeld ? 0 : 1)
                }
                .animation(.easeInOut(duration: 0.25), value: optionHeld)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isHovered ? 1 : 0.7)
        .help(optionHeld ? "Quit Relay" : "Settings")
    }
}

// MARK: - Footer

/// Always-visible footer with action buttons.
private struct FooterView: View {
    let hasContent: Bool
    let showCopiedConfirmation: Bool
    var onCopy: () -> Void
    var onClear: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showCopiedConfirmation || hasContent {
                Rectangle()
                    .fill(Color(white: 0.624).opacity(0.14))
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .transaction { $0.animation = nil }
            }

            if showCopiedConfirmation || hasContent {
                FooterButtonsView(
                    showCopied: showCopiedConfirmation,
                    onCopy: onCopy,
                    onClear: onClear
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

/// Animated footer buttons: Clear Stack collapses while Copy Prompt expands to "Copied!".
private struct FooterButtonsView: View {
    let showCopied: Bool
    var onCopy: () -> Void
    var onClear: () -> Void

    /// Internal animated state, driven via `withAnimation` to be immune to parent transaction overrides.
    @State private var collapsed = false
    @State private var clearHovered = false
    @State private var copyHovered = false

    var body: some View {
        HStack(spacing: 0) {
            // Clear Stack — collapses horizontally on copy
            Button(action: onClear) {
                Text("Clear Stack")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary.opacity(clearHovered ? 0.8 : 0.55))
                    .fixedSize()
                    .scaleEffect(collapsed ? 0.5 : 1)
                    .opacity(collapsed ? 0 : 1)
                    .blur(radius: collapsed ? 4 : 0)
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(width: collapsed ? 0 : nil)
            .frame(maxWidth: collapsed ? 0 : .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(clearHovered ? 0.1 : 0.06))
                    .opacity(collapsed ? 0 : 1)
            )
            .clipped()
            .onHover { clearHovered = $0 }
            .allowsHitTesting(!collapsed)

            // Gap between buttons
            Color.clear
                .frame(width: collapsed ? 0 : 8)

            // Copy Prompt / Copied! — expands to fill
            Button(action: onCopy) {
                ZStack {
                    Text("Copy Prompt")
                        .scaleEffect(collapsed ? 0.5 : 1)
                        .opacity(collapsed ? 0 : 1)
                        .blur(radius: collapsed ? 4 : 0)
                    Text("Copied!")
                        .foregroundStyle(.green)
                        .scaleEffect(collapsed ? 1 : 0.5)
                        .opacity(collapsed ? 1 : 0)
                        .blur(radius: collapsed ? 0 : 4)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(copyHovered ? 0.8 : 0.55))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(copyHovered ? 0.1 : 0.06))
            )
            .onHover { copyHovered = $0 }
        }
        .onChange(of: showCopied) { _, newValue in
            withAnimation(.snappy(duration: 0.35)) {
                collapsed = newValue
            }
        }
    }
}

// MARK: - Settings Page

private struct SettingsPage: View {
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

// MARK: - Popover Keyboard Shortcuts

/// Intercepts keyboard shortcuts while the popover is open.
/// ⌘C (copy prompt), ⌘⌫ (clear stack), ⌘, (settings), ⌘Q (quit).
private struct PopoverKeyHandler: NSViewRepresentable {
    var actions: [Int: () -> Void]

    func makeNSView(context: Context) -> KeyHandlerNSView {
        let view = KeyHandlerNSView()
        view.actions = actions
        return view
    }

    func updateNSView(_ nsView: KeyHandlerNSView, context: Context) {
        nsView.actions = actions
    }
}

private final class KeyHandlerNSView: NSView {
    var actions: [Int: () -> Void] = [:]
    private nonisolated(unsafe) var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.modifierFlags.contains(.command) else { return event }
                if let action = self.actions[Int(event.keyCode)] {
                    MainActor.assumeIsolated { action() }
                    return nil
                }
                return event
            }
        } else if window == nil, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }
}
