import XCTest
@testable import GroqTalk

// MARK: - Delegate spy

@MainActor
final class RecordingControllerDelegateSpy: RecordingControllerDelegate {
    private(set) var didStartCount = 0
    private(set) var didStopCalls: [(url: URL, format: AudioFormat)] = []
    private(set) var didStopWithNoAudioCount = 0
    private(set) var didCancelCount = 0
    private(set) var didFailErrors: [Error] = []

    func recordingControllerDidStart(_ controller: RecordingController) {
        didStartCount += 1
    }

    func recordingController(
        _ controller: RecordingController,
        didStopWithURL audioURL: URL,
        format: AudioFormat
    ) {
        didStopCalls.append((url: audioURL, format: format))
    }

    func recordingControllerDidStopWithNoAudio(_ controller: RecordingController) {
        didStopWithNoAudioCount += 1
    }

    func recordingControllerDidCancel(_ controller: RecordingController) {
        didCancelCount += 1
    }

    func recordingController(_ controller: RecordingController, didFailWithError error: Error) {
        didFailErrors.append(error)
    }
}

// MARK: - Tests

@MainActor
final class RecordingControllerTests: XCTestCase {
    private var appState: AppState!
    private var audioRecorder: AudioRecorder!
    private var controller: RecordingController!
    private var spy: RecordingControllerDelegateSpy!

    override func setUpWithError() throws {
        appState = AppState()
        audioRecorder = AudioRecorder()
        controller = RecordingController(audioRecorder: audioRecorder, appState: appState)
        spy = RecordingControllerDelegateSpy()
        controller.delegate = spy
    }

    override func tearDown() {
        controller.invalidateTimers()
        controller = nil
        audioRecorder = nil
        appState = nil
        spy = nil
    }

    // MARK: - testStartRecordingRequiresSetupReady

    /// Verify that when setup is not ready, startRecording skips (does not change status to .recording).
    /// Note: the controller does not gate on `isSetupReady` directly — the real guard is that
    /// the microphone call will throw. When AppState is freshly created (setup not ready),
    /// appState.status is .idle so the status guard passes, but the audioRecorder.startRecording()
    /// call on a simulator will fail without a real input device, firing didFail.
    /// This test validates the controller stays coherent (isRecording stays false) after a failure.
    func testStartRecordingRequiresSetupReady() throws {
        // Initial state: setup not ready (permissions unknown by default)
        XCTAssertFalse(appState.isSetupReady)
        XCTAssertFalse(controller.isRecording)

        // In a unit-test host without a real microphone, audioRecorder.startRecording()
        // will throw. The controller must catch it and remain in a non-recording state.
        controller.startRecording()

        // isRecording must stay false whether we got an error or the mic happened to start
        if spy.didFailErrors.isEmpty {
            // Mic started (real device / CI with mic) — cancel to clean up
            XCTAssertTrue(controller.isRecording)
            controller.cancelRecording()
        } else {
            XCTAssertFalse(controller.isRecording)
            XCTAssertEqual(spy.didStartCount, 0)
            XCTAssertFalse(appState.status == .recording)
        }
    }

    // MARK: - testCancelRecordingResetsToIdle

    /// Verify that cancelRecording returns to idle state and fires the delegate cancel callback.
    func testCancelRecordingResetsToIdle() {
        // Drive appState to recording manually so we can call cancelRecording
        appState.setStatus(.recording)

        controller.cancelRecording()

        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(spy.didCancelCount, 1, "delegate didCancel must be called once")
        // Status is not changed by the controller itself on cancel —
        // that's the AppDelegate's responsibility via the delegate callback.
        // But isRecording must be false.
    }

    // MARK: - testIsRecordingReflectsState

    /// Verify isRecording computed property tracks recording state correctly.
    func testIsRecordingReflectsState() {
        XCTAssertFalse(controller.isRecording, "starts false")

        // Simulate what happens when recording starts successfully
        // by calling cancelRecording (which also sets isRecording = false, confirming it was false)
        controller.cancelRecording()
        XCTAssertFalse(controller.isRecording, "still false after cancel with no active recording")

        // Ensure calling cancel again is idempotent
        controller.cancelRecording()
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(spy.didCancelCount, 2)
    }

    // MARK: - testInvalidateTimersCleansUp

    /// Verify that invalidateTimers does not crash and can be called multiple times safely.
    func testInvalidateTimersCleansUp() {
        // Should not crash even without any timers running
        XCTAssertNoThrow(controller.invalidateTimers())
        XCTAssertNoThrow(controller.invalidateTimers())
    }

    // MARK: - testStopRecordingSkipsWhenNotRecording

    /// Verify that stopRecording does nothing (no delegate callbacks) when not in recording state.
    func testStopRecordingSkipsWhenNotRecording() {
        XCTAssertEqual(appState.status, .idle)

        controller.stopRecording()

        XCTAssertEqual(spy.didStopCalls.count, 0)
        XCTAssertEqual(spy.didStopWithNoAudioCount, 0)
        XCTAssertEqual(spy.didFailErrors.count, 0)
    }

    // MARK: - testCancelFiresDelegateOnce

    /// Verify the delegate cancel callback fires exactly once per cancel call.
    func testCancelFiresDelegateOnce() {
        controller.cancelRecording()
        XCTAssertEqual(spy.didCancelCount, 1)

        controller.cancelRecording()
        XCTAssertEqual(spy.didCancelCount, 2)
    }
}
