import SwiftUI

struct RefChipView: View {
    let label: String
    let contentType: ContentType
    var previewText: String?
    var previewImage: NSImage?
    var onRemove: (() -> Void)?

    /// Shared timestamp of the last tooltip dismiss across all chips.
    @MainActor private static var lastTooltipDismiss: Date = .distantPast
    private static let warmWindow: TimeInterval = 0.4

    @State private var isHovered = false
    @State private var showPopover = false
    @State private var hoverTimer: Timer?
    @Environment(\.optionKeyHeld) private var optionHeld

    private var isWarm: Bool {
        Date().timeIntervalSince(Self.lastTooltipDismiss) < Self.warmWindow
    }

    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(contentType.chipColor)
            .padding(.vertical, 2)
            .padding(.horizontal, 8)
            .background(
                Capsule()
                    .fill(contentType.chipColor.opacity(optionHeld && isHovered ? 0.25 : 0.12))
            )
            .overlay(
                OptionClickOverlay {
                    onRemove?()
                }
            )
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    let delay: TimeInterval = isWarm ? 0 : 0.45
                    hoverTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                        MainActor.assumeIsolated { showPopover = true }
                    }
                } else {
                    hoverTimer?.invalidate()
                    hoverTimer = nil
                    if showPopover { Self.lastTooltipDismiss = Date() }
                    showPopover = false
                }
            }
            .popover(isPresented: Binding(
                get: { showPopover && !optionHeld },
                set: { if !$0 { showPopover = false } }
            ), arrowEdge: .bottom) {
                chipPreview
                    .frame(maxWidth: 280)
                    .padding(10)
            }
            .animation(.easeInOut(duration: 0.12), value: optionHeld && isHovered)
    }

    @ViewBuilder
    private var chipPreview: some View {
        if let image = previewImage {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 160)
                .cornerRadius(4)
        } else if let text = previewText, !text.isEmpty {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(8)
                .textSelection(.enabled)
        } else {
            Text("No preview")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Option key environment

private struct OptionKeyHeldKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var optionKeyHeld: Bool {
        get { self[OptionKeyHeldKey.self] }
        set { self[OptionKeyHeldKey.self] = newValue }
    }
}

/// Place this once near the root to track the option key and inject into environment.
struct OptionKeyTracker: ViewModifier {
    @State private var optionHeld = false
    @State private var monitor: Any?
    @State private var holdTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .environment(\.optionKeyHeld, optionHeld)
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
                    let onlyOption = flags == .option
                    if onlyOption && !optionHeld {
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(for: .seconds(0.5))
                            guard !Task.isCancelled else { return }
                            optionHeld = true
                        }
                    } else if !onlyOption {
                        holdTask?.cancel()
                        holdTask = nil
                        optionHeld = false
                    }
                    return event
                }
            }
            .onDisappear {
                holdTask?.cancel()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

// MARK: - Option-click overlay

/// Transparent NSView that intercepts option-clicks.
private struct OptionClickOverlay: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> OptionClickNSView {
        let view = OptionClickNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: OptionClickNSView, context: Context) {
        nsView.action = action
    }
}

private final class OptionClickNSView: NSView {
    var action: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            action?()
        } else {
            super.mouseDown(with: event)
        }
    }
}
