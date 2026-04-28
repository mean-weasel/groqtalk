# Async Paste ("Paste-and-Run") Prototype Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prototype the "paste-and-run" feature — capture the target window at record time, run transcription asynchronously, then flash-paste into the original target and return focus to wherever the user is now. Uses mock transcription (fixed delay + hardcoded string) to isolate the window management mechanics.

**Architecture:** A new `PasteTarget` value type captures the AX window element and app PID at record time. A new `PasteQueue` actor serializes pending paste jobs so overlapping transcriptions don't fight over focus. `TextInserter` gains a new method for targeted insertion (activate target → paste → reactivate caller's app). The feature is gated behind an `asyncPasteEnabled` toggle in AppState. When disabled, behavior is identical to today.

**Tech Stack:** Swift, macOS Accessibility API (AXUIElement), AppKit (NSRunningApplication), CGEvent

---

### Task 1: Add `asyncPasteEnabled` toggle to AppState

**Files:**
- Modify: `GroqTalk/AppState.swift`
- Modify: `GroqTalkTests/AppStateTests.swift`

- [ ] **Step 1: Write the failing test**

In `GroqTalkTests/AppStateTests.swift`, add at the bottom of the class:

```swift
// MARK: - Async paste

func testDefaultAsyncPasteDisabled() {
    let state = AppState()
    XCTAssertFalse(state.asyncPasteEnabled)
}

func testSetAsyncPaste() {
    let state = AppState()
    state.asyncPasteEnabled = true
    XCTAssertTrue(state.asyncPasteEnabled)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GroqTalk -destination 'platform=macOS' -only-testing:GroqTalkTests/AppStateTests/testDefaultAsyncPasteDisabled 2>&1 | tail -5`
Expected: Build error — `asyncPasteEnabled` does not exist on `AppState`.

- [ ] **Step 3: Write minimal implementation**

In `GroqTalk/AppState.swift`, add the UserDefaults-backed property after `keepOnClipboard`:

```swift
var asyncPasteEnabled: Bool {
    get { UserDefaults.standard.bool(forKey: "asyncPasteEnabled") }
    set { UserDefaults.standard.set(newValue, forKey: "asyncPasteEnabled") }
}
```

Add `"asyncPasteEnabled": false` to the `register(defaults:)` dictionary in `init()`.

- [ ] **Step 4: Add teardown cleanup**

In `GroqTalkTests/AppStateTests.swift`, add to the existing `tearDown()`:

```swift
UserDefaults.standard.removeObject(forKey: "asyncPasteEnabled")
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GroqTalk -destination 'platform=macOS' -only-testing:GroqTalkTests/AppStateTests 2>&1 | tail -5`
Expected: All AppState tests PASS.

- [ ] **Step 6: Commit**

```bash
git add GroqTalk/AppState.swift GroqTalkTests/AppStateTests.swift
git commit -m "feat: add asyncPasteEnabled toggle to AppState"
```

---

### Task 2: Create `PasteTarget` — AX window capture

**Files:**
- Create: `GroqTalk/PasteTarget.swift`
- Create: `GroqTalkTests/PasteTargetTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GroqTalkTests/PasteTargetTests.swift`:

```swift
import XCTest
@testable import GroqTalk

final class PasteTargetTests: XCTestCase {
    func testCaptureReturnsNilWithoutAccessibility() {
        // In the test runner, AX permissions may not be granted.
        // PasteTarget.captureCurrentTarget() should return nil gracefully
        // rather than crashing when AX queries fail.
        let target = PasteTarget.captureCurrentTarget()
        // Either nil (no AX) or a valid target — must not crash
        if let target {
            XCTAssertGreaterThan(target.pid, 0)
        }
    }

    func testManualInitStoresValues() {
        let target = PasteTarget(windowElement: nil, pid: 12345, appName: "TestApp")
        XCTAssertEqual(target.pid, 12345)
        XCTAssertEqual(target.appName, "TestApp")
        XCTAssertNil(target.windowElement)
    }

    func testTargetWithZeroPidIsInvalid() {
        let target = PasteTarget(windowElement: nil, pid: 0, appName: "")
        XCTAssertFalse(target.isValid)
    }

    func testTargetWithPositivePidIsValid() {
        let target = PasteTarget(windowElement: nil, pid: 999, appName: "App")
        XCTAssertTrue(target.isValid)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GroqTalk -destination 'platform=macOS' -only-testing:GroqTalkTests/PasteTargetTests 2>&1 | tail -5`
Expected: Build error — `PasteTarget` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `GroqTalk/PasteTarget.swift`:

```swift
import ApplicationServices
import AppKit

/// Captures the focused window and app at a point in time so that
/// text can be pasted there later, even if the user has moved on.
struct PasteTarget {
    /// The AX element for the specific window (may be nil if capture failed).
    let windowElement: AXUIElement?
    /// PID of the target app.
    let pid: pid_t
    /// Display name, for diagnostics / logging.
    let appName: String

    var isValid: Bool { pid > 0 }

    /// Snapshot the currently focused window and app.
    /// Returns nil if AX queries fail entirely (no permissions, no focused app).
    static func captureCurrentTarget() -> PasteTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName ?? "Unknown"

        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef)

        let windowElement: AXUIElement?
        if result == .success, let ref = windowRef {
            // swiftlint:disable:next force_cast
            windowElement = (ref as! AXUIElement)
        } else {
            windowElement = nil
        }

        return PasteTarget(windowElement: windowElement, pid: pid, appName: appName)
    }
}
```

- [ ] **Step 4: Add file to Xcode project**

The new file must be in both the GroqTalk app target and accessible to tests. If using Xcode's automatic file discovery this happens automatically. Otherwise add `PasteTarget.swift` to the GroqTalk target and `PasteTargetTests.swift` to the GroqTalkTests target.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme GroqTalk -destination 'platform=macOS' -only-testing:GroqTalkTests/PasteTargetTests 2>&1 | tail -5`
Expected: All PasteTarget tests PASS.

- [ ] **Step 6: Commit**

```bash
git add GroqTalk/PasteTarget.swift GroqTalkTests/PasteTargetTests.swift
git commit -m "feat: add PasteTarget for AX window capture at record time"
```

---

### Task 3: Create `PasteQueue` — serialized async paste executor

**Files:**
- Create: `GroqTalk/PasteQueue.swift`
- Create: `GroqTalkTests/PasteQueueTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GroqTalkTests/PasteQueueTests.swift`:

```swift
import XCTest
@testable import GroqTalk

final class PasteQueueTests: XCTestCase {
    func testEnqueueAndDrain() async {
        var pastedTexts: [String] = []

        let queue = PasteQueue { text, _, _ in
            pastedTexts.append(text)
        }

        await queue.enqueue(text: "hello", target: PasteTarget(windowElement: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        await queue.enqueue(text: "world", target: PasteTarget(windowElement: nil, pid: 2, appName: "B"), keepOnClipboard: false)

        XCTAssertEqual(pastedTexts, ["hello", "world"])
    }

    func testSerializesExecution() async {
        var order: [Int] = []
        let expectation = XCTestExpectation(description: "all pastes complete")
        expectation.expectedFulfillmentCount = 3

        let queue = PasteQueue { text, _, _ in
            let index = Int(text)!
            // Simulate variable paste durations
            try? await Task.sleep(for: .milliseconds(50 - index * 10))
            order.append(index)
            expectation.fulfill()
        }

        // Enqueue concurrently — they must still execute in FIFO order
        async let a: Void = queue.enqueue(text: "1", target: PasteTarget(windowElement: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        async let b: Void = queue.enqueue(text: "2", target: PasteTarget(windowElement: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        async let c: Void = queue.enqueue(text: "3", target: PasteTarget(windowElement: nil, pid: 1, appName: "A"), keepOnClipboard: false)
        _ = await (a, b, c)

        await fulfillment(of: [expectation], timeout: 5)
        XCTAssertEqual(order, [1, 2, 3])
    }

    func testInvalidTargetSkips() async {
        var called = false

        let queue = PasteQueue { _, _, _ in
            called = true
        }

        let invalidTarget = PasteTarget(windowElement: nil, pid: 0, appName: "")
        await queue.enqueue(text: "skip me", target: invalidTarget, keepOnClipboard: false)

        XCTAssertFalse(called)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme GroqTalk -destination 'platform=macOS' -only-testing:GroqTalkTests/PasteQueueTests 2>&1 | tail -5`
Expected: Build error — `PasteQueue` does not exist.

- [ ] **Step 3: Write minimal implementation**

Create `GroqTalk/PasteQueue.swift`:

```swift
import Foundation

/// Serializes paste operations so concurrent transcription completions
/// don't fight over window focus. Jobs execute in FIFO order.
actor PasteQueue {
    typealias PasteHandler = @Sendable (String, PasteTarget, Bool) async -> Void

    private let handler: PasteHandler

    init(handler: @escaping PasteHandler) {
        self.handler = handler
    }

    func enqueue(text: String, target: PasteTarget, keepOnClipboard: Bool) async {
        guard target.isValid else { return }
        await handler(text, target, keepOnClipboard)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme GroqTalk -destination 'platform=macOS' -only-testing:GroqTalkTests/PasteQueueTests 2>&1 | tail -5`
Expected: All PasteQueue tests PASS.

- [ ] **Step 5: Commit**

```bash
git add GroqTalk/PasteQueue.swift GroqTalkTests/PasteQueueTests.swift
git commit -m "feat: add PasteQueue actor for serialized async paste execution"
```

---

### Task 4: Add targeted paste method to `TextInserter`

**Files:**
- Modify: `GroqTalk/TextInserter.swift`

- [ ] **Step 1: Add `insertAtTarget` method**

In `GroqTalk/TextInserter.swift`, add this method after the existing `insert(text:keepOnClipboard:)`:

```swift
/// Paste text into a previously captured target window, then return focus
/// to wherever the user is currently working.
///
/// Flow: snapshot current app → activate target → paste → reactivate current app.
func insertAtTarget(text: String, target: PasteTarget, keepOnClipboard: Bool) async {
    // 1. Remember where the user is right now
    let currentApp = NSWorkspace.shared.frontmostApplication

    // 2. Activate the target app and raise the specific window
    guard let targetApp = NSRunningApplication(processIdentifier: target.pid),
          targetApp.isTerminated == false else {
        // Target app is gone — fall back to clipboard only
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return
    }

    targetApp.activate()

    if let window = target.windowElement {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    // 3. Wait for activation to settle
    try? await Task.sleep(for: .milliseconds(100))

    // 4. Paste using the existing mechanism
    await insert(text: text, keepOnClipboard: keepOnClipboard)

    // 5. Wait for paste to land
    try? await Task.sleep(for: .milliseconds(100))

    // 6. Return focus to where the user was
    currentApp?.activate()
}
```

Add `import ApplicationServices` at the top of `TextInserter.swift` if not already present.

- [ ] **Step 2: Verify the app builds**

Run: `xcodebuild build -scheme GroqTalk -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add GroqTalk/TextInserter.swift
git commit -m "feat: add insertAtTarget for async paste with focus-switch-return"
```

---

### Task 5: Wire async paste into AppDelegate

**Files:**
- Modify: `GroqTalk/GroqTalkApp.swift`

This task modifies the `onRecordingStopped` callback and adds the PasteQueue. When `asyncPasteEnabled` is true, the target is captured at recording start and paste goes through the queue. When false, behavior is unchanged.

- [ ] **Step 1: Add properties to AppDelegate**

In `GroqTalk/GroqTalkApp.swift`, add to the AppDelegate class properties (after `private let soundPlayer`):

```swift
private var pendingTarget: PasteTarget?
private var pasteQueue: PasteQueue!
```

- [ ] **Step 2: Initialize PasteQueue in `applicationDidFinishLaunching`**

In `applicationDidFinishLaunching`, add before the `wireHotkeyMonitor()` call:

```swift
pasteQueue = PasteQueue { [weak self] text, target, keepOnClipboard in
    guard let self else { return }
    await self.textInserter.insertAtTarget(text: text, target: target, keepOnClipboard: keepOnClipboard)
}
```

- [ ] **Step 3: Capture target on recording start**

In the `wireHotkeyMonitor()` method, inside `onRecordingStarted`, add after `self.soundPlayer.playStartSound()`:

```swift
if self.appState.asyncPasteEnabled {
    self.pendingTarget = PasteTarget.captureCurrentTarget()
}
```

- [ ] **Step 4: Branch paste logic on recording stop**

In the `wireHotkeyMonitor()` method, inside `onRecordingStopped`, replace the current paste-and-cleanup block (lines 179-186):

```swift
self.stopTranscribingAnimation()
self.history.addSuccess(text: text)
self.appState.setStatus(.idle)

if self.appState.asyncPasteEnabled, let target = self.pendingTarget {
    self.pendingTarget = nil
    await self.pasteQueue.enqueue(
        text: text, target: target,
        keepOnClipboard: self.appState.keepOnClipboard
    )
} else {
    await self.textInserter.insert(
        text: text,
        keepOnClipboard: self.appState.keepOnClipboard
    )
}
try? FileManager.default.removeItem(at: url)
```

Note: status is set to `.idle` *before* the paste in async mode, freeing the user to start a new transcription immediately.

- [ ] **Step 5: Clear pending target on cancel**

In the `onRecordingCancelled` callback, add after `self.appState.setStatus(.idle)`:

```swift
self.pendingTarget = nil
```

- [ ] **Step 6: Verify the app builds**

Run: `xcodebuild build -scheme GroqTalk -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add GroqTalk/GroqTalkApp.swift
git commit -m "feat: wire async paste queue into AppDelegate with toggle gate"
```

---

### Task 6: Add toggle to MenuBarView

**Files:**
- Modify: `GroqTalk/MenuBarView.swift`

- [ ] **Step 1: Add the toggle**

In `GroqTalk/MenuBarView.swift`, add after the `Toggle("Keep on Clipboard", ...)` line:

```swift
Toggle("Async Paste (experimental)", isOn: $appState.asyncPasteEnabled)
```

- [ ] **Step 2: Verify the app builds**

Run: `xcodebuild build -scheme GroqTalk -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add GroqTalk/MenuBarView.swift
git commit -m "feat: add async paste toggle to menu bar settings"
```

---

### Task 7: Add mock transcription for prototype testing

**Files:**
- Modify: `GroqTalk/GroqTalkApp.swift`

This task adds a compile-time flag `MOCK_TRANSCRIPTION` that replaces the real API call with a 2-second delay and hardcoded text. This lets you test the full window-capture → async-wait → focus-switch-paste-return cycle without needing audio or an API key.

- [ ] **Step 1: Add mock branch in onRecordingStopped**

In `GroqTalk/GroqTalkApp.swift`, inside the `onRecordingStopped` callback, replace the `do { let text = try await self.transcriptionService.transcribe(...)` block with a conditional compilation block:

```swift
do {
    let text: String
    #if MOCK_TRANSCRIPTION
    try await Task.sleep(for: .seconds(2))
    text = "Mock transcription at \(Date().formatted(date: .omitted, time: .standard))"
    #else
    text = try await self.transcriptionService.transcribe(
        audioFileURL: url,
        apiKey: apiKey,
        model: self.appState.selectedModel,
        format: self.appState.selectedAudioFormat,
        language: self.appState.selectedLanguage
    )
    #endif
```

The rest of the `do` block (success handling) and the `catch` block stay unchanged.

- [ ] **Step 2: When mock is active, skip the API key check**

Wrap the API key guard in a conditional:

```swift
#if !MOCK_TRANSCRIPTION
guard let apiKey = KeychainHelper.readApiKey() else {
    self.stopTranscribingAnimation()
    self.history.addFailure(error: "No API key", audioFileURL: url)
    self.appState.showError("No API key — set one via the menu")
    return
}
#endif
```

- [ ] **Step 3: Verify the app builds without the flag**

Run: `xcodebuild build -scheme GroqTalk -destination 'platform=macOS' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (normal path, no mock).

- [ ] **Step 4: Verify the app builds WITH the flag**

Run: `xcodebuild build -scheme GroqTalk -destination 'platform=macOS' OTHER_SWIFT_FLAGS='-DMOCK_TRANSCRIPTION' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (mock path).

- [ ] **Step 5: Commit**

```bash
git add GroqTalk/GroqTalkApp.swift
git commit -m "feat: add MOCK_TRANSCRIPTION compile flag for async paste prototyping"
```

---

### Task 8: Manual integration test

This task is manual — no code changes. Build with mock transcription enabled, run the app, and verify the async paste cycle works.

- [ ] **Step 1: Build with mock flag**

Run: `xcodebuild build -scheme GroqTalk -destination 'platform=macOS' OTHER_SWIFT_FLAGS='-DMOCK_TRANSCRIPTION' 2>&1 | tail -5`

- [ ] **Step 2: Launch the app**

Open the built `.app` bundle from the DerivedData build directory, or run from Xcode with the `MOCK_TRANSCRIPTION` Swift flag added to the scheme's build settings.

- [ ] **Step 3: Test scenario — single async paste**

1. Open TextEdit, click into a document
2. Enable "Async Paste (experimental)" in the GroqTalk menu bar
3. Press and hold the hotkey (dictate anything — audio is ignored with mock)
4. Release the hotkey
5. **Immediately switch to a different app** (e.g., Finder, Safari)
6. After ~2 seconds, observe: TextEdit should flash to front, text appears, then your current app comes back

Expected: "Mock transcription at HH:MM:SS" appears in TextEdit. Focus returns to wherever you were.

- [ ] **Step 4: Test scenario — two overlapping transcriptions**

1. Open two TextEdit windows (or TextEdit + Notes)
2. Click into window A, start and stop a transcription
3. Quickly click into window B, start and stop a second transcription
4. Switch to a third app (e.g., Safari)
5. Wait for both to complete

Expected: Both pastes land in their respective target windows. Pastes happen one at a time (serialized). Focus returns to Safari after the last paste.

- [ ] **Step 5: Test scenario — async paste disabled (regression)**

1. Disable "Async Paste (experimental)" in the menu
2. Click into a text field, start and stop a transcription
3. Do NOT switch apps

Expected: Text pastes into the current app immediately (2s delay due to mock). Behavior identical to the original flow.

- [ ] **Step 6: Document results**

Note which apps/windows worked or failed. Pay attention to:
- Does `AXRaise` bring the correct window forward for multi-window apps?
- Does focus return reliably?
- How visible/distracting is the flash?
