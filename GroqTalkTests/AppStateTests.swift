import XCTest
@testable import GroqTalk

@MainActor
final class AppStateTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "audioFormat")
        UserDefaults.standard.removeObject(forKey: "keepOnClipboard")
        UserDefaults.standard.removeObject(forKey: "recordingMode")
        UserDefaults.standard.removeObject(forKey: "hotkeyChoice")
        UserDefaults.standard.removeObject(forKey: "language")
        UserDefaults.standard.removeObject(forKey: "asyncPasteEnabled")
        UserDefaults.standard.removeObject(forKey: "showLiveFeedbackHUD")
        UserDefaults.standard.removeObject(forKey: "showFloatingStatus")
        UserDefaults.standard.removeObject(forKey: "mockTranscriptionEnabled")
        UserDefaults.standard.removeObject(forKey: "transcriptProcessingMode")
        UserDefaults.standard.removeObject(forKey: "transcriptCleanupModel")
    }

    func testInitialStatusIsIdle() {
        let state = AppState()
        XCTAssertEqual(state.status, .idle)
    }

    func testTransitionToRecording() {
        let state = AppState()
        state.setStatus(.recording)
        XCTAssertEqual(state.status, .recording)
    }

    func testTransitionToTranscribing() {
        let state = AppState()
        state.setStatus(.transcribing)
        XCTAssertEqual(state.status, .transcribing)
        XCTAssertEqual(state.transcriptionStage, .transcribingAudio)
    }

    func testShowErrorSetsErrorStatus() {
        let state = AppState()
        state.showError("something broke")
        XCTAssertEqual(state.status, .error("something broke"))
    }

    func testErrorPersistsUntilCleared() {
        let state = AppState()
        state.showError("persistent error")
        XCTAssertEqual(state.status, .error("persistent error"))
    }

    func testClearErrorResetsToIdle() {
        let state = AppState()
        state.showError("will be cleared")
        state.clearError()
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.transcriptionStage)
    }

    func testClearErrorNoOpWhenNotError() {
        let state = AppState()
        state.setStatus(.recording)
        state.clearError()
        XCTAssertEqual(state.status, .recording)
    }

    // MARK: - Setup health

    func testSetupHealthDefaultsUnknownAndDoesNotRequireAttention() {
        let state = AppState()

        XCTAssertEqual(state.accessibilityState, .unknown)
        XCTAssertEqual(state.microphoneState, .unknown)
        XCTAssertEqual(state.apiKeyState, .unknown)
        XCTAssertFalse(state.needsSetupAttention)
    }

    func testSetupHealthNeedsAttentionWhenPermissionNeedsAction() {
        let state = AppState()

        state.updateAccessibilityState(isTrusted: false)

        XCTAssertEqual(state.accessibilityState, .needsAction("Enable Accessibility"))
        XCTAssertTrue(state.needsSetupAttention)
        XCTAssertEqual(state.menuBarIcon, "exclamationmark.triangle.fill")
    }

    func testSetupHealthReadyClearsAttention() {
        let state = AppState()

        state.updateAccessibilityState(isTrusted: false)
        state.updateAccessibilityState(isTrusted: true)
        state.updateMicrophoneState(isReady: true)
        state.apiKeyState = .ready

        XCTAssertEqual(state.accessibilityState, .ready)
        XCTAssertFalse(state.needsSetupAttention)
        XCTAssertEqual(state.menuBarIcon, "waveform")
    }

    func testSetupCheckStateTransitions() {
        let state = AppState()

        XCTAssertEqual(state.setupCheckState, .idle)
        XCTAssertFalse(state.isSetupCheckRunning)

        state.startSetupCheck()
        XCTAssertEqual(state.setupCheckState, .running)
        XCTAssertTrue(state.isSetupCheckRunning)

        state.failSetupCheck("Allow microphone access")
        XCTAssertEqual(state.setupCheckState, .failed("Allow microphone access"))
        XCTAssertFalse(state.isSetupCheckRunning)

        state.startSetupCheck()
        state.completeSetupCheck()
        if case .passed = state.setupCheckState {
            XCTAssertFalse(state.isSetupCheckRunning)
        } else {
            XCTFail("Expected setup check to pass")
        }
    }

    func testReadySessionPresentationUsesHotkeyAndPasteMode() {
        let state = AppState()
        state.updateAccessibilityState(isTrusted: true)
        state.updateMicrophoneState(isReady: true)
        state.apiKeyState = .ready

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Ready")
        XCTAssertEqual(presentation.detail, "Right Command · Pastes into current app")
        XCTAssertEqual(presentation.systemImage, "waveform")
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertNil(presentation.primaryAction)
    }

    func testSetupSessionPresentationRoutesToFirstMissingItem() {
        let state = AppState()
        state.updateAccessibilityState(isTrusted: false)
        state.updateMicrophoneState(isReady: false)
        state.apiKeyState = .needsAction("Add Groq API key")

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Setup needed")
        XCTAssertEqual(presentation.detail, "Enable Accessibility before recording")
        XCTAssertEqual(presentation.primaryAction, .openAccessibility)
        XCTAssertEqual(presentation.tone, .warning)
    }

    func testRecordingSessionPresentationShowsTimerAndTarget() {
        let state = AppState()
        state.asyncPasteEnabled = true
        state.capturedTargetName = "Notes"
        state.recordingDuration = 7
        state.setStatus(.recording)

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Recording")
        XCTAssertEqual(presentation.timerText, "0:07")
        XCTAssertEqual(presentation.detail, "Target: Notes · Release Right Command to send")
        XCTAssertEqual(presentation.tone, .active)
    }

    func testTranscribingSessionPresentationShowsModel() {
        let state = AppState()
        state.selectedModel = "whisper-large-v3-turbo"
        state.transcriptionStage = .transcribingAudio
        state.setStatus(.transcribing)

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Transcribing")
        XCTAssertEqual(presentation.detail, "Groq · whisper-large-v3-turbo")
        XCTAssertEqual(presentation.tone, .progress)
    }

    func testCleaningSessionPresentationShowsCleanupModel() {
        let state = AppState()
        state.transcriptProcessingMode = .cleanUp
        state.transcriptCleanupModel = "llama-3.3-70b-versatile"
        state.transcriptionStage = .cleaningTranscript
        state.setStatus(.transcribing)

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Cleaning up")
        XCTAssertEqual(presentation.detail, "llama-3.3-70b-versatile · Clean up")
        XCTAssertEqual(presentation.systemImage, "sparkles")
        XCTAssertEqual(presentation.tone, .progress)
    }

    func testPastingSessionPresentationShowsTarget() {
        let state = AppState()
        state.capturedTargetName = "Notes"
        state.transcriptionStage = .pasting
        state.setStatus(.transcribing)

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Pasting")
        XCTAssertEqual(presentation.detail, "Target: Notes")
        XCTAssertEqual(presentation.systemImage, "arrow.down.doc")
    }

    func testIdleClearsTranscriptionStage() {
        let state = AppState()
        state.setStatus(.transcribing)
        XCTAssertEqual(state.transcriptionStage, .transcribingAudio)

        state.setStatus(.idle)

        XCTAssertNil(state.transcriptionStage)
    }

    func testSuccessSessionPresentationOffersPasteAgain() {
        let state = AppState()
        state.recordPaste(.currentApp)

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: false,
            hasLastSuccess: true
        )

        XCTAssertEqual(presentation.title, "Pasted into the current app")
        XCTAssertEqual(presentation.detail, "Clipboard restored")
        XCTAssertEqual(presentation.primaryAction, .pasteAgain)
        XCTAssertEqual(presentation.tone, .success)
    }

    func testErrorSessionPresentationRoutesRetryableFailure() {
        let state = AppState()
        state.showError("Request timed out")

        let presentation = state.sessionPresentation(
            hotkeyLabel: "Right Command",
            hasRetryableFailure: true,
            hasLastSuccess: false
        )

        XCTAssertEqual(presentation.title, "Request timed out")
        XCTAssertEqual(presentation.detail, "Audio saved · Retry transcription")
        XCTAssertEqual(presentation.primaryAction, .retry)
        XCTAssertEqual(presentation.tone, .warning)
    }

    // MARK: - Audio format

    func testDefaultAudioFormat() {
        let state = AppState()
        XCTAssertEqual(state.selectedAudioFormat, .m4a)
    }

    func testSetAudioFormat() {
        let state = AppState()
        state.selectedAudioFormat = .wav
        XCTAssertEqual(state.selectedAudioFormat, .wav)
    }

    func testInvalidAudioFormatStringDefaultsToM4A() {
        UserDefaults.standard.set("ogg", forKey: "audioFormat")
        let state = AppState()
        XCTAssertEqual(state.selectedAudioFormat, .m4a)
    }

    // MARK: - Keep on clipboard

    func testDefaultKeepOnClipboard() {
        let state = AppState()
        XCTAssertFalse(state.keepOnClipboard)
    }

    func testSetKeepOnClipboard() {
        let state = AppState()
        state.keepOnClipboard = true
        XCTAssertTrue(state.keepOnClipboard)
    }

    // MARK: - Floating status

    func testDefaultFloatingStatusDisabled() {
        let state = AppState()
        XCTAssertFalse(state.showFloatingStatus)
    }

    func testSetFloatingStatus() {
        let state = AppState()
        state.showFloatingStatus = true
        XCTAssertTrue(state.showFloatingStatus)
    }

    func testFloatingStatusHiddenWhenIdleWithoutTransientFeedback() {
        let state = AppState()
        state.showFloatingStatus = true
        XCTAssertFalse(state.shouldShowFloatingStatus)
    }

    func testFloatingStatusVisibleWhileRecordingWhenEnabled() {
        let state = AppState()
        state.showFloatingStatus = true
        state.setStatus(.recording)
        XCTAssertTrue(state.shouldShowFloatingStatus)
    }

    func testFloatingStatusVisibleWhileTranscribingWhenEnabled() {
        let state = AppState()
        state.showFloatingStatus = true
        state.setStatus(.transcribing)
        XCTAssertTrue(state.shouldShowFloatingStatus)
    }

    func testFloatingStatusVisibleForErrorWhenEnabled() {
        let state = AppState()
        state.showFloatingStatus = true
        state.showError("fail")
        XCTAssertTrue(state.shouldShowFloatingStatus)
    }

    func testFloatingStatusVisibleAfterPasteSuccessUntilExpired() {
        let state = AppState()
        state.showFloatingStatus = true
        state.recordPaste(.currentApp)

        XCTAssertEqual(state.transientResult, .pasted(.currentApp))
        XCTAssertTrue(state.shouldShowFloatingStatus)

        state.expireTransientSuccess()
        XCTAssertNil(state.transientResult)
        XCTAssertFalse(state.shouldShowFloatingStatus)
    }

    func testClipboardFallbackTransientPersistsAfterSuccessExpiry() {
        let state = AppState()
        state.showFloatingStatus = true
        state.recordPaste(.clipboardFallback)

        XCTAssertEqual(state.transientResult, .clipboardFallback)
        XCTAssertTrue(state.shouldShowFloatingStatus)

        state.expireTransientSuccess()
        XCTAssertEqual(state.transientResult, .clipboardFallback)
        XCTAssertTrue(state.shouldShowFloatingStatus)
    }

    func testFloatingStatusDisabledByPreference() {
        let state = AppState()
        state.showFloatingStatus = false
        state.setStatus(.recording)

        XCTAssertFalse(state.shouldShowFloatingStatus)
    }

    func testFloatingStatusDismissHidesError() {
        let state = AppState()
        state.showFloatingStatus = true
        state.showError("fail")

        state.hideFloatingStatus()

        XCTAssertFalse(state.shouldShowFloatingStatus)
    }

    func testEnablingFloatingStatusClearsDismissal() {
        let state = AppState()
        state.showFloatingStatus = true
        state.showError("fail")
        state.hideFloatingStatus()
        XCTAssertFalse(state.shouldShowFloatingStatus)

        state.showFloatingStatus = true
        XCTAssertTrue(state.shouldShowFloatingStatus)
    }

    // MARK: - Recording mode

    func testDefaultRecordingMode() {
        let state = AppState()
        XCTAssertEqual(state.recordingMode, .hold)
    }

    func testSetRecordingMode() {
        let state = AppState()
        state.recordingMode = .toggle
        XCTAssertEqual(state.recordingMode, .toggle)
    }

    func testInvalidRecordingModeStringDefaultsToHold() {
        UserDefaults.standard.set("invalid", forKey: "recordingMode")
        let state = AppState()
        XCTAssertEqual(state.recordingMode, .hold)
    }

    // MARK: - Hotkey choice

    func testDefaultHotkeyChoice() {
        let state = AppState()
        XCTAssertEqual(state.hotkeyChoice, .rightCommand)
    }

    func testSetHotkeyChoice() {
        let state = AppState()
        state.hotkeyChoice = .rightOption
        XCTAssertEqual(state.hotkeyChoice, .rightOption)
    }

    func testInvalidHotkeyChoiceStringDefaultsToRightCommand() {
        UserDefaults.standard.set("leftShift", forKey: "hotkeyChoice")
        let state = AppState()
        XCTAssertEqual(state.hotkeyChoice, .rightCommand)
    }

    // MARK: - Recording timer

    func testRecordingDurationStartsAtZero() {
        let state = AppState()
        XCTAssertEqual(state.recordingDuration, 0)
    }

    func testRecordingStartTimeNilWhenIdle() {
        let state = AppState()
        XCTAssertNil(state.recordingStartTime)
    }

    // MARK: - Formatted recording duration

    func testFormattedDurationZero() {
        let state = AppState()
        state.recordingDuration = 0
        XCTAssertEqual(state.formattedRecordingDuration, "0:00")
    }

    func testFormattedDurationSeconds() {
        let state = AppState()
        state.recordingDuration = 5
        XCTAssertEqual(state.formattedRecordingDuration, "0:05")
    }

    func testFormattedDurationMinutesAndSeconds() {
        let state = AppState()
        state.recordingDuration = 125
        XCTAssertEqual(state.formattedRecordingDuration, "2:05")
    }

    func testFormattedDurationFractionalTruncates() {
        let state = AppState()
        state.recordingDuration = 3.7
        XCTAssertEqual(state.formattedRecordingDuration, "0:03")
    }

    // MARK: - Status text

    func testStatusTextIdle() {
        let state = AppState()
        XCTAssertEqual(state.statusText, "Ready")
    }

    func testStatusTextRecording() {
        let state = AppState()
        state.setStatus(.recording)
        XCTAssertEqual(state.statusText, "Recording...")
    }

    func testStatusTextTranscribing() {
        let state = AppState()
        state.setStatus(.transcribing)
        XCTAssertEqual(state.statusText, "Transcribing...")
    }

    func testStatusTextError() {
        let state = AppState()
        state.showError("Network timeout")
        XCTAssertEqual(state.statusText, "Network timeout")
    }

    // MARK: - Menu bar icon

    func testMenuBarIconIdle() {
        let state = AppState()
        XCTAssertEqual(state.menuBarIcon, "waveform")
    }

    func testMenuBarIconPasteSuccess() {
        let state = AppState()
        state.recordPaste(.currentApp)
        XCTAssertEqual(state.menuBarIcon, "checkmark.circle.fill")
    }

    func testMenuBarIconClipboardFallback() {
        let state = AppState()
        state.recordPaste(.clipboardFallback)
        XCTAssertEqual(state.menuBarIcon, "clipboard")
    }

    func testMenuBarIconRecording() {
        let state = AppState()
        state.setStatus(.recording)
        XCTAssertEqual(state.menuBarIcon, "waveform.circle.fill")
    }

    func testMenuBarIconTranscribingCycles() {
        let state = AppState()
        state.setStatus(.transcribing)
        state.transcribingIconFrame = 0
        XCTAssertEqual(state.menuBarIcon, "ellipsis.circle")
        state.transcribingIconFrame = 1
        XCTAssertEqual(state.menuBarIcon, "ellipsis.circle.fill")
    }

    func testMenuBarIconError() {
        let state = AppState()
        state.showError("fail")
        XCTAssertEqual(state.menuBarIcon, "exclamationmark.triangle.fill")
    }

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

    func testRecordPasteUpdatesUserFeedback() {
        let state = AppState()

        state.recordPaste(.asyncBackground)

        XCTAssertEqual(state.lastPasteSummary, "Pasted into the original app")
        XCTAssertEqual(state.feedbackMessage, "Pasted into the original app")
        XCTAssertEqual(state.clipboardFeedback, "Clipboard restored")
        XCTAssertEqual(state.transientResult, .pasted(.asyncBackground))
    }

    func testRecordPasteClipboardFallbackFeedback() {
        let state = AppState()

        state.recordPaste(.clipboardFallback)

        XCTAssertEqual(state.lastPasteSummary, "Target unavailable; text copied to clipboard")
        XCTAssertEqual(state.clipboardFeedback, "Text is on the clipboard")
        XCTAssertEqual(state.transientResult, .clipboardFallback)
    }

    func testRecordTargetCaptureUpdatesFeedback() {
        let state = AppState()
        let target = PasteTarget(windowElement: nil, windowID: nil, pid: 42, appName: "TextEdit")

        state.recordTargetCapture(target)

        XCTAssertEqual(state.capturedTargetName, "TextEdit")
        XCTAssertEqual(state.feedbackMessage, "Target: TextEdit")
    }

    func testRecordMissingTargetWhenAsyncEnabled() {
        let state = AppState()
        state.asyncPasteEnabled = true

        state.recordTargetCapture(nil)

        XCTAssertNil(state.capturedTargetName)
        XCTAssertEqual(state.feedbackMessage, "Target unavailable")
    }

    #if DEBUG
    // MARK: - Mock transcription

    func testDefaultMockTranscriptionDisabled() {
        let state = AppState()
        XCTAssertFalse(state.mockTranscriptionEnabled)
    }

    func testSetMockTranscription() {
        let state = AppState()
        state.mockTranscriptionEnabled = true
        XCTAssertTrue(state.mockTranscriptionEnabled)
    }
    #endif

    // MARK: - Transcript processing

    func testDefaultTranscriptProcessingModeIsRaw() {
        let state = AppState()
        XCTAssertEqual(state.transcriptProcessingMode, .raw)
        XCTAssertEqual(state.transcriptCleanupModel, "llama-3.3-70b-versatile")
    }

    func testSetTranscriptProcessingMode() {
        let state = AppState()
        state.transcriptProcessingMode = .cleanUp
        state.transcriptCleanupModel = "llama-3.1-8b-instant"

        XCTAssertEqual(state.transcriptProcessingMode, .cleanUp)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "transcriptProcessingMode"), "cleanUp")
        XCTAssertEqual(state.transcriptCleanupModel, "llama-3.1-8b-instant")
    }

    // MARK: - isError

    func testIsErrorFalseWhenIdle() {
        let state = AppState()
        XCTAssertFalse(state.isError)
    }

    func testIsErrorTrueWhenError() {
        let state = AppState()
        state.showError("fail")
        XCTAssertTrue(state.isError)
    }

    func testIsErrorFalseAfterClear() {
        let state = AppState()
        state.showError("fail")
        state.clearError()
        XCTAssertFalse(state.isError)
    }
}
