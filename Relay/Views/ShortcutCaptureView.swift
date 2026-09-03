import SwiftUI

// MARK: - Shortcut Capture

/// NSViewRepresentable that captures the next keyDown event with modifier flags.
struct ShortcutCaptureView: NSViewRepresentable {
    let onCapture: (KeyboardShortcutModel) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {}
}

final class ShortcutCaptureNSView: NSView {
    var onCapture: ((KeyboardShortcutModel) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    /// Claim first responder the moment we land in a window. SwiftUI gives no
    /// guarantee about when it attaches the NSView to its window relative to
    /// makeNSView (on Sequoia it happened *after* a deferred main-queue block
    /// had already run against a nil window, leaving the recorder unfocused
    /// and stuck on "Press shortcut..."). Hooking the attach itself works for
    /// every ordering.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

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
