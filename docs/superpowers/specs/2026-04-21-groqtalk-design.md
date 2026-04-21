# GroqTalk — macOS Push-to-Talk Speech-to-Text via Groq API

**Date:** 2026-04-21
**Status:** Draft

## Overview

GroqTalk is a native Swift/SwiftUI macOS menubar app that provides system-wide push-to-talk speech-to-text. The user holds the `Fn` (Globe) key to record, releases to transcribe via the Groq Whisper API, and the transcribed text is pasted into whatever app has focus. It replaces Wispr Flow with a self-hosted alternative using the Groq API.

## Architecture

Single-process menubar-only app (`LSUIElement = true`). No Dock icon, no main window. Zero third-party dependencies — all functionality uses Apple frameworks (`IOKit`, `AVFAudio`, `Security`, `CoreGraphics`) and `URLSession`.

### Approach rationale

A single-process architecture was chosen over XPC services or CLI companions because the PTT feedback loop (hold → release → paste) is latency-sensitive and the app is a personal utility, not a distributed product. Swift concurrency (`async/await`) keeps the UI responsive while the API call runs on a background task.

## Components

### 1. App Lifecycle & Menubar UI (`GroqTalkApp.swift`, `AppState.swift`)

The app uses `MenuBarExtra` for its UI. A single `@Observable` `AppState` class drives all state transitions.

**App states:** `.idle`, `.recording`, `.transcribing`, `.error(String)`

**Menubar icon states:**
- Idle — `mic.fill` SF Symbol, standard appearance
- Recording — `mic.circle.fill` with red/accent color
- Transcribing — spinner or pulsing icon

**Menubar dropdown:**
- Status line ("Ready" / "Recording..." / "Transcribing...")
- Toggle: "Sound effects" (on/off, backed by `UserDefaults`)
- Whisper model picker: `whisper-large-v3-turbo` (default) / `whisper-large-v3`
- "Change API Key..." (reopens key entry window)
- "Quit"

### 2. First-Launch API Key Setup (`GroqTalkApp.swift`, `KeychainHelper.swift`)

On first launch, if no API key is found in Keychain, a small `Window` appears with:
- `SecureField` for the API key
- "Save" button
- Link to the Groq API key page

The key is stored via `Security.framework` (`SecItemAdd` / `SecItemCopyMatching`). Wrapped in a `KeychainHelper` utility struct.

The "Change API Key..." menu item reopens this window to allow updating the key.

### 3. Fn Key Monitoring (`HotkeyMonitor.swift`)

Uses IOKit HID to intercept the `Fn` (Globe) key at the hardware level, since `Fn` cannot be reliably intercepted via standard `CGEvent` taps.

**Implementation:**
- Open an `IOHIDManager`, register for keyboard-type HID devices
- Matching dictionary filters for `kHIDUsage_GD_Keyboard`
- Input value callback checks for `kHIDUsage_KeyboardFn` (usage `0x03`)
- Key down fires `onRecordingStarted`, key up fires `onRecordingStopped`

**Edge cases:**
- Ignore `Fn` events where other keys are pressed during the hold (i.e., `Fn` used as a modifier combo like `Fn+F1`)
- Debounce: ignore presses shorter than 200ms to prevent accidental triggers

**Permissions:** Requires Input Monitoring permission (System Settings > Privacy & Security). macOS prompts automatically on first HID manager access.

**Interface:** Callback-based — `onRecordingStarted: () -> Void`, `onRecordingStopped: () -> Void`. Isolates IOKit complexity from the rest of the app.

### 4. Audio Recording (`AudioRecorder.swift`)

Uses `AVAudioEngine` with an input node tap to capture microphone audio.

**Format:** 16kHz sample rate, mono, 16-bit PCM (WAV). This matches what Whisper expects and avoids server-side resampling. At this format, Groq's 25MB file limit allows ~13 minutes of audio — more than enough for PTT clips.

**Recording flow:**
- `startRecording()`: install a tap on `inputNode`, collect PCM buffers into an array
- `stopRecording() async -> URL`: remove tap, concatenate buffers, write to a temporary WAV file via `AVAudioFile`, return the file URL

**Future optimization:** WAV is used for MVP simplicity. If network latency from file size becomes noticeable, add an M4A/AAC encoding step to compress ~8x before upload.

**Permissions:** Requires Microphone permission. `NSMicrophoneUsageDescription` in `Info.plist`.

### 5. Sound Cues (`SoundPlayer.swift`)

Plays a short chirp on recording start and stop (walkie-talkie style feedback).

**Implementation:**
- `AVAudioPlayer` with bundled `.caf` or `.aiff` sound files
- Gated behind a `UserDefaults` boolean ("Sound effects" toggle in menubar)
- Two methods: `playStartSound()`, `playStopSound()`

### 6. Groq API Integration (`TranscriptionService.swift`)

**Endpoint:** `POST https://api.groq.com/openai/v1/audio/transcriptions`

**Request:** Multipart form data with:
- `file`: WAV audio data
- `model`: selected Whisper model from UserDefaults
- `response_format`: `text` (plain string, avoids JSON parsing overhead)
- `Authorization: Bearer <api_key>` header

**Implementation:** `URLSession.upload` with a manually constructed multipart body. No third-party HTTP libraries.

**Interface:** `func transcribe(audioFileURL: URL) async throws -> String`

**Error handling:**
- Network failure / timeout: set `AppState` to `.error("Transcription failed")`, auto-clear after 3 seconds
- 401 (invalid API key): prompt user to re-enter key
- 413 (file too large): log and show error (unlikely with PTT clips)
- No retry logic for MVP — user re-triggers by holding `Fn` again

**Latency:** Groq is optimized for speed. Expected ~300-500ms turnaround for a 5-10 second clip.

### 7. Text Insertion (`TextInserter.swift`)

Paste-with-clipboard-restore approach:

1. Save current `NSPasteboard.general` contents (all types, not just string)
2. Write transcription string to clipboard
3. Simulate `Cmd+V` via `CGEvent` (keyDown + keyUp for `V` with `.maskCommand`)
4. Wait ~100ms for the paste to be consumed by the target app
5. Restore original clipboard contents

**Permissions:** Requires Accessibility permission for `CGEvent` posting. App checks `AXIsProcessTrusted()` on launch and prompts if not granted.

**Clipboard restore:** All `NSPasteboardItem` types are saved and restored, preserving rich content (RTF, images, etc.) the user had copied.

## Data Flow

A single PTT cycle:

```
User holds Fn
  -> HotkeyMonitor fires onRecordingStarted
    -> AppState -> .recording
    -> SoundPlayer plays start chirp
    -> AudioRecorder.startRecording()

User releases Fn
  -> HotkeyMonitor fires onRecordingStopped
    -> AudioRecorder.stopRecording() -> temp WAV URL
    -> SoundPlayer plays stop chirp
    -> AppState -> .transcribing
    -> TranscriptionService.transcribe(wav) -> String
    -> TextInserter.insert(text)
    -> AppState -> .idle
```

The PTT coordinator logic lives in `AppState` — it wires together the four components and drives state transitions.

## Project Structure

```
GroqTalk/
├── GroqTalkApp.swift          # App entry, MenuBarExtra, first-launch flow
├── HotkeyMonitor.swift        # IOKit HID Fn key listener
├── AudioRecorder.swift        # AVAudioEngine recording -> WAV file
├── TranscriptionService.swift # Groq API multipart POST
├── TextInserter.swift         # Clipboard save -> paste -> restore
├── KeychainHelper.swift       # SecItemAdd/SecItemCopyMatching wrapper
├── SoundPlayer.swift          # Start/stop chirp playback
├── AppState.swift             # Observable state: idle/recording/transcribing/error
├── Assets.xcassets/           # Menubar icons
├── Sounds/                    # start.caf, stop.caf
└── Info.plist                 # LSUIElement, NSMicrophoneUsageDescription
```

## Required macOS Permissions

1. **Input Monitoring** — for IOKit HID `Fn` key interception
2. **Microphone** — for `AVAudioEngine` audio capture
3. **Accessibility** — for `CGEvent` keyboard simulation (paste)

## MVP Scope

**In scope:**
- Menubar-only app with Fn push-to-talk
- Record audio, send to Groq Whisper, paste result into active app
- First-launch API key setup with Keychain storage
- Toggleable start/stop sound cues
- Switchable Whisper model (turbo vs full)
- Clipboard restore after paste

**Out of scope (future):**
- Toggle-mode recording (press to start, press to stop)
- Compressed audio format (M4A/AAC) before upload
- Floating indicator / HUD overlay
- Configurable hotkey
- Launch at login
- Multiple language support / language picker
- Streaming transcription (partial results while still recording)
