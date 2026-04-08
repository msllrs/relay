<img src="Resources/icon.png" alt="Relay icon" width="64">

# Relay

A macOS menu bar app that lets you build rich LLM prompts by combining clipboard captures and voice notes. It bridges the gap between _"I have stuff on screen"_ and _"I need to explain it to an llm."_

## What it does

As you dictate, clipboard captures are woven inline with your transcription, landing exactly where you referenced them. No copy-paste choreography, just talk and the context assembles itself into a structured Markdown prompt ready to paste into any LLM.

<img src="Resources/screenshot.png" alt="Relay popover" width="560">

## Features

- **Clipboard capture** — Automatically collects what you copy with content type detection (code, URL, terminal, JSON, text)
- **Screenshots, files, and folders** — Drag and drop images, files, or entire folders to add them as context
- **Voice notes** — Record and transcribe with native macOS speech recognition, WhisperKit, or Parakeet
- **Recording overlay** — A draggable floating indicator that shows live audio levels, flashes on new clipboard captures, and doubles as a stop button
- **Prompt composition** — Generates structured prompts in Markdown format, with an option to switch to XML
- **Auto-paste** — Optionally copy and paste the result straight into the focused app after dictation
- **Transcript cleanup** — Three modes for transcription output: Raw (verbatim), Clean (strips filler words like "um" and "basically"), and Formatted (clean + capitalization, deduplication, punctuation)
- **Global hotkey** — Customizable keyboard shortcut for recording and composing

## Install

Download the latest DMG from [Releases](https://github.com/msllrs/relay/releases) and drag to Applications.

## Build from source

Requires macOS 15+ and Swift 6.0 toolchain.

```
git clone https://github.com/msllrs/relay.git
cd relay
./build-app.sh
open .build/Relay.app
```

Use `./build-app.sh --release` for an optimized build. Use `./build-app.sh --notarize` to create a signed, notarized release with DMG.

## Troubleshooting

**Global hotkey stops toggling recording** — On older versions, the hotkey could get into a state where it no longer started or stopped recording correctly. This was fixed in v0.3.3. If you're on an older version, update or reinstall from [Releases](https://github.com/msllrs/relay/releases).

## License

© 2026 Matt Sellers

Licensed under [PolyForm Shield 1.0.0](LICENSE.md)
