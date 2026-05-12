import XCTest
import AVFAudio
@testable import GroqTalk

/// End-to-end tests that call the real Groq Whisper API.
/// Skipped unless RUN_LIVE_GROQ_TESTS=1 and GROQ_API_KEY are set.
final class IntegrationTests: XCTestCase {
    private var recorder: AudioRecorder!
    private var tempFiles: [URL] = []

    override func setUp() {
        recorder = AudioRecorder()
        tempFiles = []
        executionTimeAllowance = 30
    }

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    private func requireApiKey() throws -> String {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_GROQ_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_GROQ_TESTS=1 and GROQ_API_KEY to run live Groq API tests")
        }
        if let envKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"],
           !envKey.isEmpty {
            return envKey
        }
        throw XCTSkip("Set GROQ_API_KEY to run live Groq API tests")
    }

    /// Creates a 1-second synthetic 16kHz mono sine wave buffer.
    private func makeSineBuffer(frequency: Float = 440.0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(16000)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            samples[i] = sin(2.0 * .pi * frequency * Float(i) / 16000.0) * 0.5
        }
        return buffer
    }

    @discardableResult
    private func track(_ url: URL) -> URL {
        tempFiles.append(url)
        return url
    }

    // MARK: - End-to-end: encode → upload → transcribe

    func testE2E_WAV_AcceptedByGroqAPI() async throws {
        let apiKey = try requireApiKey()
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))

        let service = TranscriptionService()
        // Sine wave won't produce meaningful speech — reaching here without throwing
        // confirms the API accepted the WAV format
        _ = try await service.transcribe(
            audioFileURL: url, apiKey: apiKey, model: "whisper-large-v3-turbo", format: .wav
        )
    }

    func testE2E_M4A_AcceptedByGroqAPI() async throws {
        let apiKey = try requireApiKey()
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeM4A(buffers: [buffer]))

        let service = TranscriptionService()
        _ = try await service.transcribe(
            audioFileURL: url, apiKey: apiKey, model: "whisper-large-v3-turbo", format: .m4a
        )
    }

    func testE2E_FLAC_AcceptedByGroqAPI() async throws {
        let apiKey = try requireApiKey()
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeFLAC(buffers: [buffer]))

        let service = TranscriptionService()
        _ = try await service.transcribe(
            audioFileURL: url, apiKey: apiKey, model: "whisper-large-v3-turbo", format: .flac
        )
    }

    // MARK: - All formats combined

    func testE2E_AllFormatsProduceValidResponses() async throws {
        let apiKey = try requireApiKey()
        let buffer = makeSineBuffer()

        for format in AudioFormat.allCases {
            let url: URL
            switch format {
            case .wav:  url = track(try recorder.writeWAV(buffers: [buffer]))
            case .m4a:  url = track(try recorder.writeM4A(buffers: [buffer]))
            case .flac: url = track(try recorder.writeFLAC(buffers: [buffer]))
            }

            let service = TranscriptionService()
            do {
                _ = try await service.transcribe(
                    audioFileURL: url, apiKey: apiKey,
                    model: "whisper-large-v3-turbo", format: format
                )
            } catch TranscriptionService.TranscriptionError.invalidApiKey {
                XCTFail("\(format.rawValue): API key is invalid — verify GROQ_API_KEY is current")
            } catch TranscriptionService.TranscriptionError.fileTooLarge {
                XCTFail("\(format.rawValue): file too large for API — check test audio generation")
            } catch TranscriptionService.TranscriptionError.rateLimited {
                XCTFail("\(format.rawValue): Groq rate limit reached — retry later")
            } catch TranscriptionService.TranscriptionError.quotaExceeded {
                XCTFail("\(format.rawValue): Groq quota exceeded — check account limits")
            } catch TranscriptionService.TranscriptionError.modelUnavailable(let model) {
                XCTFail("\(format.rawValue): model unavailable — \(model)")
            } catch TranscriptionService.TranscriptionError.serverError(let code) {
                XCTFail("\(format.rawValue): Groq server error \(code)")
            } catch TranscriptionService.TranscriptionError.apiError(let code, let body) {
                XCTFail("\(format.rawValue): API returned \(code) — \(body)")
            } catch {
                XCTFail("\(format.rawValue): unexpected error — \(error)")
            }
        }
    }

    // MARK: - Multipart body correctness per format

    func testMultipartBodyMatchesEncodedFile() throws {
        let buffer = makeSineBuffer()

        for format in AudioFormat.allCases {
            let url: URL
            switch format {
            case .wav:  url = track(try recorder.writeWAV(buffers: [buffer]))
            case .m4a:  url = track(try recorder.writeM4A(buffers: [buffer]))
            case .flac: url = track(try recorder.writeFLAC(buffers: [buffer]))
            }

            let service = TranscriptionService()
            let body = try TranscriptionService.buildMultipartBody(
                audioFileURL: url, model: "whisper-large-v3-turbo",
                format: format, boundary: "test-boundary"
            )
            let bodyString = String(data: body, encoding: .isoLatin1)!

            XCTAssertTrue(
                bodyString.contains("filename=\"\(format.filename)\""),
                "\(format.rawValue): filename should be \(format.filename)"
            )
            XCTAssertTrue(
                bodyString.contains("Content-Type: \(format.contentType)"),
                "\(format.rawValue): content type should be \(format.contentType)"
            )

            let audioData = try Data(contentsOf: url)
            XCTAssertNotNil(
                body.range(of: audioData),
                "\(format.rawValue): multipart body must contain the encoded audio data"
            )
        }
    }

    func testMultipartBodyIncludesLanguageField() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))

        let service = TranscriptionService()
        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: url, model: "whisper-large-v3-turbo",
            format: .wav, language: .es, boundary: "test-boundary"
        )
        let bodyString = String(data: body, encoding: .isoLatin1)!

        XCTAssertTrue(
            bodyString.contains("name=\"language\"\r\n\r\nes"),
            "Spanish language hint should be in multipart body"
        )
    }

    func testMultipartBodyOmitsLanguageForAuto() throws {
        let buffer = makeSineBuffer()
        let url = track(try recorder.writeWAV(buffers: [buffer]))

        let service = TranscriptionService()
        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: url, model: "whisper-large-v3-turbo",
            format: .wav, language: .auto, boundary: "test-boundary"
        )
        let bodyString = String(data: body, encoding: .isoLatin1)!

        XCTAssertFalse(
            bodyString.contains("name=\"language\""),
            "Auto-detect should not include language field"
        )
    }

    // MARK: - Error recovery

    @MainActor
    func testErrorStateClearsOnNewRecording() {
        let state = AppState()
        state.showError("Network timeout")
        XCTAssertEqual(state.status, .error("Network timeout"), "Status should be error before recording")

        state.setStatus(.recording)

        XCTAssertEqual(state.status, .recording, "Status should be recording after setStatus(.recording)")
        XCTAssertFalse(state.isError, "isError should be false once recording begins")
    }

    @MainActor
    func testTransientResultClearsOnNewRecording() {
        let state = AppState()
        state.recordPaste(.currentApp)
        XCTAssertNotNil(state.transientResult, "transientResult should be set after recordPaste")

        state.setStatus(.recording)

        XCTAssertNil(state.transientResult, "transientResult should be cleared when recording starts")
    }

    @MainActor
    func testMultipleErrorsDoNotAccumulate() {
        let state = AppState()
        state.showError("First error")
        XCTAssertEqual(state.status, .error("First error"))

        state.showError("Second error")

        XCTAssertEqual(
            state.status,
            .error("Second error"),
            "Latest error should replace the previous error"
        )
        // Verify the first error is gone — only one error state is held at a time.
        if case .error(let message) = state.status {
            XCTAssertEqual(message, "Second error", "Only the most recent error should be stored")
        } else {
            XCTFail("Status should still be .error after calling showError a second time")
        }
    }
}
