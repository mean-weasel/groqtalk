import Foundation
import Observation

@MainActor @Observable
final class AppState {
    enum Status: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    private(set) var status: Status = .idle

    var soundEffectsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundEffectsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundEffectsEnabled") }
    }

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "whisperModel") ?? "whisper-large-v3-turbo" }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModel") }
    }

    var hasApiKey: Bool { KeychainHelper.readApiKey() != nil }

    var isError: Bool {
        if case .error = status { return true }
        return false
    }

    var menuBarIcon: String {
        switch status {
        case .idle: "waveform"
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var statusText: String {
        switch status {
        case .idle: "Ready"
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .error(let msg): msg
        }
    }

    init() {
        UserDefaults.standard.register(defaults: [
            "soundEffectsEnabled": true,
            "whisperModel": "whisper-large-v3-turbo"
        ])
    }

    func setStatus(_ newStatus: Status) {
        status = newStatus
    }

    func showError(_ message: String) {
        status = .error(message)
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = status {
                status = .idle
            }
        }
    }
}
