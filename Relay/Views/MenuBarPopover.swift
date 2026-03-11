import Carbon.HIToolbox
import SwiftUI

private let successGreen = Color(nsColor: NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        NSColor(red: 0, green: 0.788, blue: 0.471, alpha: 1)
    } else {
        NSColor(red: 0, green: 0.60, blue: 0.36, alpha: 1)
    }
})

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                SettingsPage(showSettings: $showSettings, voiceManager: appState.voiceManager)
            } else {
                MainPage(showSettings: $showSettings)
            }
        }
        .frame(width: 360)
        .modifier(OptionKeyTracker())
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var handled = false
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    DispatchQueue.main.async {
                        appState.addItem(ClipboardItem.fromFileURL(url))
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

            // Prompt pill (idle or recording)
            PromptPillView(
                isRecording: appState.isRecording,
                audioLevel: appState.voiceManager.audioLevel,
                shortcutDisplay: shortcutDisplay,
                onStart: { appState.hotkeyTriggered() },
                onStop: { appState.finishDictationAndStop() }
            )
            .padding(.top, 2)
            .padding(.bottom, hasContent || appState.showCopiedConfirmation ? 0 : 16)

            // Show a processing indicator for engines that buffer audio before transcribing
            if appState.isRecording
                && appState.voiceManager.selectedEngineType != .native
                && appState.voiceManager.partialTranscription.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Processing audio…")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .transition(.opacity)
            }

            // Transcription text with inline chips (scrollable when popover hits max height)
            if !appState.displayTranscription.isEmpty || appState.stack.hasNonVoiceItems {
                ScrollView(.vertical, showsIndicators: false) {
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
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity.combined(with: .blurReplace(.downUp)))
            }

            // Footer: divider + action buttons
            FooterView(
                hasContent: hasContent,
                showCopiedConfirmation: appState.showCopiedConfirmation,
                onCopy: { appState.copyPromptToClipboard() },
                onClear: {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.clearAll()
                    }
                }
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(.easeInOut(duration: 0.25), value: hasContent)
        .background(PopoverKeyHandler(actions: {
            var actions: [Int: () -> Void] = [
                kVK_ANSI_Comma: { showSettings = true },
                kVK_ANSI_Q: { NSApplication.shared.terminate(nil) },
            ]
            if hasContent {
                actions[kVK_ANSI_C] = { appState.copyPromptToClipboard() }
                actions[kVK_Delete] = {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.clearAll()
                    }
                }
            }
            return actions
        }()))
    }
}

// MARK: - Settings Gear / Close Button

/// Gear icon that morphs into an X when settings are shown.
/// Click gear → open settings. Click X → close settings. Option-click → quit.
private struct SettingsGearButton: View {
    @Binding var showSettings: Bool
    @State private var isHovered = false
    @Environment(\.optionKeyHeld) private var optionHeld

    var body: some View {
        Button {
            if optionHeld {
                NSApplication.shared.terminate(nil)
            } else {
                showSettings.toggle()
            }
        } label: {
            ZStack {
                // Power icon (option held)
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .scaleEffect(optionHeld ? 1 : 0.5)
                    .blur(radius: optionHeld ? 0 : 3)
                    .opacity(optionHeld ? 1 : 0)

                // Gear icon (main page, no option)
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .scaleEffect(!optionHeld && !showSettings ? 1 : 0.5)
                    .blur(radius: !optionHeld && !showSettings ? 0 : 3)
                    .opacity(!optionHeld && !showSettings ? 1 : 0)

                // X icon (settings page, no option)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .scaleEffect(!optionHeld && showSettings ? 1 : 0.5)
                    .blur(radius: !optionHeld && showSettings ? 0 : 3)
                    .opacity(!optionHeld && showSettings ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: optionHeld)
            .animation(.easeInOut(duration: 0.25), value: showSettings)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .opacity(isHovered ? 1 : 0.7)
        .help(optionHeld ? "Quit Relay" : showSettings ? "Close Settings" : "Settings")
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
                    .transition(.opacity)

                FooterButtonsView(
                    showCopied: showCopiedConfirmation,
                    hasContent: hasContent,
                    onCopy: onCopy,
                    onClear: onClear
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .scale(0.95)).combined(with: .blurReplace))
            }
        }
    }
}

/// Animated footer buttons: Clear Stack collapses while Copy Prompt expands to "Copied!".
private struct FooterButtonsView: View {
    let showCopied: Bool
    let hasContent: Bool
    var onCopy: () -> Void
    var onClear: () -> Void

    private static let copiedColor = successGreen

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
                    .foregroundStyle(.primary.opacity(clearHovered ? 0.95 : 0.8))
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
                    .fill(Color.primary.opacity(clearHovered ? 0.14 : 0.1))
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
                        .foregroundStyle(Self.copiedColor)
                        .scaleEffect(collapsed ? 1 : 0.5)
                        .opacity(collapsed ? 1 : 0)
                        .blur(radius: collapsed ? 0 : 4)
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(copyHovered ? 0.95 : 0.8))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(collapsed ? Self.copiedColor.opacity(0.12) : Color.primary.opacity(copyHovered ? 0.14 : 0.1))
            )
            .onHover { copyHovered = $0 }
        }
        .onChange(of: showCopied) { _, newValue in
            if newValue {
                withAnimation(.snappy(duration: 0.35)) {
                    collapsed = true
                }
            } else if hasContent {
                // Content still visible — animate the buttons back
                withAnimation(.snappy(duration: 0.35)) {
                    collapsed = false
                }
            } else {
                // Footer is being removed — skip animation to avoid racing the exit transition
                collapsed = false
            }
        }
    }
}

// MARK: - Settings Page

private struct SettingsPage: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool
    @ObservedObject var voiceManager: VoiceManager

    var body: some View {
        // Header — matches main page
        HStack {
            Text("Settings")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            SettingsGearButton(showSettings: $showSettings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)

        VStack(alignment: .leading, spacing: 8) {
            Text("Voice Engine")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Picker("Engine", selection: $voiceManager.selectedEngineType) {
                    ForEach(SpeechEngineType.allCases) { engine in
                        Text(engine.label).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(voiceManager.isRecording)

                if voiceManager.currentEngineNeedsDownload || voiceManager.isDownloading || voiceManager.downloadComplete {
                    EngineDownloadButton(voiceManager: voiceManager)
                } else if appState.isDemo {
                    EngineDownloadButton(voiceManager: voiceManager, demo: true)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

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

            Toggle("Capture clipboard on start", isOn: $appState.captureClipboardOnStart)
                .font(.caption)

            Divider()

            Text("After Dictation")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Auto-copy dictation", isOn: $appState.autoCopyDictation)
                .font(.caption)

            Toggle("Auto-copy composed prompt", isOn: $appState.autoCopyComposedPrompt)
                .font(.caption)

            if appState.autoCopyDictation || appState.autoCopyComposedPrompt {
                Toggle("Auto-paste to focused app", isOn: $appState.autoPasteAfterCopy)
                    .font(.caption)
                    .padding(.leading, 12)
            }

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

            Text("Prompt Order")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Picker("Prompt order", selection: $appState.voiceNotePosition) {
                ForEach(VoiceNotePosition.allCases) { position in
                    Text(position.label).tag(position)
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
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
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
