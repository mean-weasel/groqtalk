import SwiftUI

struct OnboardingView: View {
    @Bindable var appState: AppState
    var onComplete: () -> Void

    @State private var currentStep: Int = 0

    private let steps = ["API Key", "Accessibility", "Microphone"]

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut, value: currentStep)
                        .accessibilityLabel("Step \(index + 1) of \(steps.count)\(index == currentStep ? ", current" : "")")
                }
            }
            .padding(.top, 24)

            Spacer()

            // Step content
            Group {
                switch currentStep {
                case 0:
                    apiKeyStep
                case 1:
                    accessibilityStep
                case 2:
                    microphoneStep
                default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation {
                            currentStep -= 1
                        }
                    }
                    .accessibilityIdentifier("onboarding.backButton")
                }

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Next") {
                        withAnimation {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("onboarding.nextButton")
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!appState.isSetupReady)
                    .accessibilityIdentifier("onboarding.getStartedButton")
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .frame(width: 420, height: 340)
        .accessibilityIdentifier("onboarding.root")
    }

    // MARK: - Step Views

    private var apiKeyStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Groq API Key")
                .font(.title2)
                .fontWeight(.semibold)

            Text("GroqTalk uses the Groq API to transcribe your voice. You'll need a free API key to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            permissionStatusBadge(state: appState.apiKeyState, readyLabel: "API key saved")

            if let url = URL(string: "https://console.groq.com/keys") {
                Link("Get a free API key at console.groq.com", destination: url)
                    .font(.caption)
            }
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Accessibility Permission")
                .font(.title2)
                .fontWeight(.semibold)

            Text("GroqTalk needs Accessibility access to paste transcribed text into other apps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            permissionStatusBadge(state: appState.accessibilityState, readyLabel: "Accessibility enabled")

            Button("Open Privacy & Security Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
            .accessibilityIdentifier("onboarding.openAccessibilityButton")
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "mic.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)

            Text("GroqTalk needs microphone access to record your voice for transcription.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            permissionStatusBadge(state: appState.microphoneState, readyLabel: "Microphone access granted")

            Button("Open Privacy & Security Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            .font(.caption)
            .accessibilityIdentifier("onboarding.openMicrophoneButton")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func permissionStatusBadge(state: AppState.PermissionState, readyLabel: String) -> some View {
        switch state {
        case .ready:
            Label(readyLabel, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
                .accessibilityLabel("Ready")
        case .needsAction(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
                .accessibilityLabel("Needs attention: \(message)")
        case .unknown:
            Label("Checking...", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
                .font(.caption)
                .accessibilityLabel("Checking status")
        }
    }
}
