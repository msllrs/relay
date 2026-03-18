import Carbon.HIToolbox
import SwiftUI

let successGreen = Color(nsColor: NSColor(name: nil) { appearance in
    if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
        NSColor(red: 0, green: 0.788, blue: 0.471, alpha: 1)
    } else {
        NSColor(red: 0, green: 0.60, blue: 0.36, alpha: 1)
    }
})

struct MenuBarPopover: View {
    @EnvironmentObject var appState: AppState
    @State private var showSettings = false

    private var mainPage: some View {
        MainPage(showSettings: $showSettings)
            .frame(width: 360, alignment: .topLeading)
    }

    private var settingsPage: some View {
        SettingsPage(showSettings: $showSettings, voiceManager: appState.voiceManager, updaterManager: appState.updaterManager)
            .frame(width: 360, alignment: .topLeading)
    }

    var body: some View {
        // Both pages always exist. The active page drives height via fixedSize;
        // the inactive page is collapsed to height 0 so it doesn't influence layout.
        // Content cross-fades in place while the popover height animates smoothly.
        ZStack(alignment: .topLeading) {
            mainPage
                .frame(height: showSettings ? 0 : nil, alignment: .top)
                .clipped()
                .opacity(showSettings ? 0 : 1)
                .allowsHitTesting(!showSettings)

            settingsPage
                .frame(height: showSettings ? nil : 0, alignment: .top)
                .clipped()
                .opacity(showSettings ? 1 : 0)
                .allowsHitTesting(showSettings)
        }
        .frame(width: 360)
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: showSettings)
        .onReceive(NotificationCenter.default.publisher(for: NSPopover.didCloseNotification)) { _ in
            showSettings = false
        }
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

private struct ScrollEdgeState: Equatable {
    var pinnedToBottom: Bool
    var canScrollUp: Bool
    var canScrollDown: Bool
}

private struct MainPage: View {
    @EnvironmentObject var appState: AppState
    @Binding var showSettings: Bool
    @State private var shortcutDisplay = KeyboardShortcutModel.load().displayString
    @State private var pinnedToBottom = true
    @State private var canScrollUp = false
    @State private var canScrollDown = false

    private var hasContent: Bool {
        !appState.displayTranscription.isEmpty || appState.stack.hasNonVoiceItems
    }

    private var showProcessingIndicator: Bool {
        appState.isRecording
            && appState.voiceManager.selectedEngineType != .native
            && appState.voiceManager.partialTranscription.isEmpty
    }

    /// Cap the scroll area so long transcriptions don't push the popover off screen.
    /// Reserve ~200pt for the header, pill, and footer chrome.
    private var maxScrollHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return screenHeight * 0.85 - 200
    }

    var body: some View {
        let hasContent = hasContent

        VStack(spacing: 0) {
            // Header — hides when recording to give more room to transcription
            HStack {
                Text("Relay")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .scaleEffect(showSettings || appState.isRecording ? 0.85 : 1, anchor: .leading)
                    .blur(radius: showSettings || appState.isRecording ? 3 : 0)
                    .opacity(showSettings || appState.isRecording ? 0 : 1)
                    .offset(y: 1)
                    .animation(.easeInOut(duration: 0.25), value: showSettings)
                    .onTapGesture {
                        guard appState.isDemo else { return }
                        appState.clearAll()
                        appState.populateDemoStack()
                    }

                Spacer()

                SettingsGearButton(showSettings: $showSettings, isRecording: appState.isRecording)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, appState.isRecording ? 0 : 10)
            .frame(height: appState.isRecording ? 0 : nil)
            .clipped()

            // Prompt pill (idle or recording)
            PromptPillView(
                isRecording: appState.isRecording,
                audioLevel: appState.voiceManager.audioLevel,
                shortcutDisplay: shortcutDisplay,
                onStart: { appState.hotkeyTriggered() },
                onStop: { appState.finishDictationAndStop() }
            )
            .padding(.top, appState.isRecording ? 16 : 2)
            .padding(.bottom, hasContent || appState.showCopiedConfirmation || showProcessingIndicator ? 0 : 16)

            // Show a processing indicator for engines that buffer audio before transcribing
            if showProcessingIndicator {
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
                .padding(.bottom, 16)
                .transition(.opacity)
            }

            // Transcription text with inline chips (scrollable when popover hits max height)
            if !appState.displayTranscription.isEmpty || appState.stack.hasNonVoiceItems {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        TranscriptionTextView(
                            text: appState.displayTranscription,
                            items: appState.stack.items,
                            isRecording: appState.isRecording,
                            onRemoveRef: { appState.removeRef($0) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, hasContent ? 0 : 16)
                        .id("transcription-bottom")
                    }
                    .onScrollGeometryChange(for: ScrollEdgeState.self) { geo in
                        let overflow = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                        return ScrollEdgeState(
                            pinnedToBottom: overflow < 30,
                            canScrollUp: geo.contentOffset.y > 5,
                            canScrollDown: overflow > 5
                        )
                    } action: { _, state in
                        pinnedToBottom = state.pinnedToBottom
                        canScrollUp = state.canScrollUp
                        canScrollDown = state.canScrollDown
                    }
                    .onChange(of: appState.displayTranscription) { _, _ in
                        if appState.isRecording && pinnedToBottom {
                            proxy.scrollTo("transcription-bottom", anchor: .bottom)
                        }
                    }
                    .mask {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: canScrollUp ? 24 : 0)
                            Rectangle().fill(.black)
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: canScrollDown ? 24 : 0)
                        }
                        .animation(.easeOut(duration: 0.12), value: canScrollUp)
                        .animation(.easeOut(duration: 0.12), value: canScrollDown)
                    }
                }
                .padding(.top, 16)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: maxScrollHeight)
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
                kVK_ANSI_Comma: { withAnimation(.easeInOut(duration: 0.25)) { showSettings = true } },
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
struct SettingsGearButton: View {
    @Binding var showSettings: Bool
    var isRecording: Bool = false
    @State private var isHovered = false
    @Environment(\.optionKeyHeld) private var optionHeld

    /// Whether the gear/icon should be visible (hidden while recording).
    private var visible: Bool { !isRecording }

    var body: some View {
        Button {
            if optionHeld {
                NSApplication.shared.terminate(nil)
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSettings.toggle()
                }
            }
        } label: {
            ZStack {
                // Power icon (option held)
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isHovered ? .red : .secondary)
                    .scaleEffect(optionHeld && visible ? 1 : 0.5)
                    .blur(radius: optionHeld && visible ? 0 : 3)
                    .opacity(optionHeld && visible ? 1 : 0)

                // Gear icon (main page, no option)
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .scaleEffect(!optionHeld && !showSettings && visible ? 1 : 0.5)
                    .blur(radius: !optionHeld && !showSettings && visible ? 0 : 3)
                    .opacity(!optionHeld && !showSettings && visible ? 1 : 0)

                // X icon (settings page, no option)
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .scaleEffect(!optionHeld && showSettings && visible ? 1 : 0.5)
                    .blur(radius: !optionHeld && showSettings && visible ? 0 : 3)
                    .opacity(!optionHeld && showSettings && visible ? 1 : 0)
            }
            .animation(.easeInOut(duration: 0.25), value: optionHeld)
            .animation(.easeInOut(duration: 0.25), value: showSettings)
            .animation(.easeInOut(duration: 0.25), value: isRecording)
            .offset(y: 1)
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
    @State private var checkmarkTrim: CGFloat = 0
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
                    HStack(spacing: 6) {
                        CheckmarkStroke(trim: checkmarkTrim)
                            .stroke(Self.copiedColor, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                            .frame(width: 8, height: 8)
                        Text("Copied!")
                    }
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
                checkmarkTrim = 0
                withAnimation(.snappy(duration: 0.35)) {
                    collapsed = true
                }
                withAnimation(.easeOut(duration: 0.2).delay(0.08)) {
                    checkmarkTrim = 1
                }
            } else if hasContent {
                // Content still visible — animate the buttons back
                withAnimation(.snappy(duration: 0.35)) {
                    collapsed = false
                }
                checkmarkTrim = 0
            } else {
                // Footer is being removed — skip animation to avoid racing the exit transition
                collapsed = false
                checkmarkTrim = 0
            }
        }
    }
}

/// A checkmark path that can be drawn progressively via `.trim(from:to:)`.
private struct CheckmarkStroke: Shape {
    var trim: CGFloat

    var animatableData: CGFloat {
        get { trim }
        set { trim = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Two-segment checkmark: down-stroke then up-stroke
        let start = CGPoint(x: rect.minX, y: rect.midY)
        let corner = CGPoint(x: rect.width * 0.35, y: rect.maxY)
        let end = CGPoint(x: rect.maxX, y: rect.minY)

        var full = Path()
        full.move(to: start)
        full.addLine(to: corner)
        full.addLine(to: end)

        return full.trimmedPath(from: 0, to: trim)
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
