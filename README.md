<img src="Resources/icon.png" alt="Relay icon" width="64">

# Relay

A macOS menu bar app that lets you build rich LLM prompts by combining clipboard captures and voice notes. It bridges the gap between _"I have stuff on screen"_ and _"I need to explain it to an llm."_

## What it does

Copy things — code, URLs, files, text — and Relay collects them in a context stack. Drop in screenshots, files, and folders for additional context. Record a voice note to describe what you want. Hit compose and get a structured prompt in Markdown ready to paste into any LLM.

As you dictate, Relay weaves your clipboard captures inline with your transcription — so when you say "fix this error" right after copying a stack trace, the error lands exactly where you referenced it. No copy-paste choreography, just talk and the context assembles itself.

<img src="Resources/screenshot.png" alt="Relay popover" width="420">

## Features

- **Clipboard capture** — Automatically collects what you copy with content type detection (code, URL, terminal, JSON, text)
- **Screenshots, files, and folders** — Drag and drop images, files, or entire folders to add them as context
- **Voice notes** — Record and transcribe with native macOS speech recognition, WhisperKit, or Parakeet
- **Prompt composition** — Generates structured prompts in Markdown format, with an option to switch to XML
- **Global hotkey** — Customizable keyboard shortcut for recording and composing

## Install

Download the latest DMG from [Releases](https://github.com/msllrs/relay/releases), drag to Applications, then right-click → Open on first launch (ad-hoc signed).

## Build from source

Requires macOS 15+ and Swift 6.0 toolchain.

```
git clone https://github.com/msllrs/relay.git
cd relay
./build-app.sh
open .build/Relay.app
```

Use `./build-app.sh --release` for an optimized build. Use `./make-dmg.sh` to create a distributable DMG.

## License

© 2026 Matt Sellers

Licensed under [PolyForm Shield 1.0.0](LICENSE.md)
