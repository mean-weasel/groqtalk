import SwiftUI

struct ApiKeySetupView: View {
    var onSaved: (() -> Void)?
    var validateApiKey: (String) async throws -> Void = { key in
        try await TranscriptionService().validateApiKey(apiKey: key)
    }

    @State private var apiKey = ""
    @State private var errorMessage: String?
    @State private var saved = false
    @State private var isValidating = false
    @State private var canSaveWithoutValidation = false
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)

            Text("GroqTalk Setup")
                .font(.headline)

            Text("Enter your Groq API key to enable speech-to-text.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("gsk_...", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .accessibilityLabel("Groq API Key")
                .accessibilityIdentifier("apiKeySetup.apiKeyField")

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(errorMessage)")
                    .accessibilityIdentifier("apiKeySetup.errorMessage")
            }

            if saved {
                Label("API key saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                    .accessibilityLabel("API key is valid")
                    .accessibilityIdentifier("apiKeySetup.validIndicator")
            }

            if isValidating {
                ProgressView("Checking key...")
                    .controlSize(.small)
                    .font(.caption)
                    .accessibilityLabel("Validating API key")
                    .accessibilityIdentifier("apiKeySetup.progress")
            }

            HStack {
                if let groqKeysURL = URL(string: "https://console.groq.com/keys") {
                    Link("Get API Key", destination: groqKeysURL)
                        .font(.caption)
                        .accessibilityIdentifier("apiKeySetup.getKeyLink")
                }

                Spacer()

                if canSaveWithoutValidation {
                    Button("Save Anyway") {
                        saveKeyWithoutValidation()
                    }
                    .accessibilityIdentifier("apiKeySetup.saveAnywayButton")
                }

                Button(isValidating ? "Checking..." : "Save & Test") {
                    saveKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty || isValidating)
                .accessibilityIdentifier("apiKeySetup.saveTestButton")
            }
        }
        .padding(24)
        .frame(width: 380)
        .accessibilityIdentifier("apiKeySetup.root")
        .onAppear {
            if let existing = KeychainHelper.readApiKey() {
                apiKey = existing
            }
        }
    }

    private func saveKey() {
        isValidating = true
        errorMessage = nil
        canSaveWithoutValidation = false
        let key = apiKey
        Task {
            do {
                try await validateApiKey(key)
                try KeychainHelper.save(apiKey: key)
                await MainActor.run {
                    finishSaved()
                }
            } catch {
                await MainActor.run {
                    isValidating = false
                    saved = false
                    errorMessage = validationMessage(from: error)
                    canSaveWithoutValidation = allowsSaveAnyway(for: error)
                }
            }
        }
    }

    private func saveKeyWithoutValidation() {
        do {
            try KeychainHelper.save(apiKey: apiKey)
            finishSaved()
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    private func finishSaved() {
        isValidating = false
        canSaveWithoutValidation = false
        onSaved?()
        saved = true
        errorMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            dismissWindow(id: "api-key-setup")
        }
    }

    private func allowsSaveAnyway(for error: Error) -> Bool {
        error is URLError
    }

    private func validationMessage(from error: Error) -> String {
        switch error {
        case TranscriptionService.TranscriptionError.invalidApiKey:
            "Invalid Groq API key."
        case TranscriptionService.TranscriptionError.rateLimited:
            "Groq rate limit reached. Try again shortly."
        case TranscriptionService.TranscriptionError.quotaExceeded:
            "Groq quota exceeded. Check your account limits."
        case TranscriptionService.TranscriptionError.serverError:
            "Groq is temporarily unavailable. Try again later."
        case let urlError as URLError where urlError.code == .notConnectedToInternet:
            "Could not reach Groq. Check your connection, or save anyway and test later."
        case let urlError as URLError where urlError.code == .timedOut:
            "Groq validation timed out. You can save anyway and test later."
        default:
            "Could not validate key: \(error.localizedDescription)"
        }
    }
}
