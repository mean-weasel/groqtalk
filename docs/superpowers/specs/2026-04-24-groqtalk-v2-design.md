# GroqTalk v2 — UX, Performance & Flexibility Improvements

**Date:** 2026-04-24
**Status:** Draft
**Builds on:** `docs/superpowers/specs/2026-04-21-groqtalk-design.md`

## Overview

Five improvements to the existing GroqTalk macOS menu bar app: audio format choice for faster uploads, enhanced menu bar feedback, a transcription safety net, error recovery with retry, and configurable hotkeys. All changes stay within the existing single-process, zero-dependency architecture.

## 1. Audio Format Picker

### Problem

AudioRecorder captures in the hardware-native format (typically 48kHz stereo float32), producing WAV files ~12x larger than what Whisper expects (16kHz mono 16-bit PCM). This means slower uploads and a practical recording ceiling of ~1 minute before hitting Groq's 25MB file limit.

### Design

Add an "Audio Format" picker to the menu bar dropdown (same style as the existing Whisper Model picker) with three options:

- **WAV (lossless)** — 16kHz mono 16-bit PCM. Lossless quality, largest files (~256 KB/s). Good for short clips where quality matters most.
- **M4A (smaller)** — AAC-compressed, 16kHz mono. ~8-10x smaller than WAV. Default choice.
- **MP3 (smallest)** — MP3-compressed, 16kHz mono. ~10x smaller than WAV. Maximum compatibility.

All three formats include 16kHz mono downsampling in the recording pipeline, which is currently missing.

### Implementation approach

**Downsampling (all formats):** Modify `AudioRecorder` to downsample from the hardware format to 16kHz mono using `AVAudioConverter` before buffering. This replaces the current approach of capturing in hardware-native format.

**WAV:** Write downsampled PCM buffers to an `AVAudioFile` as currently done (but now at 16kHz mono instead of hardware-native format).

**M4A/AAC:** Use `AVAudioConverter` to encode the 16kHz mono PCM buffers to AAC, then write via `AVAudioFile` with AAC settings. Native to Apple frameworks — no dependencies.

**MP3:** Use `AudioToolbox`'s `AudioConverter` API with `kAudioFormatMPEGLayer3`. This is a lower-level Apple API than `AVAudioConverter` but still ships with macOS — no third-party dependencies.

### State

- `UserDefaults` key: `"audioFormat"` — values: `"wav"`, `"m4a"`, `"mp3"`
- Default: `"m4a"`
- `AppState` gets a new `selectedAudioFormat` computed property (same pattern as `selectedModel`)

### API compatibility

Groq's Whisper API accepts: flac, mp3, mp4, mpeg, mpga, m4a, ogg, wav, webm. All three chosen formats are supported. The `TranscriptionService` multipart body must update the filename extension and `Content-Type` header to match the selected format.

## 2. Enhanced Menu Bar Feedback

### Problem

The only visual indicator of app state is the menu bar icon, which changes SF Symbol but has no color, no animation, and no timing information. Users can't tell how long they've been recording or whether the app is actively transcribing without opening the dropdown.

### Design

Enhance the `MenuBarExtra` label to show richer state feedback:

**Recording state:**
- Menu bar icon: `mic.circle.fill` (current) with red tint via SF Symbol rendering mode
- Menu bar text label: elapsed time counter shown next to the icon (e.g., `"0:05"`, `"0:12"`)
- Timer: `Timer.publish` firing every second, updating `AppState.recordingDuration`

**Transcribing state:**
- Menu bar icon: cycle between 2-3 SF Symbol frames on a timer to simulate animation (e.g., `ellipsis.circle`, `ellipsis.circle.fill`, alternating). `MenuBarExtra` doesn't support SwiftUI animation, so frame-swapping via a `Timer` is the standard workaround.

**Error state:**
- Menu bar icon: `exclamationmark.triangle.fill`
- Error persists in the menu bar until the user's next action (recording or menu interaction), rather than auto-clearing after 3 seconds. The 3-second auto-clear in `showError()` is replaced with a `clearError()` call at the start of the next recording cycle.

**Idle state:**
- Menu bar icon: `waveform` (current, unchanged)

### State additions

- `AppState.recordingStartTime: Date?` — set when recording starts, cleared on stop
- `AppState.recordingDuration: TimeInterval` — updated by timer, drives the menu bar text
- `AppState.transcribingIconFrame: Int` — cycles 0/1/2 on timer for icon animation

## 3. Transcription Safety Net

### Problem

If the simulated `Cmd+V` paste fails (wrong app focus, slow Electron app, etc.), the transcription is lost. The 100ms sleep before clipboard restore is a fixed guess that doesn't work for all apps. There's no way to recover a past transcription.

### Design

Two complementary features:

### 3a. Transcription History

A rolling list of the last 20 transcriptions, accessible as a submenu ("Recent Transcriptions") in the menu bar dropdown.

Each entry shows:
- Truncated text preview (first ~40 characters)
- Relative timestamp ("2m ago", "1h ago")
- For failed transcriptions: error badge with reason

Clicking an entry copies the full text to the clipboard.

**Storage:** An array of `TranscriptionRecord` structs persisted to a JSON file in `~/Library/Application Support/GroqTalk/history.json`. Each record contains:

```swift
struct TranscriptionRecord: Codable, Identifiable {
    let id: UUID
    let text: String?           // nil for failed transcriptions
    let error: String?          // nil for successful transcriptions
    let timestamp: Date
    let audioFileURL: URL?      // preserved on failure for retry, nil after cleanup
}
```

The history file is capped at 20 entries. When a new entry is added and the count exceeds 20, the oldest entry is removed and its associated audio file (if any) is deleted.

**New file:** `TranscriptionHistory.swift` — manages the history array, handles persistence, provides the submenu data.

### 3b. "Keep on Clipboard" Toggle

A toggle in the menu bar dropdown: "Keep Transcription on Clipboard". When enabled, `TextInserter` skips the clipboard restore step after pasting, leaving the transcription on the clipboard as a safety net.

**State:** `UserDefaults` key `"keepOnClipboard"`, default `false`. `AppState` gets a `keepOnClipboard` computed property.

**Impact on TextInserter:** `insert(text:keepOnClipboard:)` gains a boolean parameter. When `true`, it still saves the old clipboard (in case we want it later), pastes, but does not restore.

## 4. Error Recovery

### Problem

Errors auto-clear after 3 seconds with no way to see what happened. If transcription fails, the audio recording is deleted and the user must re-dictate.

### Design

Two mechanisms, building on the transcription history from section 3:

### 4a. Errors in History

Failed transcriptions appear in the history submenu with a red error badge and the failure reason. This gives the user a persistent record of what went wrong.

### 4b. Retry

When a transcription fails:
1. The temp audio file is **not** deleted (currently it's always deleted via `FileManager.default.removeItem`)
2. The audio file URL is stored in the `TranscriptionRecord`
3. A "Retry Last" menu item appears in the dropdown (only visible when the most recent transcription failed and an audio file is available)
4. Clicking "Retry Last" re-sends the preserved audio file to `TranscriptionService.transcribe()`
5. On successful retry: the history entry is updated with the transcription text, the audio file is deleted
6. On retry failure: the error in the history entry is updated

**Audio file cleanup:** Preserved audio files are deleted when:
- The retry succeeds
- The history entry ages out (pushed past the 20-entry cap)
- The app quits (optional — could also preserve across restarts for maximum safety)

### Impact on AppDelegate

The `onRecordingStopped` handler changes: on transcription failure, it no longer calls `FileManager.default.removeItem(at: url)`. Instead it passes the URL to `TranscriptionHistory` as part of the failed record.

## 5. Hotkey Configuration

### Problem

The trigger key (Right Command) is hardcoded. Some users may prefer a different key. The hold-to-record mode doesn't work well for longer dictations where holding a key for 30+ seconds is uncomfortable.

### Design

### 5a. Key Picker

A "Hotkey" submenu in the menu bar dropdown with:

**Presets:**
- Right Command (default)
- Right Option
- Globe/Fn

**Custom:**
- "Press to set..." — when selected, the app enters a listening mode. The next modifier key press is captured and stored as the custom hotkey. A brief "Press a key..." status appears in the menu bar. Timeout after 5 seconds if no key is pressed.

**State:** `UserDefaults` key `"hotkeyKeyCode"` storing the CGEvent flag bit or virtual key code, and `"hotkeyLabel"` storing the display name. Default: Right Command.

### 5b. Recording Mode

A toggle within the Hotkey submenu:

- **Hold to record** (default) — current behavior. Hold key to record, release to transcribe.
- **Toggle mode** — tap key to start recording, tap again to stop and transcribe. Better for longer dictations.

**State:** `UserDefaults` key `"recordingMode"` — values: `"hold"`, `"toggle"`. Default: `"hold"`.

### Impact on HotkeyMonitor

`HotkeyMonitor` currently uses a CGEvent tap filtering for the Right Command device flag bit (`0x10`). Changes needed:

- The monitored flag bit (or key code) becomes configurable via a property
- For preset modifier keys (Right Cmd, Right Option), continue using `flagsChanged` events with device-specific flag bits
- For Globe/Fn, switch to IOKit HID approach (already implemented in the git history, commit `cab3f0b`)
- Toggle mode changes the state machine: key-down starts recording, next key-down (not key-up) stops recording
- The debounce logic remains for both modes

**New file considerations:** The Globe/Fn preset requires a different interception mechanism (IOKit HID) than modifier keys (CGEvent). This could be handled as two internal strategies within `HotkeyMonitor`, selected based on the configured key.

## Menu Bar Dropdown Layout

Updated dropdown structure with all new items:

```
┌─────────────────────────────┐
│ Ready                (status)│
├─────────────────────────────┤
│ ☑ Sound Effects             │
│ ☐ Keep on Clipboard         │
├─────────────────────────────┤
│ Whisper Model          ▶    │
│   Large V3 Turbo (fast)     │
│   Large V3 (accurate)       │
│ Audio Format           ▶    │
│   M4A (smaller) ✓           │
│   WAV (lossless)            │
│   MP3 (smallest)            │
│ Hotkey                 ▶    │
│   Right Command ✓           │
│   Right Option              │
│   Globe / Fn                │
│   Press to set...           │
│   ──────────                │
│   ☑ Hold to record          │
│   ☐ Toggle mode             │
├─────────────────────────────┤
│ Recent Transcriptions  ▶    │
│   "Hello world this i..."   │
│   "Meeting notes for..."    │
│   ⚠ API error (429)        │
│ ⟳ Retry Last                │
├─────────────────────────────┤
│ Change API Key...           │
├─────────────────────────────┤
│ Quit                        │
└─────────────────────────────┘
```

## New Files

| File | Purpose |
|------|---------|
| `TranscriptionHistory.swift` | History array management, JSON persistence, cleanup |

## Modified Files

| File | Changes |
|------|---------|
| `AppState.swift` | New properties: `selectedAudioFormat`, `keepOnClipboard`, `recordingStartTime`, `recordingDuration`, `transcribingIconFrame`, `recordingMode`, `hotkeyKeyCode`, `hotkeyLabel`. Error behavior change (no auto-clear). |
| `AudioRecorder.swift` | 16kHz mono downsampling pipeline. Multi-format encoding (WAV/M4A/MP3). Accept format parameter. |
| `MenuBarView.swift` | New pickers, toggles, submenus for format/hotkey/history. Recording timer display. |
| `HotkeyMonitor.swift` | Configurable key, toggle mode state machine, Globe/Fn IOKit strategy. |
| `TextInserter.swift` | `keepOnClipboard` parameter to skip clipboard restore. |
| `TranscriptionService.swift` | Dynamic Content-Type and filename extension based on audio format. |
| `GroqTalkApp.swift` | Wire new components, recording timer, transcribing icon animation, retry handler. |

## Out of Scope

- Streaming/partial transcription results
- Language picker
- Multiple simultaneous recordings
- Cloud sync of transcription history
- Custom sound effects
