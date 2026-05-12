import Foundation

protocol TranscriptionTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: TranscriptionTransport {}

struct TranscriptionService {
    static let maxUploadBytes = 25 * 1024 * 1024

    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    private let chatEndpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
    private let modelsEndpoint = URL(string: "https://api.groq.com/openai/v1/models")!
    private let transport: TranscriptionTransport

    init(transport: TranscriptionTransport = URLSession.shared) {
        self.transport = transport
    }

    func transcribe(audioFileURL: URL, apiKey: String, model: String, format: AudioFormat = .wav, language: Language = .auto) async throws -> String {
        guard fileSize(at: audioFileURL) <= Self.maxUploadBytes else {
            DiagnosticLog.write("transcribe: local file too large")
            throw TranscriptionError.fileTooLarge
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try await buildMultipartBodyAsync(
            audioFileURL: audioFileURL, model: model, format: format, language: language, boundary: boundary
        )
        let audioSize = fileSize(at: audioFileURL)
        let bodySize = request.httpBody?.count ?? 0
        DiagnosticLog.write(
            "transcribe: sending format=\(format.rawValue) audioBytes=\(audioSize) bodyBytes=\(bodySize) model=\(model) language=\(language.rawValue)"
        )

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            DiagnosticLog.write("transcribe: invalid response type")
            throw TranscriptionError.invalidResponse
        }
        DiagnosticLog.write("transcribe: response status=\(http.statusCode) responseBytes=\(data.count)")

        if http.statusCode == 200 {
            guard let text = String(data: data, encoding: .utf8) else {
                DiagnosticLog.write("transcribe: failed to decode response as UTF-8")
                throw TranscriptionError.invalidResponse
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            DiagnosticLog.write("transcribe: success textLength=\(trimmed.count)")
            return trimmed
        }

        let error = mapAPIError(statusCode: http.statusCode, data: data)
        DiagnosticLog.write("transcribe: API error status=\(http.statusCode) mapped=\(error.logName) bodyBytes=\(data.count)")
        throw error
    }

    func processTranscript(
        _ transcript: String,
        apiKey: String,
        mode: TranscriptProcessingMode,
        model: String
    ) async throws -> String {
        guard mode != .raw else { return transcript }
        var request = URLRequest(url: chatEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildTranscriptProcessingBody(transcript: transcript, mode: mode, model: model)

        DiagnosticLog.write("processTranscript: sending mode=\(mode.rawValue) model=\(model) inputLength=\(transcript.count)")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            DiagnosticLog.write("processTranscript: invalid response type")
            throw TranscriptionError.invalidResponse
        }
        DiagnosticLog.write("processTranscript: response status=\(http.statusCode) responseBytes=\(data.count)")

        if http.statusCode == 200 {
            let decoded: ChatCompletionResponse
            do {
                decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            } catch {
                DiagnosticLog.write("processTranscript: failed to decode response")
                throw TranscriptionError.invalidResponse
            }
            guard let content = decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else {
                throw TranscriptionError.invalidResponse
            }
            DiagnosticLog.write("processTranscript: success outputLength=\(content.count)")
            return content
        }

        let error = mapAPIError(statusCode: http.statusCode, data: data)
        DiagnosticLog.write("processTranscript: API error status=\(http.statusCode) mapped=\(error.logName) bodyBytes=\(data.count)")
        throw error
    }

    func validateApiKey(apiKey: String, requiredModels: [String] = []) async throws {
        var request = URLRequest(url: modelsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        DiagnosticLog.write("validateApiKey: checking Groq API key requiredModels=\(requiredModels.count)")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            DiagnosticLog.write("validateApiKey: invalid response type")
            throw TranscriptionError.invalidResponse
        }
        DiagnosticLog.write("validateApiKey: response status=\(http.statusCode) responseBytes=\(data.count)")

        guard http.statusCode == 200 else {
            let error = mapAPIError(statusCode: http.statusCode, data: data)
            DiagnosticLog.write("validateApiKey: API error status=\(http.statusCode) mapped=\(error.logName) bodyBytes=\(data.count)")
            throw error
        }

        let responseBody: ModelsResponse
        do {
            responseBody = try JSONDecoder().decode(ModelsResponse.self, from: data)
        } catch {
            DiagnosticLog.write("validateApiKey: failed to decode models response")
            throw TranscriptionError.invalidResponse
        }

        let availableModels = Set(responseBody.data.map(\.id))
        for model in requiredModels where !availableModels.contains(model) {
            throw TranscriptionError.modelUnavailable(model)
        }
    }

    func buildTranscriptProcessingBody(
        transcript: String,
        mode: TranscriptProcessingMode,
        model: String
    ) throws -> Data {
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: mode.promptInstruction),
                .init(role: "user", content: transcript)
            ],
            temperature: 0.2,
            maxCompletionTokens: 1024
        )
        return try JSONEncoder().encode(request)
    }

    static func buildMultipartBody(audioFileURL: URL, model: String, format: AudioFormat, language: Language = .auto, boundary: String) throws -> Data {
        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("\(model)\r\n")

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendString("text\r\n")

        if language != .auto {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.appendString("\(language.rawValue)\r\n")
        }

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(format.filename)\"\r\n")
        body.appendString("Content-Type: \(format.contentType)\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    func buildMultipartBodyAsync(
        audioFileURL: URL,
        model: String,
        format: AudioFormat,
        language: Language = .auto,
        boundary: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let body = try Self.buildMultipartBody(
                        audioFileURL: audioFileURL,
                        model: model,
                        format: format,
                        language: language,
                        boundary: boundary
                    )
                    continuation.resume(returning: body)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    enum TranscriptionError: Error, Equatable {
        case invalidResponse
        case invalidApiKey
        case fileTooLarge
        case rateLimited(String?)
        case quotaExceeded(String?)
        case modelUnavailable(String)
        case badRequest(String?)
        case serverError(Int)
        case apiError(Int, String)

        var logName: String {
            switch self {
            case .invalidResponse: "invalidResponse"
            case .invalidApiKey: "invalidApiKey"
            case .fileTooLarge: "fileTooLarge"
            case .rateLimited: "rateLimited"
            case .quotaExceeded: "quotaExceeded"
            case .modelUnavailable: "modelUnavailable"
            case .badRequest: "badRequest"
            case .serverError(let code): "serverError(\(code))"
            case .apiError(let code, _): "apiError(\(code))"
            }
        }
    }

    private func mapAPIError(statusCode: Int, data: Data) -> TranscriptionError {
        let apiError = decodeAPIError(data)
        let body = String(data: data, encoding: .utf8) ?? ""
        let message = apiError?.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = apiError?.code?.lowercased()
        let type = apiError?.type?.lowercased()
        let haystack = [message, code, type].compactMap { $0?.lowercased() }.joined(separator: " ")

        switch statusCode {
        case 400:
            if mentionsModel(haystack) {
                return .modelUnavailable(apiError?.modelName ?? message ?? "selected model")
            }
            return .badRequest(message)
        case 401, 403:
            return .invalidApiKey
        case 413:
            return .fileTooLarge
        case 429:
            if haystack.contains("quota") || haystack.contains("billing") || haystack.contains("insufficient") {
                return .quotaExceeded(message)
            }
            return .rateLimited(message)
        case 500...599:
            return .serverError(statusCode)
        default:
            return .apiError(statusCode, body)
        }
    }

    private func mentionsModel(_ text: String) -> Bool {
        text.contains("model") && (
            text.contains("not found")
                || text.contains("does not exist")
                || text.contains("unavailable")
                || text.contains("invalid")
        )
    }

    private func decodeAPIError(_ data: Data) -> APIErrorPayload.ErrorDetail? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(APIErrorPayload.self, from: data).error
    }

    private func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? -1)
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxCompletionTokens: Int

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxCompletionTokens = "max_completion_tokens"
        }

        struct Message: Encodable {
            let role: String
            let content: String
        }
    }

    private struct ChatCompletionResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: Message
        }

        struct Message: Decodable {
            let content: String
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [Model]

        struct Model: Decodable {
            let id: String
        }
    }

    private struct APIErrorPayload: Decodable {
        let error: ErrorDetail

        struct ErrorDetail: Decodable {
            let message: String
            let type: String?
            let code: String?

            var modelName: String? {
                let quoted = message.split(separator: "'")
                if quoted.count >= 2 {
                    return String(quoted[1])
                }
                return nil
            }
        }
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
