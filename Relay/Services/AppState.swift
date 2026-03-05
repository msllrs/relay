import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var stack = ContextStack()
    @Published var isMonitoring = true
    @Published var taskIntent = ""
    @Published var showCopiedConfirmation = false

    private var clipboardMonitor: ClipboardMonitor?
    private var cancellables = Set<AnyCancellable>()

    /// The change count to ignore (set after we write to the pasteboard)
    var lastWrittenChangeCount: Int?

    init() {
        clipboardMonitor = ClipboardMonitor(appState: self)

        // Forward stack changes so SwiftUI picks them up
        stack.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func startMonitoring() {
        isMonitoring = true
        clipboardMonitor?.start()
    }

    func stopMonitoring() {
        isMonitoring = false
        clipboardMonitor?.stop()
    }

    func toggleMonitoring() {
        if isMonitoring {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    func copyPromptToClipboard() {
        let prompt = PromptComposer.compose(task: taskIntent, items: stack.items)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        lastWrittenChangeCount = pasteboard.changeCount

        showCopiedConfirmation = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            showCopiedConfirmation = false
        }
    }
}
