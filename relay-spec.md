# Project Brief: Relay — macOS Menu Bar Clipboard + Voice → LLM Prompt Composer

You are building a macOS menu bar application called **Relay**. It captures clipboard content and voice dictation, then composes them into structured prompts ready to paste into an LLM. The app has no Dock icon — it lives entirely in the menu bar.

## Core Concept

Relay bridges the gap between *gathering context* (code snippets, URLs, errors, images, files) and *talking about that context* (voice notes). The user copies things, narrates what they want, and Relay produces a single structured prompt combining everything.

---

## Feature Inventory

### 1. Clipboard Monitoring
- Poll `NSPasteboard` every ~0.5 seconds while monitoring is active
- Capture **text** (auto-classified by content type), **images** (saved as temp PNGs), and **file URLs**
- Deduplicate against the last captured item (by text content or image bytes)
- Truncate text items over 10KB with a `[truncated]` suffix
- Optional: capture the current clipboard contents immediately when monitoring starts
- Maintain a **context stack** of up to 20 items (FIFO eviction)
- Prevent feedback loops: skip pasteboard changes written by the app itself

### 2. Content Classification
Classify captured text into types using a priority chain (first match wins):
1. **JSON** — starts with `{` or `[` and parses successfully
2. **URL** — single line with http/https/ftp/ssh/file scheme
3. **Diff/Patch** — contains `diff --git`, `---`/`+++` lines, `@@` hunks
4. **Error/Stack Trace** — lines with `Error:`, `Exception`, `Traceback`, `panic:`, stack frame patterns (≥2 indicators)
5. **Terminal** — lines starting with `$ `, `% `, `> `, or ANSI escape codes
6. **Markdown** — ≥2 of: ATX headings, fenced code blocks, bullet lists, links, bold
7. **Code** — ≥2 language keyword hits, or brace+indent patterns
8. **Plain Text** — fallback

Each type has an assigned color for UI chips (e.g., code=blue, error=red, url=sky, json=teal, image=purple, voice=pink).

### 3. Voice Dictation
- Three speech engine implementations behind a common protocol:
  - **Native** (Apple `SFSpeechRecognizer` + `AVAudioEngine`) — zero download, real-time streaming partials
  - **WhisperKit** (local Whisper model, ~142MB download) — periodic batch transcription every 1.5s
  - **Parakeet / FluidAudio** (local ASR model) — streaming with confirmed + volatile transcript segments
- Live partial transcription displayed during recording
- Audio level (RMS) drives an animated waveform visualization
- Start/stop via global hotkey, UI button, or push-to-talk (hold to record, release to stop)
- Cancel with Escape (discards the recording)
- Skip first ~3 audio buffers to avoid hardware startup transients misrecognized as speech
- Always create a fresh `AVAudioEngine` per recording session (persistent engines produce stale/zero audio)
- Use `nil` as the tap format — let Core Audio negotiate (explicit formats break AirPods/device switching)

### 4. Reference Markers (Core Differentiator)
When the user copies something to the clipboard *during* an active recording:
- A `[ref:N]` marker is inserted into the transcription at the proportional time offset where the copy happened
- Markers snap to the nearest word boundary in the transcript
- In the UI, markers render as **colored chips** inline with the transcription text
- Hovering a chip shows a **popover preview** of the referenced content (text preview or image thumbnail)
- Option-clicking a chip **removes** it: strips the marker from the text, removes the stack item, and renumbers all higher refs
- During live recording, markers are continuously recalculated as the partial transcript grows

### 5. Prompt Composition
Combine all stack items into a structured prompt. Two output formats:

**XML format:**
```xml
<context>
<item type="voice_note">
transcribed text with [ref:1] markers
</item>

<item type="code" index="1">
code content here
</item>
</context>
```

**Markdown format:**
```markdown
## Context

### Voice Note
transcribed text

### 1. Code
\`\`\`
code content
\`\`\`
```

- Voice note position is configurable: **Top**, **Bottom**, or **Inline**
- Voice notes have no index number; other items get sequential 1-based indices
- Images render as `[image: /path/to/file.png]`
- If the stack contains *only* voice notes (no clipboard context), output the raw text without any wrapper

### 6. Transcript Enhancement
Three levels of post-processing on voice transcription:
- **Off** — verbatim text
- **Clean** — removes filler words while preserving ref markers:
  - Phrase fillers: "you know", "I mean", "sort of", "kind of"
  - Hedge patterns: ", like,"
  - Sentence-initial "so" / "well"
  - Context-aware removal of "like" (after conjunctions, before intensifiers, sentence-initial before pronouns) and "right" (after conjunctions, sentence-initial)
  - Always-remove: "um", "uh", "uhh", "hmm", "basically", "actually", "literally"
  - Collapse whitespace, clean punctuation spacing
- **Formatted** — everything in Clean, plus: deduplicate adjacent identical words, capitalize after sentence boundaries, add trailing period

### 7. Menu Bar UI

**Status item icon:**
- Custom SVG-based icon with two states: closed arc (idle) and open arc (active/monitoring)
- Animated dot overlay: orange dot during recording, green dot briefly when a new item is added
- Dot transitions: scale-in 150ms, scale-out 120ms, color swap with bounce

**Popover (main window):**
- Fixed width ~360pt, max height 85% of screen
- **Header**: app title, pin button (when pinned), settings gear
- **Prompt pill**: rounded rectangle showing idle hint text ("Press ⇧⌘R to start recording") or stop button + waveform during recording
- **Scrollable content area**: transcription text with inline ref chips, using a custom `FlowLayout` that wraps words and chips across rows
- **Scroll edge masking**: fade gradients at top/bottom when content overflows
- **Footer**: "Clear Stack" + "Copy Prompt" buttons; Clear collapses on copy, checkmark animates on success
- Header collapses (height → 0) during recording to maximize content space
- Cross-fade transition between main page and settings page

**Floating recording overlay:**
- Appears when recording with the popover closed
- Non-activating panel (doesn't steal focus) at status bar window level
- Shows: mini 3-bar waveform, clipboard icon when a new item arrives, stop square on hover
- Draggable; snaps back to default position (below status item) if dropped within 40pt of it

### 8. Settings
Organized in sections:

**Voice:** engine picker, model download button with progress, input device picker, max mic volume toggle

**Behavior:** push-to-talk, capture clipboard on start, keep popover pinned, show recording overlay, clear after copying

**After dictation:** auto-copy prompt, auto-paste to focused input (nested under auto-copy; requires Accessibility permission)

**Prompt:** format (XML/Markdown), voice note position (Top/Bottom/Inline), transcript enhancement level (Off/Clean/Formatted)

**Keyboard shortcut:** custom shortcut recorder (click to capture next key+modifier combo), reset to default (⇧⌘R)

**Footer:** version number, author link, GitHub link, check for updates, quit button

### 9. Global Hotkey System
- **Carbon hotkey** (`RegisterEventHotKey`) — works globally without Accessibility permission
- **NSEvent local monitor** — catches the shortcut when the popover is focused
- **NSEvent global monitors** (require Accessibility) — for Escape-to-cancel and push-to-talk key-up detection
- Accessibility state detection: checks `AXIsProcessTrusted()`, detects stale TCC entries after app updates, shows orange warning banners
- Shortcut is fully customizable and persisted

### 10. Drag and Drop
- Drop files onto the menu bar status item icon
- Drop files into the popover window
- Images are classified as image type; other files as file/folder type

### 11. Auto-Copy and Auto-Paste
- After dictation ends, optionally auto-copy the composed prompt to clipboard
- Then optionally simulate Cmd+V to paste into the currently-focused app
- Requires Accessibility permission for paste simulation
- Shows a "Copied!" flash banner on success

### 12. Edge Cases and Polish
- **Clear during recording**: advances a trim offset so the voice note starts fresh from that point
- **Copy during recording**: snapshots the live partial transcription with current ref markers into the prompt
- **Pinnable popover**: toggles between transient (auto-close on click-outside) and persistent
- **Option-click the settings gear** → shows power icon → click to quit
- **Demo mode** (`RELAY_DEMO=1` env var): populates fake stack data, title tap cycles scenarios
- **Auto-updates** via Sparkle 2 framework

---

## Technical Constraints
- macOS 15+ only, arm64
- Swift 6 strict concurrency: all UI/state is `@MainActor`; speech engines are `Sendable`
- `LSUIElement = true` (no Dock icon)
- App must be built as a `.app` bundle with `Info.plist` and codesigning for mic/accessibility TCC permissions to work
- WhisperKit and FluidAudio are conditionally imported with `#if canImport()`

## Architecture Summary
- **AppState** (`@MainActor ObservableObject`): central coordinator owning all managers and the context stack
- **ContextStack**: observable array of `ClipboardItem` structs (max 20)
- **ClipboardMonitor**: timer-based pasteboard polling service
- **VoiceManager**: manages speech engine lifecycle, recording state, audio levels
- **SpeechEngine** protocol: abstraction over Native/WhisperKit/FluidAudio implementations
- **HotkeyManager**: Carbon + NSEvent hotkey registration and Accessibility detection
- **PromptComposer**: pure function composing stack items into formatted output
- **ContentClassifier**: pure function classifying text into content types
- **TranscriptEnhancer**: pure function for filler word removal and formatting
- **MenuBarIconBuilder**: SVG-based icon generation with animated dot overlays

## User Flow Summary
1. User launches app → appears in menu bar only
2. User copies code/text/images as they work → items appear in the context stack
3. User presses hotkey → recording starts, waveform animates
4. User speaks about what they want, copying more items mid-dictation → ref markers appear inline
5. User presses hotkey again (or releases in push-to-talk mode) → transcription finalizes
6. User clicks "Copy Prompt" (or auto-copy fires) → structured prompt is on the clipboard
7. User pastes into their LLM of choice
