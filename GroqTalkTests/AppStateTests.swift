import XCTest
@testable import GroqTalk

@MainActor
final class AppStateTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "audioFormat")
        UserDefaults.standard.removeObject(forKey: "keepOnClipboard")
        UserDefaults.standard.removeObject(forKey: "recordingMode")
        UserDefaults.standard.removeObject(forKey: "hotkeyChoice")
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
    }

    func testClearErrorNoOpWhenNotError() {
        let state = AppState()
        state.setStatus(.recording)
        state.clearError()
        XCTAssertEqual(state.status, .recording)
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
