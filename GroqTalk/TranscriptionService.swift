import Foundation

struct TranscriptionService {
    private let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    func transcribe(audioFileURL: URL, apiKey: String, model: String, format: AudioFormat = .wav) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try buildMultipartBody(
            audioFileURL: audioFileURL, model: model, format: format, boundary: boundary
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            guard let text = String(data: data, encoding: .utf8) else {
                throw TranscriptionError.invalidResponse
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case 401:
            throw TranscriptionError.invalidApiKey
        case 413:
            throw TranscriptionError.fileTooLarge
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.apiError(http.statusCode, body)
        }
    }

    func buildMultipartBody(audioFileURL: URL, model: String, format: AudioFormat, boundary: String) throws -> Data {
        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("\(model)\r\n")

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        body.appendString("text\r\n")

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(format.filename)\"\r\n")
        body.appendString("Content-Type: \(format.contentType)\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        body.appendString("--\(boundary)--\r\n")
        return body
    }

    enum TranscriptionError: Error, Equatable {
        case invalidResponse
        case invalidApiKey
        case fileTooLarge
        case apiError(Int, String)
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
