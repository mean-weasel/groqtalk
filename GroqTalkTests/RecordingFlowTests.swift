import XCTest
@testable import GroqTalk

@MainActor
final class RecordingFlowTests: XCTestCase {
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        appState = AppState()
    }

    override func tearDown() {
        appState = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Mark all permissions as ready so setup-warning branches don't interfere with other tests.
    private func markSetupReady() {
        appState.updateAccessibilityState(isTrusted: true)
        appState.updateMicrophoneState(isReady: true)
        appState.apiKeyState = .ready
    }

    // MARK: - Full State Flow

    func testFullStateFlow_idleToRecordingToTranscribingToIdle() {
        XCTAssertEqual(appState.status, .idle)

        appState.setStatus(.recording)
        XCTAssertEqual(appState.status, .recording)

        appState.setStatus(.transcribing)
        XCTAssertEqual(appState.status, .transcribing)

        appState.setStatus(.idle)
        XCTAssertEqual(appState.status, .idle)
    }

    func testStateFlow_recordingCancelledResetsCleanly() {
        appState.setStatus(.recording)
        appState.recordingDuration = 42
        appState.recordingStartTime = Date()

        appState.setStatus(.idle)

        XCTAssertEqual(appState.status, .idle)
        XCTAssertNil(appState.transcriptionStage)
    }

    func testStateFlow_errorFromTranscribing() {
        appState.setStatus(.transcribing)
        appState.showError("API rate limit exceeded")

        XCTAssertTrue(appState.isError)
        if case .error(let msg) = appState.status {
            XCTAssertEqual(msg, "API rate limit exceeded")
        } else {
            XCTFail("Status should be .error")
        }
    }

    func testStateFlow_clearErrorReturnsToIdle() {
        appState.showError("Some error")
        appState.clearError()
        XCTAssertEqual(appState.status, .idle)
    }

    func testStateFlow_clearErrorIsNoOpWhenNotError() {
        appState.setStatus(.recording)
        appState.clearError()
        XCTAssertEqual(appState.status, .recording)
    }

    func testStateFlow_multipleErrorsDoNotAccumulate() {
        appState.showError("First error")
        XCTAssertEqual(appState.status, .error("First error"))

        appState.showError("Second error")
        XCTAssertEqual(appState.status, .error("Second error"))
    }

    // MARK: - Recording Time Limit

    func testRecordingTimeLimitIntegration_notApproachingWhenShort() {
        appState.setStatus(.recording)
        appState.recordingDuration = 0
        XCTAssertFalse(appState.isApproachingTimeLimit)
    }

    func testRecordingTimeLimitIntegration_approachingPastThreshold() {
        appState.setStatus(.recording)
        appState.recordingDuration = 541
        XCTAssertTrue(appState.isApproachingTimeLimit)
        XCTAssertEqual(appState.remainingRecordingTime, 59, accuracy: 0.01)
    }

    func testRecordingTimeLimitIntegration_notApproachingWhenNotRecording() {
        // Even with duration past threshold, limit only applies while recording
        appState.recordingDuration = 550
        XCTAssertFalse(appState.isApproachingTimeLimit)
    }

    func testFormattedRemainingTime_atWarningBoundary() {
        appState.setStatus(.recording)
        appState.recordingDuration = 540
        XCTAssertEqual(appState.formattedRemainingTime, "1:00")
    }

    func testRemainingRecordingTime_neverNegative() {
        appState.recordingDuration = 700
        XCTAssertEqual(appState.remainingRecordingTime, 0)
    }

    // MARK: - Transcription Stages

    func testTranscriptionStageProgression() {
        appState.setStatus(.transcribing)

        // Default stage set by setStatus(.transcribing) when none was previously set
        XCTAssertEqual(appState.transcriptionStage, .transcribingAudio)

        appState.transcriptionStage = .cleaningTranscript
        XCTAssertEqual(appState.transcriptionStage, .cleaningTranscript)

        appState.transcriptionStage = .pasting
        XCTAssertEqual(appState.transcriptionStage, .pasting)
    }

    func testTranscriptionStageClearsWhenReturningToIdle() {
        appState.setStatus(.transcribing)
        XCTAssertEqual(appState.transcriptionStage, .transcribingAudio)

        appState.setStatus(.idle)
        XCTAssertNil(appState.transcriptionStage)
    }

    func testTranscriptionStageClearsOnError() {
        appState.setStatus(.transcribing)
        appState.transcriptionStage = .cleaningTranscript

        appState.showError("Transcription failed")

        XCTAssertNil(appState.transcriptionStage)
    }

    func testTranscriptionStagePreservedWhenAlreadySetBeforeTranscribing() {
        // Set a stage before calling setStatus(.transcribing)
        appState.transcriptionStage = .cleaningTranscript
        appState.setStatus(.transcribing)

        // setStatus(.transcribing) only sets to .transcribingAudio if stage is nil
        XCTAssertEqual(appState.transcriptionStage, .cleaningTranscript)
    }

    // MARK: - Paste Delivery

    func testPasteDeliveryRecordsCurrentApp() {
        appState.recordPaste(.currentApp)
        XCTAssertEqual(appState.transientResult, .pasted(.currentApp))
        XCTAssertEqual(appState.lastPasteSummary, "Pasted into the current app")
    }

    func testPasteDeliveryRecordsAsyncBackground() {
        appState.recordPaste(.asyncBackground)
        XCTAssertEqual(appState.transientResult, .pasted(.asyncBackground))
        XCTAssertEqual(appState.lastPasteSummary, "Pasted into the original app")
    }

    func testPasteDeliveryRecordsClipboardFallback() {
        appState.recordPaste(.clipboardFallback)
        XCTAssertEqual(appState.transientResult, .clipboardFallback)
        XCTAssertEqual(appState.clipboardFeedback, "Text is on the clipboard")
    }

    func testPasteDeliverySetsFloatingStatusVisible() {
        appState.recordPaste(.currentApp)
        XCTAssertTrue(appState.floatingStatusTransientVisible)
    }

    // MARK: - Session Presentation

    func testSessionPresentationReflectsIdleState_setupNotReady() {
        // Default state has permissions not set (unknown), so session shows warning
        let presentation = appState.sessionPresentation(
            hotkeyLabel: "Right Cmd",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
        // With unknown permissions, it shows setup warning
        XCTAssertEqual(presentation.tone, .warning)
    }

    func testSessionPresentationReflectsIdleState_setupReady() {
        markSetupReady()
        let presentation = appState.sessionPresentation(
            hotkeyLabel: "Right Cmd",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
        XCTAssertEqual(presentation.tone, .neutral)
        XCTAssertEqual(presentation.title, "Ready")
    }

    func testSessionPresentationReflectsRecordingState() {
        appState.setStatus(.recording)
        let presentation = appState.sessionPresentation(
            hotkeyLabel: "Right Cmd",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
        XCTAssertEqual(presentation.tone, .active)
        XCTAssertEqual(presentation.title, "Recording")
    }

    func testSessionPresentationReflectsTranscribingState() {
        appState.setStatus(.transcribing)
        let presentation = appState.sessionPresentation(
            hotkeyLabel: "Right Cmd",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
        XCTAssertEqual(presentation.tone, .progress)
        XCTAssertEqual(presentation.title, "Transcribing")
    }

    func testSessionPresentationReflectsErrorState() {
        appState.showError("Network timeout")
        let presentation = appState.sessionPresentation(
            hotkeyLabel: "Right Cmd",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
        XCTAssertEqual(presentation.tone, .warning)
        XCTAssertEqual(presentation.title, "Network timeout")
    }

    func testSessionPresentationReflectsSuccessPaste() {
        markSetupReady()
        appState.recordPaste(.currentApp)
        let presentation = appState.sessionPresentation(
            hotkeyLabel: "Right Cmd",
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
        XCTAssertEqual(presentation.tone, .success)
        XCTAssertEqual(presentation.title, "Pasted into the current app")
    }

    // MARK: - Menu Bar Icon

    func testMenuBarIconReflectsIdleSetupNeeded() {
        // Default state: permissions unknown → setup needed icon
        XCTAssertEqual(appState.menuBarIcon, "exclamationmark.triangle.fill")
    }

    func testMenuBarIconReflectsIdleReady() {
        markSetupReady()
        XCTAssertEqual(appState.menuBarIcon, "waveform")
    }

    func testMenuBarIconReflectsRecording() {
        appState.setStatus(.recording)
        XCTAssertEqual(appState.menuBarIcon, "waveform.circle.fill")
        XCTAssertFalse(appState.menuBarIcon.isEmpty)
    }

    func testMenuBarIconReflectsTranscribing() {
        appState.setStatus(.transcribing)
        appState.transcribingIconFrame = 0
        XCTAssertEqual(appState.menuBarIcon, "ellipsis.circle")
        XCTAssertFalse(appState.menuBarIcon.isEmpty)

        appState.transcribingIconFrame = 1
        XCTAssertEqual(appState.menuBarIcon, "ellipsis.circle.fill")
    }

    func testMenuBarIconReflectsError() {
        appState.showError("Something failed")
        XCTAssertEqual(appState.menuBarIcon, "exclamationmark.triangle.fill")
        XCTAssertFalse(appState.menuBarIcon.isEmpty)
    }

    func testMenuBarIconReflectsPasteSuccess() {
        markSetupReady()
        appState.recordPaste(.currentApp)
        XCTAssertEqual(appState.menuBarIcon, "checkmark.circle.fill")
    }

    func testMenuBarIconReflectsClipboardFallback() {
        markSetupReady()
        appState.recordPaste(.clipboardFallback)
        XCTAssertEqual(appState.menuBarIcon, "clipboard")
    }

    // MARK: - Transient State Cleanup

    func testTransientStateClearsOnRecordingStart() {
        appState.recordPaste(.currentApp)
        XCTAssertNotNil(appState.transientResult)

        appState.setStatus(.recording)

        // setStatus(.recording) clears transientResult
        XCTAssertNil(appState.transientResult)
    }

    func testFeedbackAndSummaryResetOnRecordingStart() {
        appState.recordPaste(.currentApp)
        XCTAssertNotNil(appState.lastPasteSummary)

        appState.setStatus(.recording)

        XCTAssertNil(appState.lastPasteSummary)
        XCTAssertNil(appState.clipboardFeedback)
    }

    func testErrorStateClearsOnNewRecordingStart() {
        appState.showError("Previous error")
        XCTAssertTrue(appState.isError)

        appState.clearError()
        appState.setStatus(.recording)

        XCTAssertFalse(appState.isError)
        XCTAssertEqual(appState.status, .recording)
    }

    func testErrorStatusDirectlyReplacedByRecording() {
        // setStatus(.recording) can also be called directly on an error state
        appState.showError("Previous error")
        XCTAssertTrue(appState.isError)

        appState.setStatus(.recording)

        XCTAssertEqual(appState.status, .recording)
        XCTAssertFalse(appState.isError)
    }

    // MARK: - Transient Success Expiry

    func testExpireTransientSuccessClearsTransientResult() {
        appState.recordPaste(.currentApp)
        XCTAssertEqual(appState.transientResult, .pasted(.currentApp))

        appState.expireTransientSuccess()

        XCTAssertNil(appState.transientResult)
        XCTAssertFalse(appState.floatingStatusTransientVisible)
    }

    func testExpireTransientDoesNotClearClipboardFallback() {
        appState.recordPaste(.clipboardFallback)
        XCTAssertEqual(appState.transientResult, .clipboardFallback)

        appState.expireTransientSuccess()

        // clipboardFallback is NOT cleared by expireTransientSuccess
        XCTAssertEqual(appState.transientResult, .clipboardFallback)
    }

    func testExpireTransientIsNoOpWhenNotIdle() {
        appState.setStatus(.recording)
        // recordPaste while recording (unusual but tests guard)
        appState.recordPaste(.currentApp)

        // expireTransientSuccess is a no-op when status != .idle
        appState.expireTransientSuccess()

        // transient result stays because status is not .idle
        XCTAssertEqual(appState.transientResult, .pasted(.currentApp))
    }

    // MARK: - Clear Transient Feedback

    func testClearTransientFeedbackResetsAllFeedbackFields() {
        appState.recordPaste(.currentApp)
        appState.capturedTargetName = "Notes"

        appState.clearTransientFeedback()

        XCTAssertNil(appState.capturedTargetName)
        XCTAssertNil(appState.feedbackMessage)
        XCTAssertNil(appState.clipboardFeedback)
        XCTAssertNil(appState.transientResult)
        XCTAssertFalse(appState.floatingStatusTransientVisible)
        XCTAssertFalse(appState.floatingStatusDismissed)
    }

    // MARK: - Status Text Correctness

    func testStatusTextIdleSetupNeeded() {
        XCTAssertEqual(appState.statusText, "Setup needed")
    }

    func testStatusTextIdleReady() {
        markSetupReady()
        XCTAssertEqual(appState.statusText, "Ready")
    }

    func testStatusTextRecording() {
        appState.setStatus(.recording)
        XCTAssertEqual(appState.statusText, "Recording...")
    }

    func testStatusTextTranscribing() {
        appState.setStatus(.transcribing)
        XCTAssertEqual(appState.statusText, "Transcribing...")
    }

    func testStatusTextError() {
        appState.showError("Something went wrong")
        XCTAssertEqual(appState.statusText, "Something went wrong")
    }

    // MARK: - isError Computed Property

    func testIsErrorFalseWhenIdle() {
        XCTAssertFalse(appState.isError)
    }

    func testIsErrorFalseWhenRecording() {
        appState.setStatus(.recording)
        XCTAssertFalse(appState.isError)
    }

    func testIsErrorTrueAfterShowError() {
        appState.showError("Test error")
        XCTAssertTrue(appState.isError)
    }

    func testIsErrorFalseAfterClearError() {
        appState.showError("Test error")
        appState.clearError()
        XCTAssertFalse(appState.isError)
    }
}
