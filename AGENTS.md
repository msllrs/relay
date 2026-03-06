# Agents Guide for Relay

## Project
macOS menu bar app (SwiftUI) that captures clipboard items and voice notes into structured LLM prompts.

## Build & Run
```bash
# Build only (bare binary, no mic permissions)
swift build

# Build .app bundle with proper entitlements (required for mic/speech)
./build-app.sh
open .build/Relay.app
```

**Important:** Always use `build-app.sh` when testing voice features. The bare `swift build` binary lacks the Info.plist and codesigning needed for microphone access on macOS. Without the `.app` bundle, `AVAudioEngine` silently receives zeroed audio buffers.

## Architecture

### Core
- **AppState** (`Services/AppState.swift`) — `@MainActor` ObservableObject, owns all state including `VoiceManager`, `ClipboardMonitor`, `HotkeyManager`
- **ContextStack** (`Models/ContextStack.swift`) — ordered list of `ClipboardItem`, max 20
- **ClipboardMonitor** (`Services/ClipboardMonitor.swift`) — polls `NSPasteboard` every 0.5s, deduplicates against last item
- **PromptComposer** (`Services/PromptComposer.swift`) — generates XML-tagged prompt from task + items
- **HotkeyManager** (`Services/HotkeyManager.swift`) — customizable global keyboard shortcut via `NSEvent` monitors

### Voice
- **SpeechEngine** (`Voice/SpeechEngine.swift`) — protocol: `startStreaming`, `stopAndTranscribe`, `cancel`, `downloadModel`
- **NativeSpeechEngine** — `SFSpeechRecognizer` + `AVAudioEngine` (no download needed)
- **WhisperKitEngine** — WhisperKit batch transcription (guarded with `#if canImport`)
- **FluidAudioEngine** — FluidAudio/Parakeet streaming transcription (guarded with `#if canImport`)
- **VoiceManager** (`Voice/VoiceManager.swift`) — manages active engine, recording state, mic volume save/restore

### Audio Gotchas
- `AVAudioEngine` must be created **fresh each recording session** — a persistent engine caches stale audio graphs and delivers zeros
- Always pass `nil` as tap format to `installTap(onBus:bufferSize:format:)` — let Core Audio negotiate; explicit formats break with AirPods and device switching
- `setVoiceProcessingEnabled(true)` activates Bluetooth HFP for AirPods but outputs multi-channel (3-7ch) which `SFSpeechRecognizer` can't handle — don't use it with Native engine
- `SystemAudioHelper` (`Services/SystemAudioHelper.swift`) wraps CoreAudio for input volume control

### Views
- **MenuBarPopover** — main UI, owns settings section with shortcut recorder
- **VoiceNoteButton** — record/stop with pulse animation
- **ClipboardItemRow** — shows item with remove-on-hover X button
- **ContextStackView** — list of clipboard items with drag-to-reorder
- **EmptyStateView** — shows dynamic keyboard shortcut

## Concurrency
- All UI/state types are `@MainActor`
- `SpeechEngine` protocol is `Sendable`, implementations are `@unchecked Sendable`
- `ClipboardMonitor` uses `MainActor.assumeIsolated` in Timer callback
- `HotkeyManager` uses `nonisolated(unsafe)` for NSEvent monitor references
- Swift 6 strict concurrency is enabled

## Settings (UserDefaults keys)
- `clearStackOnCopy` — clear context stack after copying prompt
- `alwaysOnMonitoring` — start monitoring on launch
- `maxMicOnRecord` — set input volume to 1.0 during recording (default: true)
- `hotkeyStartsDictation` — hotkey starts recording instead of just toggling monitoring
- `selectedSpeechEngine` — native/whisperKit/parakeet
- `customKeyboardShortcut` — JSON-encoded `KeyboardShortcutModel`

## Tests
- Test files in `RelayTests/` use XCTest — require Xcode to run (only CLI tools on this machine)
