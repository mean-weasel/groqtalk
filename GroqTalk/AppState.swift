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
    //
    // These are stored properties so that @Observable can track mutations.
    // Each didSet syncs the value back to UserDefaults for persistence.

    var soundEffectsEnabled: Bool = true {
        didSet { UserDefaults.standard.set(soundEffectsEnabled, forKey: "soundEffectsEnabled") }
    }

    var selectedModel: String = "whisper-large-v3-turbo" {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "whisperModel") }
    }

    var selectedAudioFormat: AudioFormat = .m4a {
        didSet { UserDefaults.standard.set(selectedAudioFormat.rawValue, forKey: "audioFormat") }
    }

    var selectedLanguage: Language = .auto {
        didSet { UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "language") }
    }

    var keepOnClipboard: Bool = false {
        didSet { UserDefaults.standard.set(keepOnClipboard, forKey: "keepOnClipboard") }
    }

    var asyncPasteEnabled: Bool = false {
        didSet { UserDefaults.standard.set(asyncPasteEnabled, forKey: "asyncPasteEnabled") }
    }

    var recordingMode: HotkeyMonitor.RecordingMode = .hold {
        didSet { UserDefaults.standard.set(recordingMode.rawValue, forKey: "recordingMode") }
    }

    var hotkeyChoice: HotkeyMonitor.HotkeyChoice = .rightCommand {
        didSet { UserDefaults.standard.set(hotkeyChoice.rawValue, forKey: "hotkeyChoice") }
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
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "soundEffectsEnabled": true,
            "whisperModel": "whisper-large-v3-turbo",
            "audioFormat": "m4a",
            "keepOnClipboard": false,
            "asyncPasteEnabled": false,
            "recordingMode": "hold",
            "hotkeyChoice": "rightCommand",
            "language": "auto"
        ])

        // Load persisted values into stored properties.
        // didSet does NOT fire during init, so no redundant writes.
        soundEffectsEnabled = defaults.bool(forKey: "soundEffectsEnabled")
        selectedModel = defaults.string(forKey: "whisperModel") ?? "whisper-large-v3-turbo"
        selectedAudioFormat = AudioFormat(rawValue: defaults.string(forKey: "audioFormat") ?? "") ?? .m4a
        selectedLanguage = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        keepOnClipboard = defaults.bool(forKey: "keepOnClipboard")
        asyncPasteEnabled = defaults.bool(forKey: "asyncPasteEnabled")
        recordingMode = HotkeyMonitor.RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .hold
        hotkeyChoice = HotkeyMonitor.HotkeyChoice(rawValue: defaults.string(forKey: "hotkeyChoice") ?? "") ?? .rightCommand
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
