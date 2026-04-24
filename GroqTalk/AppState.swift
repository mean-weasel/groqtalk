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

    // MARK: - Timer state

    var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0
    var transcribingIconFrame: Int = 0

    // MARK: - UserDefaults-backed preferences

    var soundEffectsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundEffectsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundEffectsEnabled") }
    }

    var selectedModel: String {
        get { UserDefaults.standard.string(forKey: "whisperModel") ?? "whisper-large-v3-turbo" }
        set { UserDefaults.standard.set(newValue, forKey: "whisperModel") }
    }

    var selectedAudioFormat: AudioFormat {
        get { AudioFormat(rawValue: UserDefaults.standard.string(forKey: "audioFormat") ?? "") ?? .m4a }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "audioFormat") }
    }

    var keepOnClipboard: Bool {
        get { UserDefaults.standard.bool(forKey: "keepOnClipboard") }
        set { UserDefaults.standard.set(newValue, forKey: "keepOnClipboard") }
    }

    var recordingMode: HotkeyMonitor.RecordingMode {
        get { HotkeyMonitor.RecordingMode(rawValue: UserDefaults.standard.string(forKey: "recordingMode") ?? "") ?? .hold }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "recordingMode") }
    }

    var hotkeyChoice: HotkeyMonitor.HotkeyChoice {
        get { HotkeyMonitor.HotkeyChoice(rawValue: UserDefaults.standard.string(forKey: "hotkeyChoice") ?? "") ?? .rightCommand }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkeyChoice") }
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
        case .transcribing:
            transcribingIconFrame == 0 ? "ellipsis.circle" : "ellipsis.circle.fill"
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

    var formattedRecordingDuration: String {
        let seconds = Int(recordingDuration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    init() {
        UserDefaults.standard.register(defaults: [
            "soundEffectsEnabled": true,
            "whisperModel": "whisper-large-v3-turbo",
            "audioFormat": "m4a",
            "keepOnClipboard": false,
            "recordingMode": "hold",
            "hotkeyChoice": "rightCommand"
        ])
    }

    func setStatus(_ newStatus: Status) {
        status = newStatus
    }

    func showError(_ message: String) {
        status = .error(message)
    }

    func clearError() {
        if case .error = status {
            status = .idle
        }
    }
}
