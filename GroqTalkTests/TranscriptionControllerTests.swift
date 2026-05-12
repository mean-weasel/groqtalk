import XCTest
@testable import GroqTalk

// MARK: - Delegate spy

@MainActor
final class TranscriptionDelegateSpy: TranscriptionControllerDelegate {
    private(set) var didStartCalls: [URL] = []
    private(set) var didTranscribeCalls: [(text: String, audioURL: URL, cleanupFailed: Bool)] = []
    private(set) var didFailCalls: [(error: Error, errorMessage: String, audioURL: URL, format: AudioFormat)] = []

    func transcriptionController(
        _ controller: TranscriptionController,
        didStartTranscribing audioURL: URL
    ) {
        didStartCalls.append(audioURL)
    }

    func transcriptionController(
        _ controller: TranscriptionController,
        didTranscribe text: String,
        audioURL: URL,
        cleanupFailed: Bool
    ) {
        didTranscribeCalls.append((text: text, audioURL: audioURL, cleanupFailed: cleanupFailed))
    }

    func transcriptionController(
        _ controller: TranscriptionController,
        didFail error: Error,
        errorMessage: String,
        audioURL: URL,
        format: AudioFormat
    ) {
        didFailCalls.append((error: error, errorMessage: errorMessage, audioURL: audioURL, format: format))
    }
}

// MARK: - Tests

@MainActor
final class TranscriptionControllerTests: XCTestCase {
    private var appState: AppState!
    private var controller: TranscriptionController!
    private var spy: TranscriptionDelegateSpy!

    override func setUpWithError() throws {
        appState = AppState()
        controller = TranscriptionController(
            transcriptionService: TranscriptionService(),
            appState: appState
        )
        spy = TranscriptionDelegateSpy()
        controller.delegate = spy
    }

    override func tearDown() {
        controller = nil
        appState = nil
        spy = nil
    }

    // MARK: - errorMessage mapping

    func testErrorMessageInvalidApiKey() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.invalidApiKey)
        XCTAssertEqual(msg, "Invalid API key")
    }

    func testErrorMessageRateLimited() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.rateLimited("Rate limit reached"))
        XCTAssertEqual(msg, "Groq rate limit reached")
    }

    func testErrorMessageFileTooLarge() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.fileTooLarge)
        XCTAssertEqual(msg, "Recording too long")
    }

    func testErrorMessageRecordingTooLong() {
        let msg = controller.errorMessage(from: AudioRecorder.RecordingError.recordingTooLong)
        XCTAssertEqual(msg, "Recording too long")
    }

    func testErrorMessageQuotaExceeded() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.quotaExceeded(nil))
        XCTAssertEqual(msg, "Groq quota exceeded")
    }

    func testErrorMessageServerError() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.serverError(503))
        XCTAssertEqual(msg, "Groq is temporarily unavailable")
    }

    func testErrorMessageBadRequest() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.badRequest(nil))
        XCTAssertEqual(msg, "Groq rejected the request")
    }

    func testErrorMessageModelUnavailable() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.modelUnavailable("some-model"))
        XCTAssertEqual(msg, "Model unavailable: some-model")
    }

    func testErrorMessageApiError() {
        let msg = controller.errorMessage(from: TranscriptionService.TranscriptionError.apiError(418, "teapot"))
        XCTAssertEqual(msg, "API error (418)")
    }

    func testErrorMessageNoInternet() {
        let msg = controller.errorMessage(from: URLError(.notConnectedToInternet))
        XCTAssertEqual(msg, "No internet connection")
    }

    func testErrorMessageTimedOut() {
        let msg = controller.errorMessage(from: URLError(.timedOut))
        XCTAssertEqual(msg, "Request timed out")
    }

    func testErrorMessageCannotConnectToHost() {
        let msg = controller.errorMessage(from: URLError(.cannotConnectToHost))
        XCTAssertEqual(msg, "Cannot reach server")
    }

    func testErrorMessageCannotFindHost() {
        let msg = controller.errorMessage(from: URLError(.cannotFindHost))
        XCTAssertEqual(msg, "Cannot reach server")
    }

    func testErrorMessageUnknownFallback() {
        struct SomeUnknownError: Error, LocalizedError {
            var errorDescription: String? { "something went wrong" }
        }
        let msg = controller.errorMessage(from: SomeUnknownError())
        XCTAssertTrue(msg.hasPrefix("Transcription failed:"), "Expected fallback message, got: \(msg)")
    }

    // MARK: - processTranscriptOrRaw

    func testProcessTranscriptOrRawReturnsRawWhenModeIsRaw() async {
        appState.transcriptProcessingMode = .raw
        let result = await controller.processTranscriptOrRaw(
            rawText: "hello world",
            apiKey: "any-key",
            context: "test"
        )
        XCTAssertEqual(result.text, "hello world")
        XCTAssertFalse(result.cleanupFailed)
    }

    // MARK: - transcribe without API key

    func testTranscribeFailsGracefullyWithoutApiKey() async throws {
        // Ensure no API key is stored (test environment has no keychain entry for this test)
        // We make the audio URL point to a temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        // Write minimal data so the file exists
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // The test keychain environment almost certainly has no key; if it does this test is moot
        // but we still verify that either:
        //   (a) didFail is called (no key path), or
        //   (b) some network error is thrown (key exists, real network call fails)
        // Either way, didTranscribe must NOT be called.
        await controller.transcribe(audioURL: tempURL, format: .wav)

        XCTAssertEqual(spy.didTranscribeCalls.count, 0,
                        "didTranscribe should not be called when no API key or network fails")
        // didFail or didStart may have been called depending on environment
        // The important invariant: no successful transcription without an API key
    }

    // MARK: - retryTranscription with missing audio file

    func testRetryTranscriptionWithNoAudioURLOnRecordDoesNothing() async {
        let record = TranscriptionRecord(
            id: UUID(),
            timestamp: Date(),
            outcome: .failure(error: "some error", audioFileURL: nil)
        )
        await controller.retryTranscription(record: record)

        XCTAssertEqual(spy.didStartCalls.count, 0)
        XCTAssertEqual(spy.didTranscribeCalls.count, 0)
        XCTAssertEqual(spy.didFailCalls.count, 0)
    }

    // MARK: - Delegate is notified of didStart before outcome

    func testTranscribeCallsDidStartBeforeOutcome() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        await controller.transcribe(audioURL: tempURL, format: .wav)

        // didStart should be fired first regardless of outcome
        XCTAssertEqual(spy.didStartCalls.count, 1)
        XCTAssertEqual(spy.didStartCalls.first, tempURL)
    }
}
