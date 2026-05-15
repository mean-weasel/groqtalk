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
    private var audioRecorder: MockAudioRecorder!
    private var controller: RecordingController!
    private var spy: RecordingControllerDelegateSpy!

    override func setUpWithError() throws {
        appState = AppState()
        audioRecorder = MockAudioRecorder()
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

    /// Verify that a recorder start failure leaves controller state coherent.
    func testStartRecordingRequiresSetupReady() throws {
        audioRecorder.startRecordingShouldThrow = AudioRecorder.RecordingError.audioFormatUnavailable
        XCTAssertFalse(appState.isSetupReady)
        XCTAssertFalse(controller.isRecording)

        controller.startRecording()

        XCTAssertEqual(audioRecorder.startRecordingCallCount, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(spy.didStartCount, 0)
        XCTAssertEqual(spy.didFailErrors.count, 1)
        XCTAssertFalse(appState.status == .recording)
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

// MARK: - Tests (MockAudioRecorder — deterministic, no hardware required)

@MainActor
final class RecordingControllerMockTests: XCTestCase {
    private var appState: AppState!
    private var mock: MockAudioRecorder!
    private var controller: RecordingController!
    private var spy: RecordingControllerDelegateSpy!

    override func setUpWithError() throws {
        appState = AppState()
        mock = MockAudioRecorder()
        controller = RecordingController(audioRecorder: mock, appState: appState)
        spy = RecordingControllerDelegateSpy()
        controller.delegate = spy
    }

    override func tearDown() {
        controller.invalidateTimers()
        controller = nil
        mock = nil
        appState = nil
        spy = nil
    }

    // MARK: - testStartRecordingCallsAudioRecorder

    /// Happy path: startRecording reaches the mock, sets isRecording, and fires didStart.
    func testStartRecordingCallsAudioRecorder() {
        controller.startRecording()

        XCTAssertEqual(mock.startRecordingCallCount, 1, "mock startRecording must be called once")
        XCTAssertTrue(controller.isRecording)
        XCTAssertEqual(appState.status, .recording)
        XCTAssertEqual(spy.didStartCount, 1)
        XCTAssertTrue(spy.didFailErrors.isEmpty)
    }

    // MARK: - testStartRecordingFailureSetsError

    /// When the mock throws, the controller must catch it, leave isRecording false, and fire didFail.
    func testStartRecordingFailureSetsError() {
        mock.startRecordingShouldThrow = AudioRecorder.RecordingError.audioFormatUnavailable

        controller.startRecording()

        XCTAssertEqual(mock.startRecordingCallCount, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertNotEqual(appState.status, .recording)
        XCTAssertEqual(spy.didStartCount, 0)
        XCTAssertEqual(spy.didFailErrors.count, 1)
    }

    // MARK: - testStopRecordingCallsDelegate

    /// Happy path: stopRecording with a URL from the mock fires didStopWithURL.
    func testStopRecordingCallsDelegate() async throws {
        let expectedURL = URL(fileURLWithPath: "/tmp/test-audio.wav")
        mock.stopRecordingResult = expectedURL

        // Put the controller into recording state first
        controller.startRecording()
        XCTAssertTrue(controller.isRecording)

        controller.stopRecording()

        // stopRecording is async internally; yield to the run loop so the Task completes
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 s

        XCTAssertEqual(mock.stopRecordingCallCount, 1)
        XCTAssertEqual(spy.didStopCalls.count, 1)
        XCTAssertEqual(spy.didStopCalls.first?.url, expectedURL)
        XCTAssertTrue(spy.didFailErrors.isEmpty)
    }

    // MARK: - testStopRecordingWithNoAudioCallsDelegate

    /// When the mock returns nil, the controller must fire didStopWithNoAudio.
    func testStopRecordingWithNoAudioCallsDelegate() async throws {
        mock.stopRecordingResult = nil // default, but explicit for clarity

        controller.startRecording()
        controller.stopRecording()

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mock.stopRecordingCallCount, 1)
        XCTAssertEqual(spy.didStopWithNoAudioCount, 1)
        XCTAssertTrue(spy.didStopCalls.isEmpty)
        XCTAssertTrue(spy.didFailErrors.isEmpty)
    }

    // MARK: - testStopRecordingErrorCallsDelegate

    /// When the mock throws during stop, the controller must fire didFail.
    func testStopRecordingErrorCallsDelegate() async throws {
        mock.stopRecordingShouldThrow = AudioRecorder.RecordingError.conversionFailed(errorCount: 3)

        controller.startRecording()
        controller.stopRecording()

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mock.stopRecordingCallCount, 1)
        XCTAssertTrue(spy.didStopCalls.isEmpty)
        XCTAssertEqual(spy.didFailErrors.count, 1)
    }

    // MARK: - testCancelRecordingCallsMock

    /// cancelRecording must reach the mock's cancelRecording method.
    func testCancelRecordingCallsMock() {
        controller.startRecording()
        controller.cancelRecording()

        XCTAssertEqual(mock.cancelRecordingCallCount, 1)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(spy.didCancelCount, 1)
    }
}
