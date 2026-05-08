#!/usr/bin/env swift
//
// Real Groq cleanup-quality smoke test.
//
// Reads the saved local Groq API key and runs the post-transcription cleanup
// prompts against a fixed rambling sample. Prints only model outputs, never the key.

import Foundation

struct ChatRequest: Encodable {
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
}

struct Message: Encodable, Decodable {
    let role: String
    let content: String
}

struct ChatResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }
}

enum CleanupMode: String, CaseIterable {
    case cleanUp
    case rewriteClearly

    var displayName: String {
        switch self {
        case .cleanUp: "Clean up"
        case .rewriteClearly: "Rewrite clearly"
        }
    }

    var instruction: String {
        switch self {
        case .cleanUp:
            "Clean up the transcript lightly. Fix obvious speech recognition errors, punctuation, capitalization, and filler words. Preserve the speaker's meaning and wording as much as possible. Return only the cleaned text."
        case .rewriteClearly:
            "Rewrite the transcript into clear, concise prose. Preserve all concrete facts, names, numbers, and intent. Do not add new information. Return only the rewritten text."
        }
    }
}

enum CleanupQualityTest {
    static func run() async -> Int32 {
        let keyURL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GroqTalk/api-key")

        guard let key = try? String(contentsOf: keyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            print("ERROR: Missing Groq API key at \(keyURL.path)")
            return 1
        }

        let sample = "um so i think what we need to do is like tomorrow before the demo we should maybe test the async paste thing in chrome terminal and textedit and then if that all works we can record a short video for groqtalk"
        let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        let model = "llama-3.3-70b-versatile"

        print("=== Cleanup Quality Smoke Test ===")
        print()
        print("Raw transcript:")
        print(sample)
        print()

        var failed = false
        for mode in CleanupMode.allCases {
            do {
                let output = try await process(
                    endpoint: endpoint,
                    apiKey: key,
                    model: model,
                    mode: mode,
                    transcript: sample
                )
                print("\(mode.displayName):")
                print(output)
                print()

                let lower = output.lowercased()
                let preservesCoreFacts = ["tomorrow", "demo", "async paste", "chrome", "terminal", "textedit", "video", "groqtalk"]
                    .allSatisfy { lower.contains($0) }
                if output.isEmpty || !preservesCoreFacts {
                    failed = true
                    print("❌ \(mode.displayName) failed fact-preservation smoke check.")
                } else {
                    print("✅ \(mode.displayName) returned non-empty text and preserved core facts.")
                }
                print()
            } catch {
                failed = true
                print("❌ \(mode.displayName) failed: \(error)")
                print()
            }
        }

        return failed ? 1 : 0
    }

    static func process(
        endpoint: URL,
        apiKey: String,
        model: String,
        mode: CleanupMode,
        transcript: String
    ) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: [
                    Message(role: "system", content: mode.instruction),
                    Message(role: "user", content: transcript)
                ],
                temperature: 0.2,
                maxCompletionTokens: 1024
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "CleanupQualityTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "CleanupQualityTest", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body.prefix(240))"])
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

Task {
    let code = await CleanupQualityTest.run()
    exit(code)
}

dispatchMain()
