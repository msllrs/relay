#!/usr/bin/env node

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
  ListPromptsRequestSchema,
  GetPromptRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import * as fs from "fs/promises";
import * as path from "path";
import * as os from "os";

const BRIDGE_DIR = path.join(
  os.homedir(),
  "Library",
  "Application Support",
  "Relay",
  "mcp"
);

const NOT_ACTIVE_MSG =
  "Relay bridge not active. Enable 'MCP bridge for Claude Code' in Relay settings.";

async function readBridgeFile(filename: string): Promise<string> {
  return fs.readFile(path.join(BRIDGE_DIR, filename), "utf-8");
}

async function bridgeFileExists(filename: string): Promise<boolean> {
  try {
    await fs.access(path.join(BRIDGE_DIR, filename));
    return true;
  } catch {
    return false;
  }
}

const SIGNAL_DIR = path.join(BRIDGE_DIR, "signal");

function textResult(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function writeSignalFile(signal: string): Promise<void> {
  await fs.mkdir(SIGNAL_DIR, { recursive: true });
  await fs.writeFile(path.join(SIGNAL_DIR, signal), "");
}

async function waitForRecordingStop(
  timeoutMs: number = 10000
): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const raw = await readBridgeFile("status.json");
      const status = JSON.parse(raw);
      if (!status.isRecording) return true;
    } catch {
      // file may not exist yet
    }
    await sleep(300);
  }
  return false;
}

// --- Server ---

const server = new Server(
  { name: "relay-mcp", version: "1.0.0" },
  { capabilities: { tools: {}, resources: {}, prompts: {} } }
);

// Tools

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "relay_get_context",
      description:
        "Get the composed prompt from Relay's current context stack. " +
        "Returns the same output that Relay's 'Copy Prompt' button produces — " +
        "structured XML or Markdown with voice notes and clipboard items.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "relay_get_stack",
      description:
        "Get Relay's full context stack as structured JSON. " +
        "Includes all clipboard items, voice notes, content types, timestamps, and current settings.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "relay_get_status",
      description:
        "Get Relay's current status — whether it's recording, how many items are in the stack, etc.",
      inputSchema: { type: "object" as const, properties: {} },
    },
    {
      name: "relay_stop_and_get_context",
      description:
        "Stop Relay's active recording, wait for the transcript to finalize, " +
        "then return the composed prompt. If not recording, returns the current context immediately.",
      inputSchema: { type: "object" as const, properties: {} },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name } = request.params;

  // Simple file-read tools
  const fileMap: Record<string, string> = {
    relay_get_context: "prompt.txt",
    relay_get_stack: "state.json",
    relay_get_status: "status.json",
  };

  if (name in fileMap) {
    const filename = fileMap[name];
    if (!(await bridgeFileExists(filename))) {
      return textResult(NOT_ACTIVE_MSG);
    }
    return textResult(await readBridgeFile(filename));
  }

  // Stop recording, then return context
  if (name === "relay_stop_and_get_context") {
    if (!(await bridgeFileExists("status.json"))) {
      return textResult(NOT_ACTIVE_MSG);
    }

    // Check if currently recording
    try {
      const raw = await readBridgeFile("status.json");
      const status = JSON.parse(raw);
      if (status.isRecording) {
        await writeSignalFile("stop");
        const stopped = await waitForRecordingStop();
        if (!stopped) {
          return textResult(
            "Timed out waiting for Relay to stop recording. " +
              "Try stopping manually, then use relay_get_context."
          );
        }
        // Give the bridge writer time to flush prompt.txt after finalization
        await sleep(500);
      }
    } catch {
      // Fall through to read prompt anyway
    }

    if (!(await bridgeFileExists("prompt.txt"))) {
      return textResult("Relay has no context items.");
    }
    return textResult(await readBridgeFile("prompt.txt"));
  }

  throw new Error(`Unknown tool: ${name}`);
});

// Resources

server.setRequestHandler(ListResourcesRequestSchema, async () => ({
  resources: [
    {
      uri: "relay://context/current",
      name: "Current Relay prompt",
      description: "The composed prompt from Relay's context stack",
      mimeType: "text/plain",
    },
    {
      uri: "relay://stack",
      name: "Relay context stack",
      description: "Full context stack as JSON",
      mimeType: "application/json",
    },
  ],
}));

server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const { uri } = request.params;

  const resourceMap: Record<string, { file: string; mime: string }> = {
    "relay://context/current": { file: "prompt.txt", mime: "text/plain" },
    "relay://stack": { file: "state.json", mime: "application/json" },
  };

  const resource = resourceMap[uri];
  if (!resource) {
    throw new Error(`Unknown resource: ${uri}`);
  }

  if (!(await bridgeFileExists(resource.file))) {
    return {
      contents: [{ uri, mimeType: resource.mime, text: NOT_ACTIVE_MSG }],
    };
  }

  const text = await readBridgeFile(resource.file);
  return {
    contents: [{ uri, mimeType: resource.mime, text }],
  };
});

// Prompts (slash commands)

server.setRequestHandler(ListPromptsRequestSchema, async () => ({
  prompts: [
    {
      name: "relay_context",
      description:
        "Inject Relay's current context stack into the conversation. " +
        "Use this to pull in voice notes and clipboard items from Relay.",
    },
  ],
}));

server.setRequestHandler(GetPromptRequestSchema, async (request) => {
  const { name } = request.params;

  if (name !== "relay_context") {
    throw new Error(`Unknown prompt: ${name}`);
  }

  if (!(await bridgeFileExists("prompt.txt"))) {
    return {
      messages: [
        {
          role: "user" as const,
          content: { type: "text" as const, text: NOT_ACTIVE_MSG },
        },
      ],
    };
  }

  const prompt = await readBridgeFile("prompt.txt");
  const status = (await bridgeFileExists("status.json"))
    ? await readBridgeFile("status.json")
    : null;

  let intro = "Here is context captured in Relay:";
  if (status) {
    try {
      const s = JSON.parse(status);
      const n = s.itemCount ?? 0;
      intro = `Here is context captured in Relay (${n} item${n === 1 ? "" : "s"}):`;
    } catch {
      // ignore parse errors
    }
  }

  return {
    messages: [
      {
        role: "user" as const,
        content: {
          type: "text" as const,
          text: `${intro}\n\n${prompt}`,
        },
      },
    ],
  };
});

// Start

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("Relay MCP server running on stdio");
