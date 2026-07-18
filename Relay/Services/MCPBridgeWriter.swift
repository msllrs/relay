import Combine
import Foundation

/// Writes Relay's context stack and composed prompt to disk so an external
/// MCP server can read them on demand, enabling Claude Code integration.
@MainActor
final class MCPBridgeWriter {
    private weak var appState: AppState?
    private var cancellables = Set<AnyCancellable>()
    private var writeTask: Task<Void, Never>?
    private var signalTimer: Timer?
    private var imagePathCache: [String: String] = [:]

    static let bridgeDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Relay/mcp", isDirectory: true)
    }()

    private static let imagesDirectory: URL = {
        bridgeDirectory.appendingPathComponent("images", isDirectory: true)
    }()

    private static let signalDirectory: URL = {
        bridgeDirectory.appendingPathComponent("signal", isDirectory: true)
    }()

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        // Clean up any previous subscriptions before re-subscribing
        cancellables.removeAll()
        signalTimer?.invalidate()

        guard let appState else { return }

        // objectWillChange fires before the new value is applied.
        // Delay with .receive(on:) so performWrite reads the updated state.
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        appState.stack.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleWrite() }
            .store(in: &cancellables)

        // Poll for signal files from the MCP server
        signalTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkSignals()
            }
        }

        // Write immediately on start
        scheduleWrite()
    }

    func stop() {
        writeTask?.cancel()
        signalTimer?.invalidate()
        signalTimer = nil
        cancellables.removeAll()
        imagePathCache.removeAll()
        try? FileManager.default.removeItem(at: Self.bridgeDirectory)
    }

    // MARK: - Signal Handling

    private func checkSignals() {
        let stopSignal = Self.signalDirectory.appendingPathComponent("stop")
        guard FileManager.default.fileExists(atPath: stopSignal.path) else { return }

        // Remove the signal file immediately to prevent re-triggering
        try? FileManager.default.removeItem(at: stopSignal)

        guard let appState, appState.isRecording else { return }
        appState.finishDictationAndStop()
    }

    // MARK: - Private

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            performWrite()
        }
    }

    private func performWrite() {
        guard let appState else { return }

        let items = appState.stack.items
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Stabilize image paths (copy from temp to persistent location)
        let stabilizedItems = items.map { stabilizeImagePath($0) }

        // Clean up orphaned images
        cleanOrphanedImages(keeping: stabilizedItems)

        // 1. state.json
        let state = StatePayload(
            version: 1,
            timestamp: Date(),
            items: stabilizedItems,
            settings: .init(
                promptFormat: appState.promptFormat.rawValue,
                voiceNotePosition: appState.voiceNotePosition.rawValue,
                transcriptEnhancement: appState.transcriptEnhancement.rawValue
            )
        )
        if let data = try? encoder.encode(state) {
            try? atomicWrite(data, to: Self.bridgeDirectory.appendingPathComponent("state.json"))
        }

        // 2. status.json
        let status = StatusPayload(
            version: 1,
            timestamp: Date(),
            isRecording: appState.isRecording,
            itemCount: items.count,
            hasVoiceNote: items.contains { $0.contentType == .voiceNote }
        )
        if let data = try? encoder.encode(status) {
            try? atomicWrite(data, to: Self.bridgeDirectory.appendingPathComponent("status.json"))
        }

        // 3. prompt.txt
        let prompt = composePrompt(items: items, appState: appState)
        if let data = prompt.data(using: .utf8) {
            try? atomicWrite(data, to: Self.bridgeDirectory.appendingPathComponent("prompt.txt"))
        }
    }

    private func composePrompt(items: [ClipboardItem], appState: AppState) -> String {
        let nonEmptyVoiceNotes = items.filter {
            $0.contentType == .voiceNote
                && !($0.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let hasNonVoiceItems = items.contains { $0.contentType != .voiceNote }
        let onlyVoiceNotes = !nonEmptyVoiceNotes.isEmpty && !hasNonVoiceItems

        if onlyVoiceNotes {
            return nonEmptyVoiceNotes.compactMap(\.textContent).joined(separator: " ")
        }
        return PromptComposer.compose(
            items: items,
            format: appState.promptFormat,
            voiceNotePosition: appState.voiceNotePosition
        )
    }

    private func stabilizeImagePath(_ item: ClipboardItem) -> ClipboardItem {
        guard let originalPath = item.imagePath else { return item }
        if let cached = imagePathCache[originalPath] {
            return ClipboardItem(
                id: item.id, contentType: item.contentType,
                textContent: item.textContent, imagePath: cached,
                timestamp: item.timestamp
            )
        }

        let filename = URL(fileURLWithPath: originalPath).lastPathComponent
        let destURL = Self.imagesDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.copyItem(atPath: originalPath, toPath: destURL.path)
            }
            imagePathCache[originalPath] = destURL.path
            return ClipboardItem(
                id: item.id, contentType: item.contentType,
                textContent: item.textContent, imagePath: destURL.path,
                timestamp: item.timestamp
            )
        } catch {
            return item
        }
    }

    private func cleanOrphanedImages(keeping items: [ClipboardItem]) {
        let keepFilenames = Set(items.compactMap { $0.imagePath }.map { URL(fileURLWithPath: $0).lastPathComponent })
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: Self.imagesDirectory.path) else { return }
        for filename in contents where !keepFilenames.contains(filename) {
            try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent(filename))
            imagePathCache = imagePathCache.filter { $0.value != Self.imagesDirectory.appendingPathComponent(filename).path }
        }
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }

    // MARK: - Payloads

    private struct StatePayload: Codable {
        let version: Int
        let timestamp: Date
        let items: [ClipboardItem]
        let settings: Settings

        struct Settings: Codable {
            let promptFormat: String
            let voiceNotePosition: String
            let transcriptEnhancement: String
        }
    }

    private struct StatusPayload: Codable {
        let version: Int
        let timestamp: Date
        let isRecording: Bool
        let itemCount: Int
        let hasVoiceNote: Bool
    }
}
