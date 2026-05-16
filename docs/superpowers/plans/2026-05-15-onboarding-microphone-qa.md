# Onboarding Microphone QA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix and test GroqTalk first-run onboarding so completing the wizard keeps the menu bar app alive, and microphone permission/setup behavior is covered by deterministic and opt-in live QA.

**Architecture:** Keep regular CI deterministic by using UI-testing launch flags and injected app state for onboarding and microphone-permission UI flows. Put real microphone capture behind a separate opt-in local command because it depends on macOS TCC state, hardware, and the signed installed app. Preserve the normal menu bar app lifecycle: closing onboarding should close only the onboarding window, not terminate GroqTalk.

**Tech Stack:** Swift, SwiftUI, AppKit lifecycle hooks, AVFoundation microphone authorization, XCUITest, Makefile local QA targets.

---

## File Map

- Modify `GroqTalk/GroqTalkApp.swift`
  - Add/verify AppKit lifecycle behavior so closing onboarding does not terminate the app.
  - Keep microphone permission request logic centralized.
  - Keep diagnostics useful but remove temporary noisy trust polling logs before PR unless still needed behind a debug-only narrow log.
- Modify `GroqTalk/OnboardingView.swift`
  - Ensure microphone step can trigger permission checking/requesting.
  - Ensure completion is only enabled when setup is ready.
  - Ensure completion calls only the onboarding completion closure.
- Modify `GroqTalk/MenuBarView.swift`
  - Ensure unknown microphone state offers `Check`; denied/restricted state offers `Open Settings`; ready state offers no action.
- Modify `GroqTalk/UITestingController.swift`
  - Add launch flags/seeds for deterministic onboarding and microphone flows.
  - Provide UI-test-only microphone check callback that flips state without invoking real TCC.
- Modify `GroqTalkUITests/GroqTalkUITests.swift`
  - Add deterministic onboarding completion/liveness tests.
  - Add deterministic microphone setup tests.
- Modify `Makefile`
  - Add focused deterministic test target if helpful.
  - Add opt-in real microphone smoke target.
- Create `scripts/run-live-microphone-qa.sh`
  - Launch installed signed app, run opt-in microphone smoke, skip cleanly if prerequisites are missing.
- Create `docs/microphone-qa.md`
  - Document deterministic tests, live microphone smoke, and manual reset/retry steps.

---

## Task 1: Preserve App Liveness After Onboarding Completion

**Files:**
- Modify `GroqTalk/GroqTalkApp.swift`
- Test `GroqTalkUITests/GroqTalkUITests.swift`

- [ ] **Step 1: Write the failing XCUITest**

Add a test that launches onboarding in UI-test mode, marks setup ready, completes onboarding, and verifies the app process/menu surface remains available.

```swift
func testOnboardingCompletionKeepsMenuBarAppRunning() {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = [
        "--ui-testing",
        "--reset-defaults",
        "--show-onboarding",
        "--seed-setup-ready"
    ]
    app.launch()

    XCTAssertTrue(app.windows["Welcome to GroqTalk"].waitForExistence(timeout: 5), app.debugDescription)

    while app.buttons["Next"].exists {
        app.buttons["Next"].click()
    }

    XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 2))
    app.buttons["Get Started"].click()

    XCTAssertFalse(app.windows["Welcome to GroqTalk"].waitForExistence(timeout: 2))
    XCTAssertEqual(app.state, .runningForeground)
    XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -scheme GroqTalk -configuration Debug -destination 'platform=macOS' -only-testing:GroqTalkUITests/GroqTalkUITests/testOnboardingCompletionKeepsMenuBarAppRunning
```

Expected before fix: FAIL because completing onboarding closes the last visible window and the app exits or no menu/control surface remains.

- [ ] **Step 3: Implement minimal lifecycle fix**

Add this to `AppDelegate` in `GroqTalk/GroqTalkApp.swift`:

```swift
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
}
```

If needed, update onboarding completion to explicitly leave the app active:

```swift
private func completeOnboarding() {
    hasCompletedOnboarding = true
    onboardingWindow?.close()
    onboardingWindow = nil
    NSApp.setActivationPolicy(.accessory)
}
```

Use the existing completion closure in `showOnboarding()` rather than introducing a second lifecycle path.

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test ...testOnboardingCompletionKeepsMenuBarAppRunning` command.

Expected: PASS.

---

## Task 2: Deterministic Microphone Permission UI Tests

**Files:**
- Modify `GroqTalk/OnboardingView.swift`
- Modify `GroqTalk/MenuBarView.swift`
- Modify `GroqTalk/UITestingController.swift`
- Test `GroqTalkUITests/GroqTalkUITests.swift`

- [ ] **Step 1: Add deterministic launch seeds**

In `UITestingController.configureUITestingIfNeeded()`, add seeds:

```swift
if args.contains("--seed-setup-ready") {
    appState.updateAccessibilityState(isTrusted: true)
    appState.updateMicrophoneState(isReady: true)
    appState.apiKeyState = .ready
}

if args.contains("--seed-microphone-unknown") {
    appState.updateAccessibilityState(isTrusted: true)
    appState.microphoneState = .unknown
    appState.apiKeyState = .ready
}

if args.contains("--seed-microphone-denied") {
    appState.updateAccessibilityState(isTrusted: true)
    appState.updateMicrophoneState(isReady: false, message: "Allow microphone access")
    appState.apiKeyState = .ready
}
```

- [ ] **Step 2: Write failing UI tests for microphone states**

Add:

```swift
func testMicrophoneUnknownShowsCheckAction() {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = [
        "--ui-testing",
        "--reset-defaults",
        "--seed-microphone-unknown"
    ]
    app.launch()

    XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Microphone"].exists)
    XCTAssertTrue(app.staticTexts["Not checked"].exists)
    XCTAssertTrue(app.buttons["Check"].exists)
}

func testMicrophoneDeniedShowsOpenSettingsAction() {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = [
        "--ui-testing",
        "--reset-defaults",
        "--seed-microphone-denied"
    ]
    app.launch()

    XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Microphone"].exists)
    XCTAssertTrue(app.staticTexts["Allow microphone access"].exists)
    XCTAssertTrue(app.buttons["Open Settings"].exists)
}

func testMicrophoneCheckMarksPermissionReadyInUITestMode() {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = [
        "--ui-testing",
        "--reset-defaults",
        "--seed-microphone-unknown"
    ]
    app.launch()

    XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
    app.buttons["Check"].click()
    XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 2))
}
```

- [ ] **Step 3: Run tests to verify failure**

Run:

```bash
xcodebuild test -scheme GroqTalk -configuration Debug -destination 'platform=macOS' \
  -only-testing:GroqTalkUITests/GroqTalkUITests/testMicrophoneUnknownShowsCheckAction \
  -only-testing:GroqTalkUITests/GroqTalkUITests/testMicrophoneDeniedShowsOpenSettingsAction \
  -only-testing:GroqTalkUITests/GroqTalkUITests/testMicrophoneCheckMarksPermissionReadyInUITestMode
```

Expected before implementation: at least one test fails because microphone actions are not fully provider/state-aware.

- [ ] **Step 4: Implement microphone action wiring**

Use `MenuBarView` state-derived actions:

```swift
private var microphoneActionTitle: String? {
    switch appState.microphoneState {
    case .ready: nil
    case .unknown: "Check"
    case .needsAction: "Open Settings"
    }
}

private var microphoneAction: (() -> Void)? {
    switch appState.microphoneState {
    case .ready: nil
    case .unknown: onCheckMicrophone
    case .needsAction: onOpenMicrophone
    }
}
```

Wire `onCheckMicrophone` from `GroqTalkApp` to `AppDelegate.checkMicrophonePermission()`, and from `UITestingController` to a deterministic state update:

```swift
onCheckMicrophone: { [weak self] in
    self?.appState.updateMicrophoneState(isReady: true)
}
```

- [ ] **Step 5: Run tests to verify pass**

Run the same focused `xcodebuild test` command.

Expected: PASS.

---

## Task 3: Onboarding Microphone Flow Coverage

**Files:**
- Modify `GroqTalk/OnboardingView.swift`
- Modify `GroqTalk/GroqTalkApp.swift`
- Modify `GroqTalk/UITestingController.swift`
- Test `GroqTalkUITests/GroqTalkUITests.swift`

- [ ] **Step 1: Write failing onboarding microphone tests**

Add:

```swift
func testOnboardingMicrophoneStepCanCheckPermission() {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = [
        "--ui-testing",
        "--reset-defaults",
        "--show-onboarding",
        "--seed-microphone-unknown"
    ]
    app.launch()

    XCTAssertTrue(app.windows["Welcome to GroqTalk"].waitForExistence(timeout: 5), app.debugDescription)
    app.buttons["Next"].click()
    app.buttons["Next"].click()

    XCTAssertTrue(app.staticTexts["Microphone Access"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Checking status"].exists || app.staticTexts["Checking..."].exists)
    XCTAssertTrue(app.buttons["Check Microphone Access"].exists)

    app.buttons["Check Microphone Access"].click()
    XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 2))
}
```

- [ ] **Step 2: Run test to verify failure**

Run:

```bash
xcodebuild test -scheme GroqTalk -configuration Debug -destination 'platform=macOS' -only-testing:GroqTalkUITests/GroqTalkUITests/testOnboardingMicrophoneStepCanCheckPermission
```

Expected before implementation: FAIL because onboarding does not expose or wire a microphone check action.

- [ ] **Step 3: Implement onboarding microphone check**

Update `OnboardingView`:

```swift
struct OnboardingView: View {
    @Bindable var appState: AppState
    var onCheckMicrophone: (() -> Void)?
    var onComplete: () -> Void
}
```

In the microphone step:

```swift
if appState.microphoneState == .unknown {
    Button("Check Microphone Access") {
        onCheckMicrophone?()
    }
    .font(.caption)
    .accessibilityIdentifier("onboarding.checkMicrophoneButton")
}
```

Also trigger once on entering the step:

```swift
.onChange(of: currentStep) { _, step in
    if step == 2 {
        onCheckMicrophone?()
    }
}
```

Wire `showOnboarding()`:

```swift
let onboardingView = OnboardingView(
    appState: appState,
    onCheckMicrophone: { [weak self] in self?.checkMicrophonePermission() }
) { [weak self] in
    self?.hasCompletedOnboarding = true
    self?.onboardingWindow?.close()
    self?.onboardingWindow = nil
}
```

- [ ] **Step 4: Run onboarding microphone test**

Run the focused test again.

Expected: PASS.

---

## Task 4: Opt-In Real Microphone Smoke

**Files:**
- Create `scripts/run-live-microphone-qa.sh`
- Modify `Makefile`
- Create `docs/microphone-qa.md`

- [ ] **Step 1: Create live script**

Create `scripts/run-live-microphone-qa.sh`:

```bash
#!/bin/bash
set -euo pipefail

if [ "${RUN_LIVE_MICROPHONE_TESTS:-}" != "1" ]; then
  echo "skip: set RUN_LIVE_MICROPHONE_TESTS=1 to run live microphone QA"
  exit 0
fi

make run

echo "Live microphone QA prerequisites:"
echo "- /Applications/GroqTalk.app is running"
echo "- Microphone permission must be granted to GroqTalk"
echo "- A working input device must be selected"

xcodebuild test \
  -scheme GroqTalk \
  -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:GroqTalkUITests/GroqTalkUITests/testLiveMicrophoneSmoke
```

- [ ] **Step 2: Add Makefile target**

Add:

```make
test-microphone-live:
	RUN_LIVE_MICROPHONE_TESTS=1 scripts/run-live-microphone-qa.sh
```

Add `test-microphone-live` to `.PHONY`.

- [ ] **Step 3: Add opt-in XCUITest**

Add:

```swift
func testLiveMicrophoneSmoke() {
    let env = ProcessInfo.processInfo.environment
    guard env["RUN_LIVE_MICROPHONE_TESTS"] == "1" else {
        throw XCTSkip("Set RUN_LIVE_MICROPHONE_TESTS=1 to run live microphone QA.")
    }

    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-defaults", "--seed-setup-ready"]
    app.launch()

    XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.buttons["Start recording"].exists)
    app.buttons["Start recording"].click()
    sleep(2)
    XCTAssertTrue(app.buttons["Stop recording"].exists)
    app.buttons["Stop recording"].click()
    XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 5) || app.staticTexts["Ready"].waitForExistence(timeout: 5))
}
```

If the existing UI-test harness cannot safely exercise the real `AudioRecorder` because it uses `--ui-testing`, split this into a script-level app launch plus a smaller debug-only automation hook. Keep the target opt-in and skip by default.

- [ ] **Step 4: Document live QA**

Create `docs/microphone-qa.md`:

```markdown
# Microphone QA

Regular CI does not require microphone permission or hardware.

Run deterministic setup tests:

```bash
make test-ui
```

Run live microphone smoke locally:

```bash
RUN_LIVE_MICROPHONE_TESTS=1 make test-microphone-live
```

If macOS permission state is stale:

```bash
tccutil reset Microphone com.neonwatty.GroqTalk
make run
```

Then allow GroqTalk in System Settings > Privacy & Security > Microphone.
```

---

## Acceptance Criteria

- `make test` passes.
- `make test-ui` passes.
- `make test-provider-qa` passes.
- `make build-warnings-as-errors` passes.
- `git diff --check` passes.
- Completing onboarding closes only the onboarding window; GroqTalk remains running as a menu bar app.
- XCUITest proves onboarding completion does not terminate the app.
- XCUITest proves unknown microphone state shows a `Check` action.
- XCUITest proves denied microphone state shows `Open Settings`.
- XCUITest proves microphone `Check` can mark the state ready in deterministic UI-test mode.
- XCUITest proves onboarding microphone step can trigger/check microphone readiness.
- Live microphone QA is opt-in and skips cleanly unless explicitly requested.
- Live microphone QA records evidence of:
  - app path used
  - signing identity
  - microphone permission status
  - recording start/stop result
  - non-empty captured audio file or clear reason it could not be captured
- No regular CI job requires real microphone hardware or macOS TCC prompts.

---

## Current Evidence To Preserve

- Accessibility issue was fixed by running `/Applications/GroqTalk.app` with the Developer ID identity.
- App log confirmed Accessibility success:

```text
AccessibilityTrust: context=setup.refresh trusted=true bundlePath=/Applications/GroqTalk.app
```

- App log confirmed microphone permission prompt success:

```text
MicrophonePermission: authorizationStatus=0
MicrophonePermission: requestAccess granted=true
MicrophonePermission: checked ready=true
```

---

## Stop Rule

Stop when deterministic tests prove onboarding/microphone state behavior, manual app launch proves onboarding completion leaves GroqTalk running, and the opt-in live microphone target is documented and either passes on this machine or skips/fails with a precise prerequisite message.
