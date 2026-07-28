import Foundation
import MCP

/// Stdio MCP server for Relay — exposes the context stack and composed prompts
/// to Claude Code, and pushes items/commands back into the app.
///
/// Read path:  Relay's `MCPBridgeWriter` writes state.json / status.json /
/// prompt.txt under ~/Library/Application Support/Relay/mcp; this server
/// reads them on demand.
///
/// Write path: signal files (`signal/stop`) and queued items (`queue/*.json`)
/// are picked up by the app's 0.5s bridge poll; recording start/stop goes
/// through the `relay://` URL scheme via /usr/bin/open.
@main
struct RelayMCPServer {
    static func main() async throws {
        let server = Server(
            name: "relay-mcp",
            version: "1.0.0",
            capabilities: .init(
                prompts: .init(),
                resources: .init(),
                tools: .init()
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: Bridge.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            try await Bridge.callTool(name: params.name, arguments: params.arguments)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [
                Resource(
                    name: "Current Relay prompt",
                    uri: "relay://context/current",
                    description: "The composed prompt from Relay's context stack",
                    mimeType: "text/plain"
                ),
                Resource(
                    name: "Relay context stack",
                    uri: "relay://stack",
                    description: "Full context stack as JSON",
                    mimeType: "application/json"
                ),
            ])
        }

        await server.withMethodHandler(ReadResource.self) { params in
            let resourceMap: [String: (file: String, mime: String)] = [
                "relay://context/current": ("prompt.txt", "text/plain"),
                "relay://stack": ("state.json", "application/json"),
            ]
            guard let resource = resourceMap[params.uri] else {
                throw MCPError.invalidParams("Unknown resource: \(params.uri)")
            }
            let text = Bridge.readBridgeFile(resource.file) ?? Bridge.notActiveMessage
            return .init(contents: [.text(text, uri: params.uri, mimeType: resource.mime)])
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            .init(prompts: [
                Prompt(
                    name: "relay_context",
                    description: "Inject Relay's current context stack into the conversation. "
                        + "Use this to pull in voice notes and clipboard items from Relay."
                )
            ])
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            guard params.name == "relay_context" else {
                throw MCPError.invalidParams("Unknown prompt: \(params.name)")
            }
            guard let prompt = Bridge.readBridgeFile("prompt.txt") else {
                return .init(messages: [.user(.text(text: Bridge.notActiveMessage))])
            }
            var intro = "Here is context captured in Relay:"
            if let status = Bridge.readStatus() {
                let n = status.itemCount
                intro = "Here is context captured in Relay (\(n) item\(n == 1 ? "" : "s")):"
            }
            return .init(messages: [.user(.text(text: "\(intro)\n\n\(prompt)"))])
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        FileHandle.standardError.write(Data("Relay MCP server running on stdio\n".utf8))
        await server.waitUntilCompleted()
    }
}

// MARK: - Bridge

/// File-based bridge to the Relay app. All members are stateless helpers so
/// the type is trivially Sendable for use inside MCP handler closures.
enum Bridge {
    static let notActiveMessage =
        "Relay bridge not active. Enable 'MCP bridge for Claude Code' in Relay settings."

    static var bridgeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Relay/mcp", isDirectory: true)
    }

    static var signalDirectory: URL {
        bridgeDirectory.appendingPathComponent("signal", isDirectory: true)
    }

    static var queueDirectory: URL {
        bridgeDirectory.appendingPathComponent("queue", isDirectory: true)
    }

    /// URL scheme for recording commands. Production builds register `relay`;
    /// dev builds register `relay-dev` (set RELAY_URL_SCHEME to target one).
    static var urlScheme: String {
        ProcessInfo.processInfo.environment["RELAY_URL_SCHEME"] ?? "relay"
    }

    struct Status: Decodable {
        let isRecording: Bool
        let itemCount: Int
        let hasVoiceNote: Bool
    }

    // MARK: File access

    static func readBridgeFile(_ filename: String) -> String? {
        try? String(contentsOf: bridgeDirectory.appendingPathComponent(filename), encoding: .utf8)
    }

    static func bridgeFileExists(_ filename: String) -> Bool {
        FileManager.default.fileExists(atPath: bridgeDirectory.appendingPathComponent(filename).path)
    }

    static func readStatus() -> Status? {
        guard let raw = readBridgeFile("status.json"), let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(Status.self, from: data)
    }

    static func writeSignalFile(_ signal: String) throws {
        try FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)
        try Data().write(to: signalDirectory.appendingPathComponent(signal))
    }

    static func waitForRecordingStop(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let status = readStatus(), !status.isRecording { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    static func waitForRecordingState(_ recording: Bool, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let status = readStatus(), status.isRecording == recording { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
    }

    /// Open a `relay://` command URL with /usr/bin/open (NSWorkspace is not
    /// available to a headless CLI).
    static func openRelayURL(command: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["\(urlScheme)://\(command)"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw MCPError.internalError(
                "Could not open \(urlScheme)://\(command) — is Relay installed and running?")
        }
    }

    // MARK: Tool definitions

    private static let emptySchema: Value = .object([
        "type": .string("object"),
        "properties": .object([:]),
    ])

    static let tools: [Tool] = [
        Tool(
            name: "relay_get_context",
            description: "Get the composed prompt from Relay's current context stack. "
                + "Returns the same output that Relay's 'Copy Prompt' button produces — "
                + "structured XML or Markdown with voice notes and clipboard items.",
            inputSchema: emptySchema
        ),
        Tool(
            name: "relay_get_stack",
            description: "Get Relay's full context stack as structured JSON. "
                + "Includes all clipboard items, voice notes, content types, timestamps, and current settings.",
            inputSchema: emptySchema
        ),
        Tool(
            name: "relay_get_status",
            description: "Get Relay's current status — whether it's recording, "
                + "how many items are in the stack, etc.",
            inputSchema: emptySchema
        ),
        Tool(
            name: "relay_stop_and_get_context",
            description: "Stop Relay's active recording, wait for the transcript to finalize, "
                + "then return the composed prompt. If not recording, returns the current context immediately.",
            inputSchema: emptySchema
        ),
        Tool(
            name: "relay_add_context",
            description: "Push a text item onto Relay's context stack. "
                + "Optionally specify a content type; omit it to let Relay classify the text automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("The text content to add to the stack."),
                    ]),
                    "type": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Content type for the item. One of: code, json, markdown, terminal, "
                                + "url, error, diff, text. Omit to auto-classify."),
                    ]),
                ]),
                "required": .array([.string("text")]),
            ])
        ),
        Tool(
            name: "relay_start_recording",
            description: "Start a Relay dictation session (voice recording). "
                + "Requires 'Siri voice activation' to be enabled in Relay settings. "
                + "No-op if already recording.",
            inputSchema: emptySchema
        ),
        Tool(
            name: "relay_stop_recording",
            description: "Stop Relay's active dictation session and save the transcription. "
                + "Requires 'Siri voice activation' to be enabled in Relay settings. "
                + "Use relay_stop_and_get_context instead to stop and fetch the prompt in one step.",
            inputSchema: emptySchema
        ),
    ]

    // MARK: Tool dispatch

    static func callTool(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        switch name {
        case "relay_get_context":
            return textResult(forBridgeFile: "prompt.txt")
        case "relay_get_stack":
            return textResult(forBridgeFile: "state.json")
        case "relay_get_status":
            return textResult(forBridgeFile: "status.json")
        case "relay_stop_and_get_context":
            return try await stopAndGetContext()
        case "relay_add_context":
            return try await addContext(arguments: arguments)
        case "relay_start_recording":
            return try await startRecording()
        case "relay_stop_recording":
            return try await stopRecording()
        default:
            throw MCPError.invalidParams("Unknown tool: \(name)")
        }
    }

    private static func textResult(forBridgeFile filename: String) -> CallTool.Result {
        guard let text = readBridgeFile(filename) else {
            return .init(content: [.text(notActiveMessage)])
        }
        return .init(content: [.text(text)])
    }

    private static func stopAndGetContext() async throws -> CallTool.Result {
        guard bridgeFileExists("status.json") else {
            return .init(content: [.text(notActiveMessage)])
        }
        if let status = readStatus(), status.isRecording {
            try writeSignalFile("stop")
            guard await waitForRecordingStop() else {
                return .init(content: [
                    .text("Timed out waiting for Relay to stop recording. "
                        + "Try stopping manually, then use relay_get_context.")
                ])
            }
            // Give the bridge writer time to flush prompt.txt after finalization
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let prompt = readBridgeFile("prompt.txt") else {
            return .init(content: [.text("Relay has no context items.")])
        }
        return .init(content: [.text(prompt)])
    }

    private static func addContext(arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let text = arguments?["text"]?.stringValue, !text.isEmpty else {
            return .init(content: [.text("Missing required 'text' argument.")], isError: true)
        }
        guard bridgeFileExists("status.json") else {
            return .init(content: [.text(notActiveMessage)])
        }

        var payload: [String: String] = ["text": text]
        if let type = arguments?["type"]?.stringValue {
            payload["type"] = type
        }
        let data = try JSONEncoder().encode(payload)

        // Timestamped filename keeps consumption ordered when several items
        // are queued in one burst.
        let filename = String(format: "%.6f-%@.json", Date().timeIntervalSince1970, UUID().uuidString)
        try FileManager.default.createDirectory(at: queueDirectory, withIntermediateDirectories: true)
        let fileURL = queueDirectory.appendingPathComponent(filename)
        try data.write(to: fileURL)

        // The app's bridge poll consumes queue files every 0.5s — wait briefly
        // so we can confirm the item actually landed on the stack.
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                return .init(content: [.text("Added item to Relay's context stack.")])
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return .init(content: [
            .text("Item queued, but Relay hasn't picked it up yet. "
                + "Make sure Relay is running with the MCP bridge enabled.")
        ])
    }

    private static func startRecording() async throws -> CallTool.Result {
        if let status = readStatus(), status.isRecording {
            return .init(content: [.text("Relay is already recording.")])
        }
        try openRelayURL(command: "start-recording")
        if await waitForRecordingState(true) {
            return .init(content: [.text("Relay is now recording.")])
        }
        return .init(content: [
            .text("Sent start-recording to Relay, but it hasn't started. "
                + "Make sure 'Siri voice activation' is enabled in Relay settings.")
        ])
    }

    private static func stopRecording() async throws -> CallTool.Result {
        if let status = readStatus(), !status.isRecording {
            return .init(content: [.text("Relay is not recording.")])
        }
        try openRelayURL(command: "stop-recording")
        if await waitForRecordingState(false) {
            return .init(content: [.text("Recording stopped; the transcription was saved to the stack.")])
        }
        return .init(content: [
            .text("Sent stop-recording to Relay, but it hasn't stopped. "
                + "Make sure 'Siri voice activation' is enabled in Relay settings.")
        ])
    }
}
