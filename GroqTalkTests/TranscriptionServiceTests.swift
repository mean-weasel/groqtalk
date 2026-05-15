import XCTest
@testable import GroqTalk

final class TranscriptionServiceTests: XCTestCase {
    private final class StubTransport: TranscriptionTransport {
        var requests: [URLRequest] = []
        let handler: (URLRequest) async throws -> (Data, URLResponse)

        init(handler: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            return try await handler(request)
        }
    }

    private static func makeAudioFile(name: String = UUID().uuidString, bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("wav")
        try Data(bytes).write(to: url)
        return url
    }

    private static func httpResponse(statusCode: Int, url: URL = URL(string: "https://api.groq.com")!) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private static func apiErrorJSON(message: String, type: String? = nil, code: String? = nil) -> Data {
        var error: [String: Any] = ["message": message]
        if let type { error["type"] = type }
        if let code { error["code"] = code }
        let payload: [String: Any] = ["error": error]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Providers

    func testGroqProviderBuildsExpectedDefaultEndpoints() {
        let provider = TranscriptionProvider.groq

        XCTAssertEqual(
            provider.audioTranscriptionsEndpoint.absoluteString,
            "https://api.groq.com/openai/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            provider.chatCompletionsEndpoint.absoluteString,
            "https://api.groq.com/openai/v1/chat/completions"
        )
        XCTAssertEqual(
            provider.modelsEndpoint.absoluteString,
            "https://api.groq.com/openai/v1/models"
        )
        XCTAssertEqual(provider.transcriptionModel, "whisper-large-v3-turbo")
        XCTAssertTrue(provider.requiresAPIKey)
        XCTAssertTrue(provider.supportsModelValidation)
    }

    func testOpenAICompatibleProviderBuildsEndpointsFromCustomBaseURL() {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )

        XCTAssertEqual(
            provider.audioTranscriptionsEndpoint.absoluteString,
            "http://127.0.0.1:8080/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            provider.chatCompletionsEndpoint.absoluteString,
            "http://127.0.0.1:8080/v1/chat/completions"
        )
        XCTAssertEqual(
            provider.modelsEndpoint.absoluteString,
            "http://127.0.0.1:8080/v1/models"
        )
        XCTAssertEqual(provider.transcriptionModel, "whisper-1")
        XCTAssertFalse(provider.requiresAPIKey)
        XCTAssertFalse(provider.supportsModelValidation)
    }

    func testMultipartBodyContainsAllFields() throws {
        let service = TranscriptionService()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let boundary = "test-boundary-123"
        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL,
            model: "whisper-large-v3-turbo",
            format: .wav,
            boundary: boundary
        )
        let bodyString = String(data: body, encoding: .utf8)!

        XCTAssertTrue(bodyString.contains("--test-boundary-123\r\n"))
        XCTAssertTrue(bodyString.contains("name=\"model\"\r\n\r\nwhisper-large-v3-turbo"))
        XCTAssertTrue(bodyString.contains("name=\"response_format\"\r\n\r\ntext"))
        XCTAssertTrue(bodyString.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/wav"))
        XCTAssertTrue(bodyString.contains("--test-boundary-123--"))
    }

    func testMultipartBodyM4AFormat() throws {
        let service = TranscriptionService()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio.m4a")
        try Data([0x00, 0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL,
            model: "whisper-large-v3",
            format: .m4a,
            boundary: "b"
        )
        let bodyString = String(data: body, encoding: .utf8)!

        XCTAssertTrue(bodyString.contains("filename=\"audio.m4a\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/mp4"))
    }

    func testMultipartBodyFLACFormat() throws {
        let service = TranscriptionService()

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio.flac")
        try Data([0x66, 0x4C, 0x61, 0x43]).write(to: tempURL) // "fLaC" magic
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL,
            model: "whisper-large-v3",
            format: .flac,
            boundary: "b"
        )
        let bodyString = String(data: body, encoding: .utf8)!

        XCTAssertTrue(bodyString.contains("filename=\"audio.flac\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/flac"))
    }

    func testMultipartBodyIncludesAudioData() throws {
        let service = TranscriptionService()

        let audioBytes: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05]
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-audio2.wav")
        try Data(audioBytes).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL,
            model: "whisper-large-v3",
            format: .wav,
            boundary: "b"
        )

        let audioData = Data(audioBytes)
        XCTAssertNotNil(body.range(of: audioData))
    }

    // MARK: - Format consistency

    func testAllThreeFormatsProduceDistinctContentTypes() throws {
        let service = TranscriptionService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-ct.bin")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var contentTypes: Set<String> = []

        for format in AudioFormat.allCases {
            let body = try TranscriptionService.buildMultipartBody(
                audioFileURL: tempURL, model: "m", format: format, boundary: "b"
            )
            let bodyString = String(data: body, encoding: .isoLatin1)!
            if let range = bodyString.range(of: "Content-Type: audio/") {
                let start = range.lowerBound
                let lineEnd = bodyString[start...].firstIndex(of: "\r") ?? bodyString.endIndex
                contentTypes.insert(String(bodyString[start..<lineEnd]))
            }
        }

        XCTAssertEqual(contentTypes.count, 3, "Each format should produce a distinct Content-Type")
    }

    func testMultipartBodyIncludesResponseFormatText() throws {
        let service = TranscriptionService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-rf.wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL, model: "whisper-large-v3", format: .wav, boundary: "b"
        )
        let bodyString = String(data: body, encoding: .utf8)!
        XCTAssertTrue(bodyString.contains("name=\"response_format\"\r\n\r\ntext"),
                       "Multipart body must request text response format")
    }

    func testMultipartBodyBoundaryTermination() throws {
        let service = TranscriptionService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-term.wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL, model: "m", format: .wav, boundary: "BOUNDARY"
        )
        let bodyString = String(data: body, encoding: .utf8)!
        XCTAssertTrue(bodyString.hasSuffix("--BOUNDARY--\r\n"),
                       "Multipart body must end with closing boundary")
    }

    func testTranscriptProcessingBodyUsesGroqChatShape() throws {
        let service = TranscriptionService()

        let data = try service.buildTranscriptProcessingBody(
            transcript: "um this is teh thing",
            mode: .cleanUp,
            model: "llama-3.3-70b-versatile"
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = json?["messages"] as? [[String: String]]

        XCTAssertEqual(json?["model"] as? String, "llama-3.3-70b-versatile")
        XCTAssertEqual(json?["temperature"] as? Double, 0.2)
        XCTAssertEqual(json?["max_completion_tokens"] as? Int, 1024)
        XCTAssertEqual(messages?.first?["role"], "system")
        XCTAssertTrue(messages?.first?["content"]?.contains("Clean up the transcript lightly") == true)
        XCTAssertEqual(messages?.last?["role"], "user")
        XCTAssertEqual(messages?.last?["content"], "um this is teh thing")
    }

    // MARK: - Deterministic transport/status mapping

    func testTranscribeReturnsTrimmedTextForHTTP200() async throws {
        let transport = StubTransport { request in
            (
                Data("  hello world\n".utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        }
        let service = TranscriptionService(transport: transport)
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let text = try await service.transcribe(
            audioFileURL: tempURL,
            apiKey: "test-key",
            model: "whisper-large-v3",
            format: .wav
        )

        XCTAssertEqual(text, "hello world")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testTranscribeUsesCustomOpenAICompatibleEndpointAndCanOmitAuthorization() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/audio/transcriptions")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (
                Data("local transcript".utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        }
        let service = TranscriptionService(provider: provider, transport: transport)
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let text = try await service.transcribe(
            audioFileURL: tempURL,
            apiKey: nil,
            model: provider.transcriptionModel,
            format: .wav
        )

        XCTAssertEqual(text, "local transcript")
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testTranscribeTrimsDummyAuthorizationForLocalProvider() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )
        let transport = StubTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local")
            return (
                Data("local transcript".utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        }
        let service = TranscriptionService(provider: provider, transport: transport)
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        _ = try await service.transcribe(
            audioFileURL: tempURL,
            apiKey: " local ",
            model: provider.transcriptionModel,
            format: .wav
        )
    }

    func testTranscribeMapsHTTP401ToInvalidApiKey() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data("unauthorized".utf8), Self.httpResponse(statusCode: 401, url: request.url!))
        })
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "bad", model: "m")
            XCTFail("Expected invalid API key error")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .invalidApiKey)
        }
    }

    func testTranscribeMapsHTTP413ToFileTooLarge() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data("too large".utf8), Self.httpResponse(statusCode: 413, url: request.url!))
        })
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "m")
            XCTFail("Expected file too large error")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .fileTooLarge)
        }
    }

    func testTranscribePreflightsOversizedFileBeforeNetwork() async throws {
        var transportCalled = false
        let service = TranscriptionService(transport: StubTransport { _ in
            transportCalled = true
            return (Data("should not call".utf8), Self.httpResponse(statusCode: 200))
        })
        let tempURL = try Self.makeAudioFile(
            name: "oversized",
            bytes: Array(repeating: 0x00, count: TranscriptionService.maxUploadBytes + 1)
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "m")
            XCTFail("Expected file too large")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .fileTooLarge)
        }
        XCTAssertFalse(transportCalled)
    }

    func testAsyncMultipartBodyMatchesSyncBuilder() async throws {
        let service = TranscriptionService()
        let tempURL = try Self.makeAudioFile(bytes: [0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sync = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL,
            model: "whisper-large-v3",
            format: .wav,
            language: .es,
            boundary: "boundary"
        )
        let async = try await service.buildMultipartBodyAsync(
            audioFileURL: tempURL,
            model: "whisper-large-v3",
            format: .wav,
            language: .es,
            boundary: "boundary"
        )

        XCTAssertEqual(async, sync)
    }

    func testTranscribeMapsHTTP429ToRateLimited() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (
                Self.apiErrorJSON(message: "Rate limit reached", type: "rate_limit_error"),
                Self.httpResponse(statusCode: 429, url: request.url!)
            )
        })
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "m")
            XCTFail("Expected rate limit error")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .rateLimited("Rate limit reached"))
        }
    }

    func testTranscribeMapsHTTP429QuotaBodyToQuotaExceeded() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (
                Self.apiErrorJSON(message: "Quota exceeded. Check billing.", type: "insufficient_quota"),
                Self.httpResponse(statusCode: 429, url: request.url!)
            )
        })
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "m")
            XCTFail("Expected quota error")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .quotaExceeded("Quota exceeded. Check billing."))
        }
    }

    func testTranscribeMapsHTTP500ToServerError() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data("server exploded".utf8), Self.httpResponse(statusCode: 500, url: request.url!))
        })
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "m")
            XCTFail("Expected server error")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .serverError(500))
        }
    }

    func testTranscribeMapsBadRequestModelBodyToModelUnavailable() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (
                Self.apiErrorJSON(message: "The model 'missing-model' does not exist"),
                Self.httpResponse(statusCode: 400, url: request.url!)
            )
        })
        let tempURL = try Self.makeAudioFile()
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "missing-model")
            XCTFail("Expected model unavailable")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .modelUnavailable("missing-model"))
        }
    }

    func testProcessTranscriptMapsMalformedChatResponseToInvalidResponse() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data(#"{"choices":[{"message":{"content":"   "}}]}"#.utf8), Self.httpResponse(statusCode: 200, url: request.url!))
        })

        do {
            _ = try await service.processTranscript(
                "raw transcript",
                apiKey: "key",
                mode: .cleanUp,
                model: "llama-3.3-70b-versatile"
            )
            XCTFail("Expected invalid response")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testProcessTranscriptMapsMalformedJSONToInvalidResponse() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data(#"{"choices":["#.utf8), Self.httpResponse(statusCode: 200, url: request.url!))
        })

        do {
            _ = try await service.processTranscript(
                "raw transcript",
                apiKey: "key",
                mode: .cleanUp,
                model: "llama-3.3-70b-versatile"
            )
            XCTFail("Expected invalid response")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testProcessTranscriptMapsHTTP401ToInvalidApiKey() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data("unauthorized".utf8), Self.httpResponse(statusCode: 401, url: request.url!))
        })

        do {
            _ = try await service.processTranscript(
                "raw transcript",
                apiKey: "bad",
                mode: .cleanUp,
                model: "llama-3.3-70b-versatile"
            )
            XCTFail("Expected invalid API key")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .invalidApiKey)
        }
    }

    func testProcessTranscriptMapsHTTP429ToRateLimited() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (
                Self.apiErrorJSON(message: "Rate limit reached", type: "rate_limit_error"),
                Self.httpResponse(statusCode: 429, url: request.url!)
            )
        })

        do {
            _ = try await service.processTranscript(
                "raw transcript",
                apiKey: "key",
                mode: .cleanUp,
                model: "llama-3.3-70b-versatile"
            )
            XCTFail("Expected rate limit")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .rateLimited("Rate limit reached"))
        }
    }

    func testValidateApiKeyUsesModelsEndpointAndAuthorization() async throws {
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.groq.com/openai/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            return (
                Data(#"{"data":[{"id":"whisper-large-v3-turbo"},{"id":"llama-3.3-70b-versatile"}]}"#.utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        }
        let service = TranscriptionService(transport: transport)

        try await service.validateApiKey(
            apiKey: "test-key",
            requiredModels: ["whisper-large-v3-turbo", "llama-3.3-70b-versatile"]
        )

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testValidateApiKeySkipsModelsEndpointForOpenAICompatibleProvider() async throws {
        var transportCalled = false
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )
        let service = TranscriptionService(provider: provider, transport: StubTransport { request in
            transportCalled = true
            return (Data("unexpected".utf8), Self.httpResponse(statusCode: 500, url: request.url!))
        })

        try await service.validateApiKey(apiKey: nil, requiredModels: ["whisper-1"])

        XCTAssertFalse(transportCalled)
    }

    func testValidateProviderConfigurationChecksCustomModelsEndpoint() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8080/v1/models")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.timeoutInterval, TranscriptionService.providerValidationTimeout)
            return (
                Data(#"{"data":[{"id":"whisper-1"}]}"#.utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        }
        let service = TranscriptionService(provider: provider, transport: transport)

        let result = try await service.validateProviderConfiguration(apiKey: nil, requiredModels: ["whisper-1"])

        XCTAssertEqual(result, .modelsValidated)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testValidateProviderConfigurationAllowsReachableCustomServerWithoutModelsEndpoint() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )
        let service = TranscriptionService(provider: provider, transport: StubTransport { request in
            (
                Data("not found".utf8),
                Self.httpResponse(statusCode: 404, url: request.url!)
            )
        })

        let result = try await service.validateProviderConfiguration(apiKey: nil, requiredModels: ["whisper-1"])

        XCTAssertEqual(result, .reachableWithoutModelValidation)
    }

    func testValidateProviderConfigurationFailsWhenCustomServerIsUnreachable() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:9999/v1")!,
            model: "whisper-1"
        )
        let service = TranscriptionService(provider: provider, transport: StubTransport { _ in
            throw URLError(.cannotConnectToHost)
        })

        do {
            _ = try await service.validateProviderConfiguration(apiKey: nil, requiredModels: ["whisper-1"])
            XCTFail("Expected reachability failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }

    func testValidateProviderConfigurationRejectsInvalidCustomBaseURL() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(fileURLWithPath: "/tmp/whisper"),
            model: "whisper-1"
        )
        let service = TranscriptionService(provider: provider, transport: StubTransport { request in
            XCTFail("Invalid base URL should fail before request: \(String(describing: request.url))")
            return (Data(), Self.httpResponse(statusCode: 500))
        })

        do {
            _ = try await service.validateProviderConfiguration(apiKey: nil, requiredModels: ["whisper-1"])
            XCTFail("Expected invalid provider URL")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .invalidProviderURL)
        }
    }

    func testValidateProviderConfigurationFailsWhenCustomModelIsUnavailable() async throws {
        let provider = TranscriptionProvider.openAICompatible(
            baseURL: URL(string: "http://127.0.0.1:8080/v1")!,
            model: "whisper-1"
        )
        let service = TranscriptionService(provider: provider, transport: StubTransport { request in
            (
                Data(#"{"data":[{"id":"other-model"}]}"#.utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        })

        do {
            _ = try await service.validateProviderConfiguration(apiKey: nil, requiredModels: ["whisper-1"])
            XCTFail("Expected missing custom model failure")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .modelUnavailable("whisper-1"))
        }
    }

    func testValidateApiKeyMapsHTTP401ToInvalidApiKey() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (Data("unauthorized".utf8), Self.httpResponse(statusCode: 401, url: request.url!))
        })

        do {
            try await service.validateApiKey(apiKey: "bad")
            XCTFail("Expected invalid API key")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .invalidApiKey)
        }
    }

    func testValidateApiKeyFailsWhenRequiredModelIsUnavailable() async throws {
        let service = TranscriptionService(transport: StubTransport { request in
            (
                Data(#"{"data":[{"id":"whisper-large-v3-turbo"}]}"#.utf8),
                Self.httpResponse(statusCode: 200, url: request.url!)
            )
        })

        do {
            try await service.validateApiKey(
                apiKey: "key",
                requiredModels: ["whisper-large-v3-turbo", "missing-cleanup-model"]
            )
            XCTFail("Expected model unavailable")
        } catch let error as TranscriptionService.TranscriptionError {
            XCTAssertEqual(error, .modelUnavailable("missing-cleanup-model"))
        }
    }

    func testTranscribePropagatesTimeoutAndOfflineErrors() async throws {
        for code in [URLError.timedOut, .notConnectedToInternet] {
            let service = TranscriptionService(transport: StubTransport { _ in
                throw URLError(code)
            })
            let tempURL = try Self.makeAudioFile()
            defer { try? FileManager.default.removeItem(at: tempURL) }

            do {
                _ = try await service.transcribe(audioFileURL: tempURL, apiKey: "key", model: "m")
                XCTFail("Expected URL error \(code)")
            } catch let error as URLError {
                XCTAssertEqual(error.code, code)
            }
        }
    }
}
