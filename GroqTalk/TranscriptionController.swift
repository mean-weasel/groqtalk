import Foundation

// MARK: - Delegate protocol

@MainActor
protocol TranscriptionControllerDelegate: AnyObject {
    /// Called when transcription begins (audio is being sent to API).
    func transcriptionController(
        _ controller: TranscriptionController,
        didStartTranscribing audioURL: URL
    )

    /// Called when transcription succeeded and text is ready for paste.
    func transcriptionController(
        _ controller: TranscriptionController,
        didTranscribe text: String,
        audioURL: URL,
        cleanupFailed: Bool
    )

    /// Called when transcription failed.
    func transcriptionController(
        _ controller: TranscriptionController,
        didFail error: Error,
        errorMessage: String,
        audioURL: URL,
        format: AudioFormat
    )
}

// MARK: - TranscriptionController

/// Owns the transcription pipeline: API call → optional cleanup → delegate callbacks.
/// Has no knowledge of paste routing, history, or UI — those belong to the delegate (AppDelegate).
@MainActor
final class TranscriptionController {
    // MARK: Public

    weak var delegate: TranscriptionControllerDelegate?

    // MARK: Private

    private let transcriptionService: TranscriptionService
    private let appState: AppState

    // MARK: Init

    init(transcriptionService: TranscriptionService, appState: AppState) {
        self.transcriptionService = transcriptionService
        self.appState = appState
    }

    // MARK: - Public API

    /// Main transcription flow. Called after recording stops with a valid audio URL.
    func transcribe(audioURL: URL, format: AudioFormat) async {
        DiagnosticLog.write("TranscriptionController.transcribe: url=\(audioURL.lastPathComponent) format=\(format.rawValue)")

        delegate?.transcriptionController(self, didStartTranscribing: audioURL)

        let useMockTranscription: Bool
        #if DEBUG
        useMockTranscription = appState.mockTranscriptionEnabled
        #else
        useMockTranscription = false
        #endif
        DiagnosticLog.write("TranscriptionController: mock=\(useMockTranscription)")

        // Validate API key (skipped for mock mode)
        let apiKey: String?
        if useMockTranscription {
            apiKey = nil
        } else {
            guard let storedApiKey = KeychainHelper.readApiKey() else {
                let missingKeyError = TranscriptionService.TranscriptionError.invalidApiKey
                let msg = errorMessage(from: missingKeyError)
                // Use a sentinel error for "no key" that callers can detect
                let noKeyError = NoApiKeyError()
                delegate?.transcriptionController(
                    self,
                    didFail: noKeyError,
                    errorMessage: "No API key -- set one via the menu",
                    audioURL: audioURL,
                    format: format
                )
                return
            }
            apiKey = storedApiKey
        }

        do {
            let text: String
            var cleanupFailed = false

            if useMockTranscription {
                appState.transcriptionStage = .transcribingAudio
                try await Task.sleep(for: .seconds(2))
                text = "Mock transcription at \(Date().formatted(date: .omitted, time: .standard))"
            } else if let apiKey {
                appState.transcriptionStage = .transcribingAudio
                let rawText = try await transcriptionService.transcribe(
                    audioFileURL: audioURL,
                    apiKey: apiKey,
                    model: appState.selectedModel,
                    format: format,
                    language: appState.selectedLanguage
                )
                let processed = await processTranscriptOrRaw(
                    rawText: rawText,
                    apiKey: apiKey,
                    context: "transcription"
                )
                text = processed.text
                cleanupFailed = processed.cleanupFailed
            } else {
                throw TranscriptionService.TranscriptionError.invalidResponse
            }

            DiagnosticLog.write("TranscriptionController: success textLength=\(text.count) cleanupFailed=\(cleanupFailed)")
            delegate?.transcriptionController(self, didTranscribe: text, audioURL: audioURL, cleanupFailed: cleanupFailed)
        } catch {
            let msg = errorMessage(from: error)
            DiagnosticLog.write("TranscriptionController: failed error=\(msg)")
            delegate?.transcriptionController(self, didFail: error, errorMessage: msg, audioURL: audioURL, format: format)
        }
    }

    /// Retry a previously failed transcription record.
    func retryTranscription(record: TranscriptionRecord) async {
        guard let audioURL = record.audioFileURL else {
            DiagnosticLog.write("TranscriptionController.retryTranscription: no audioFileURL on record")
            return
        }
        let format = AudioFormat(rawValue: audioURL.pathExtension) ?? appState.selectedAudioFormat
        DiagnosticLog.write("TranscriptionController.retryTranscription: url=\(audioURL.lastPathComponent)")

        guard let apiKey = KeychainHelper.readApiKey() else {
            let noKeyError = NoApiKeyError()
            delegate?.transcriptionController(
                self,
                didFail: noKeyError,
                errorMessage: "No API key -- set one via the menu",
                audioURL: audioURL,
                format: format
            )
            return
        }

        do {
            appState.transcriptionStage = .transcribingAudio
            let rawText = try await transcriptionService.transcribe(
                audioFileURL: audioURL,
                apiKey: apiKey,
                model: appState.selectedModel,
                format: format,
                language: appState.selectedLanguage
            )
            let processed = await processTranscriptOrRaw(
                rawText: rawText,
                apiKey: apiKey,
                context: "retry"
            )
            DiagnosticLog.write("TranscriptionController.retryTranscription: success cleanupFailed=\(processed.cleanupFailed)")
            delegate?.transcriptionController(
                self,
                didTranscribe: processed.text,
                audioURL: audioURL,
                cleanupFailed: processed.cleanupFailed
            )
        } catch {
            let msg = errorMessage(from: error)
            DiagnosticLog.write("TranscriptionController.retryTranscription: failed error=\(msg)")
            delegate?.transcriptionController(self, didFail: error, errorMessage: msg, audioURL: audioURL, format: format)
        }
    }

    // MARK: - Internal helpers

    /// Apply transcript processing mode (cleanup/raw). Returns (text, cleanupFailed).
    func processTranscriptOrRaw(
        rawText: String,
        apiKey: String,
        context: String
    ) async -> (text: String, cleanupFailed: Bool) {
        guard appState.transcriptProcessingMode != .raw else {
            return (rawText, false)
        }

        appState.transcriptionStage = .cleaningTranscript
        do {
            let text = try await transcriptionService.processTranscript(
                rawText,
                apiKey: apiKey,
                mode: appState.transcriptProcessingMode,
                model: appState.transcriptCleanupModel
            )
            return (text, false)
        } catch {
            DiagnosticLog.write("\(context): cleanup failed mappedMessage=\(errorMessage(from: error))")
            return (rawText, true)
        }
    }

    /// Maps all error types to user-facing strings.
    func errorMessage(from error: Error) -> String {
        switch error {
        case TranscriptionService.TranscriptionError.invalidApiKey:
            "Invalid API key"
        case TranscriptionService.TranscriptionError.fileTooLarge:
            "Recording too long"
        case AudioRecorder.RecordingError.recordingTooLong:
            "Recording too long"
        case AudioRecorder.RecordingError.audioFormatUnavailable:
            "Audio format unavailable -- please restart the app"
        case TranscriptionService.TranscriptionError.rateLimited:
            "Groq rate limit reached"
        case TranscriptionService.TranscriptionError.quotaExceeded:
            "Groq quota exceeded"
        case TranscriptionService.TranscriptionError.modelUnavailable(let model):
            "Model unavailable: \(model)"
        case TranscriptionService.TranscriptionError.badRequest:
            "Groq rejected the request"
        case TranscriptionService.TranscriptionError.serverError:
            "Groq is temporarily unavailable"
        case TranscriptionService.TranscriptionError.apiError(let code, _):
            "API error (\(code))"
        case let urlError as URLError where urlError.code == .notConnectedToInternet:
            "No internet connection"
        case let urlError as URLError where urlError.code == .timedOut:
            "Request timed out"
        case let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost:
            "Cannot reach server"
        default:
            "Transcription failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Supporting types

/// Sentinel error thrown when no API key is stored in the keychain.
struct NoApiKeyError: Error {}
