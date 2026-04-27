# SkyLight Background Paste — Design Spec

**Date:** 2026-04-27
**Status:** Approved
**Problem:** Async paste requires activating the target window to deliver CMD+V, causing visible focus flicker and unreliable behavior across app types.
**Solution:** Use macOS SkyLight private framework APIs to route keyboard events to a background process without raising its window.

## Background

GroqTalk records audio and transcribes it via the Groq Whisper API. Transcription is async — the user may switch apps while it runs. The current async paste implementation (`insertAtTarget`) activates the target window, pastes via CMD+V, and returns focus. This causes two problems:

1. **Unreliable window targeting** — activation + AXRaise behaves differently across native, browser, and Electron apps.
2. **Jarring visual flicker** — the window shuffle is visible even when it works correctly.

## Research Findings

Every shipping voice-to-text app (Wispr Flow, Superwhisper, MacWhisper) uses the same clipboard + CMD+V approach with the same limitations. No production app currently solves background async paste.

However, the **Cua project** (MIT licensed, github.com/trycua/cua) and **yabai** window manager (github.com/koekeishiya/yabai) have proven that macOS SkyLight private framework APIs can decouple input routing from window raising. This enables sending keyboard events to a background process invisibly.

### Key APIs

Three private functions in `/System/Library/PrivateFrameworks/SkyLight.framework`:

#### 1. `SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes)`

Posts a 248-byte synthetic event record into a process's Carbon event queue. By setting specific bytes, you can mark a window as focused (for input routing) or defocused — without raising it.

Buffer layout (verified on macOS 15 and 26 by Cua, stable across yabai's 6+ year history):
- `bytes[0x04] = 0xF8` — opcode high
- `bytes[0x08] = 0x0D` — opcode low
- `bytes[0x3C..0x3F]` — little-endian CGWindowID
- `bytes[0x8A]` — `0x01` = focus, `0x02` = defocus
- All other bytes zero

Recipe (two calls):
1. Call with `0x02` targeting current frontmost PSN → defocuses it
2. Wait ~40ms (empirical, from yabai)
3. Call with `0x01` targeting the target PSN → focuses it for input

Deliberately skip `_SLPSSetFrontProcessWithOptions` — that would raise the window.

#### 2. `_SLPSGetFrontProcess(ProcessSerialNumber *psn)`

Captures the current frontmost process's PSN. Used to know who to defocus in step 1 above.

#### 3. `GetProcessForPID(pid_t, ProcessSerialNumber *)`

Converts a PID to a ProcessSerialNumber. Deprecated but still resolves via dlsym.

### Compatibility

| macOS Version | Status | Evidence |
|---|---|---|
| Sonoma 14 | Works | Cua specifies macOS 14+ as minimum |
| Sequoia 15 | Works | Cua verified "against live captures on macOS 15" |
| Tahoe 26 | Works | Cua verified 2026-04-20; yabai users report non-SA features work |

### Permissions

- **Accessibility:** Required (already granted for GroqTalk)
- **SIP disabled:** Not required (only needed for yabai's scripting addition)
- **Hardened Runtime:** Compatible (system frameworks load without library validation bypass)
- **Notarization:** Compatible (many notarized apps use private APIs)
- **Special entitlements:** None

### Reference Implementations

- Cua FocusWithoutRaise.swift: https://github.com/trycua/cua/blob/main/libs/cua-driver/Sources/CuaDriverCore/Input/FocusWithoutRaise.swift
- Cua SkyLightEventPost.swift: https://github.com/trycua/cua/blob/main/libs/cua-driver/Sources/CuaDriverCore/Input/SkyLightEventPost.swift
- Cua KeyboardInput.swift: https://github.com/trycua/cua/blob/main/libs/cua-driver/Sources/CuaDriverCore/Input/KeyboardInput.swift
- Cua AXEnablementAssertion.swift: https://github.com/trycua/cua/blob/main/libs/cua-driver/Sources/CuaDriverCore/Focus/AXEnablementAssertion.swift
- Cua FocusGuard.swift: https://github.com/trycua/cua/blob/main/libs/cua-driver/Sources/CuaDriverCore/Focus/FocusGuard.swift
- Cua blog — Inside macOS Window Internals: https://github.com/trycua/cua/blob/main/blog/inside-macos-window-internals.md
- Cua Known Limits: https://github.com/trycua/cua/blob/main/docs/content/docs/cua-driver/reference/limits.mdx
- yabai window_manager.c (focus_window_without_raise at line 1293): https://github.com/koekeishiya/yabai/blob/master/src/window_manager.c
- yabai extern.h (SkyLight declarations): https://github.com/koekeishiya/yabai/blob/master/src/misc/extern.h
- HN discussion: https://news.ycombinator.com/item?id=47891384
- Exploring macOS private frameworks: https://www.jviotti.com/2023/11/20/exploring-macos-private-frameworks.html

## Architecture

### Three-Tier Paste Strategy

```
Transcription completes
        |
        v
+-- Tier 1: SkyLight Background Paste --+
|  FocusWithoutRaise -> CMD+V via PID    |
|  (invisible, no window raise)          |
+-------------------+--------------------+
                    | SkyLight unavailable or failed?
                    v
+-- Tier 2: Window Choreography ---------+
|  activate() -> CMD+V -> reactivate()   |
|  (existing insertAtTarget behavior)    |
+-------------------+--------------------+
                    | Target app terminated?
                    v
+-- Tier 3: Clipboard + Notification ----+
|  Text on clipboard, user notification  |
+----------------------------------------+
```

### New Files

#### `SkyLightBridge.swift` (~150 lines)

Encapsulates all `dlopen`/`dlsym` work. The rest of the codebase never touches raw function pointers.

```swift
enum SkyLightBridge {
    static var isAvailable: Bool

    static func focusWithoutRaise(targetPid: pid_t, targetWindowID: CGWindowID) -> Bool

    static func postKeyEvent(to pid: pid_t, event: CGEvent) -> Bool

    static func windowID(from element: AXUIElement) -> CGWindowID?

    static func currentFocus() -> (pid: pid_t, windowID: CGWindowID)?
}
```

**Internal details:**
- Single `dlopen` of `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight` with `RTLD_LAZY`
- Three `dlsym` lookups cached as `lazy static let` typed function pointers:
  - `SLPSPostEventRecordTo` as `@convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32`
  - `_SLPSGetFrontProcess` as `@convention(c) (UnsafeMutableRawPointer) -> Int32`
  - `GetProcessForPID` as `@convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32`
- One additional `dlsym` for `_AXUIElementGetWindow` (from ApplicationServices, not SkyLight)
- `isAvailable` returns `true` only if all four resolve
- `focusWithoutRaise` builds the 248-byte buffer, calls defocus then focus with 40ms gap
- `postKeyEvent` initially uses public `CGEvent.postToPid` (may upgrade to `SLEventPostToPid` + auth envelope if Chrome testing requires it)
- All methods return `false` on any resolution failure — never crash

#### `BackgroundPaste.swift` (~60 lines)

Orchestrates the Tier 1 paste sequence.

```swift
struct BackgroundPaste {
    static func attempt(
        text: String,
        target: PasteTarget,
        keepOnClipboard: Bool
    ) async -> Bool
}
```

**Sequence:**
1. Guard `SkyLightBridge.isAvailable` and `target.windowID != nil`
2. Capture current focus via `SkyLightBridge.currentFocus()`
3. Save clipboard contents (unless `keepOnClipboard`)
4. Write text to `NSPasteboard.general`
5. `SkyLightBridge.focusWithoutRaise(target.pid, target.windowID!)`
6. `await Task.sleep(.milliseconds(50))` — AppKit state settle
7. Build CMD+V `CGEvent`, post via `CGEvent.postToPid(target.pid)`
8. `await Task.sleep(.milliseconds(100))` — paste lands
9. `SkyLightBridge.focusWithoutRaise(currentPid, currentWindowID)` — restore input routing
10. Restore clipboard
11. Return `true`

On any failure at steps 1-5, return `false` (caller falls through to Tier 2).

### Modified Files

#### `PasteTarget.swift`

Add `windowID: CGWindowID?` property:

```swift
struct PasteTarget {
    let windowElement: AXUIElement?
    let windowID: CGWindowID?      // NEW — needed for SkyLight 248-byte buffer
    let pid: pid_t
    let appName: String
}
```

In `captureCurrentTarget()`, after obtaining the window AXUIElement:

```swift
let windowID: CGWindowID? = window.flatMap { SkyLightBridge.windowID(from: $0) }
```

#### `TextInserter.swift`

Add one new method — the primary async paste entry point:

```swift
func insertAsync(text: String, target: PasteTarget, keepOnClipboard: Bool) async {
    // Tier 1
    if await BackgroundPaste.attempt(text: text, target: target, keepOnClipboard: keepOnClipboard) {
        return
    }
    // Tier 2 (existing)
    await insertAtTarget(text: text, target: target, keepOnClipboard: keepOnClipboard)
}
```

#### `GroqTalkApp.swift`

Change the `PasteQueue` handler from `insertAtTarget` to `insertAsync`. One line.

## Scope Control — What We're NOT Doing

- **No mouse event posting** — Cua's mouse path has significantly more complexity (window-local coordinates, session-ID fields, primer clicks). We only need CMD+V.
- **No Chrome AX tree management** — We don't read or write AX elements at paste time, just send a keystroke.
- **No Space migration** — If the target window is on another Space, Tier 2 fallback handles it.
- **No Tier 3 notification UI** — Clipboard fallback works; notification is polish for later.
- **No `SLEventPostToPid` + auth envelope initially** — Test `CGEvent.postToPid` first after focus-without-raise. Add the auth envelope only if Chrome/Electron testing shows it's needed.

## Testing Strategy

### Unit Tests

- `SkyLightBridge.isAvailable` returns Bool without crash
- `PasteTarget.captureCurrentTarget()` populates `windowID` when a window is available
- `PasteTarget.windowID` is `nil` when no window element exists
- `BackgroundPaste.attempt()` returns `false` when `SkyLightBridge.isAvailable` is false
- `BackgroundPaste.attempt()` returns `false` when `target.windowID` is nil
- `insertAsync()` falls through to `insertAtTarget` when `BackgroundPaste` returns false

### Integration Test

Extend `tests/test_async_paste.swift`:

1. Open two TextEdit windows (A and B)
2. Focus window A, capture PasteTarget (including windowID)
3. Switch focus to window B
4. Call `BackgroundPaste.attempt()` with test text
5. Verify: text landed in window A (read via AX)
6. Verify: window B is still `NSWorkspace.shared.frontmostApplication` (focus never visibly changed)
7. Verify: clipboard restored

Key assertion: step 6 distinguishes SkyLight paste from the existing Tier 2 test.

### Manual Testing Matrix

| App Type | Test App | Verify |
|---|---|---|
| Native Cocoa | TextEdit, Notes | Text lands in background window, no flicker |
| Browser | Chrome, Safari | CMD+V pastes into background tab |
| Electron | VS Code, Slack | CMD+V pastes into background editor/chat |
| Terminal | Terminal.app, iTerm2 | CMD+V pastes into background shell |

If Chrome/Electron fail with `CGEvent.postToPid` after focus-without-raise, that's when we add `SLEventPostToPid` + auth envelope.

### Fallback Verification

- Force `BackgroundPaste.attempt` to return `false` → verify Tier 2 behavior unchanged
- Terminate target app before paste → verify clipboard-only fallback (Tier 3)

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Apple removes SkyLight symbols | Low (stable 6+ years) | Tier 1 stops | `dlsym` returns nil, `isAvailable` = false, auto fallback to Tier 2 |
| 248-byte buffer layout changes | Low (stable across versions) | Focus-without-raise fails silently | Returns false, falls to Tier 2. Can detect by checking isActive post-call. |
| CMD+V via `postToPid` rejected by Chrome | Medium | Chrome/Electron need Tier 2 | Add `SLEventPostToPid` + auth envelope (~100 lines from Cua). Planned follow-up. |
| Race: user switches apps during 150ms paste window | Low (window is short) | Focus restore targets wrong app | Capture current app atomically at paste start. SkyLight path is less disruptive since focus never visibly moves. |
| `_AXUIElementGetWindow` unavailable | Very low (used widely) | Can't get windowID | windowID = nil, Tier 1 unavailable, falls to Tier 2 |
