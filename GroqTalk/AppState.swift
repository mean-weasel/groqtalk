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

    enum TransientResult: Equatable {
        case pasted(PasteDelivery)
        case clipboardFallback
    }

    enum TranscriptionStage: Equatable {
        case transcribingAudio
        case cleaningTranscript
        case pasting
    }

    enum PermissionState: Equatable {
        case unknown
        case ready
        case needsAction(String)
    }

    enum SetupCheckState: Equatable {
        case idle
        case running
        case passed(Date)
        case failed(String)
    }

    enum SessionTone: Equatable {
        case neutral
        case active
        case progress
        case success
        case warning
    }

    enum SessionAction: Equatable {
        case retry
        case openAccessibility
        case openMicrophone
        case addKey
        case pasteAgain
        case copy

        var title: String {
            switch self {
            case .retry: "Retry"
            case .openAccessibility, .openMicrophone: "Open"
            case .addKey: "Add Key"
            case .pasteAgain: "Again"
            case .copy: "Copy"
            }
        }
    }

    struct SessionPresentation: Equatable {
        let title: String
        let detail: String
        let timerText: String?
        let systemImage: String
        let tone: SessionTone
        let primaryAction: SessionAction?
    }

    private(set) var status: Status = .idle

    // MARK: - Timer state

    var recordingStartTime: Date?
    var recordingDuration: TimeInterval = 0
    var transcribingIconFrame: Int = 0
    var lastPasteSummary: String?
    var capturedTargetName: String?
    var feedbackMessage: String?
    var clipboardFeedback: String?
    var transientResult: TransientResult?
    var transcriptionStage: TranscriptionStage?
    var floatingStatusTransientVisible = false
    var floatingStatusDismissed = false
    var accessibilityState: PermissionState = .unknown
    var microphoneState: PermissionState = .unknown
    var apiKeyState: PermissionState = .unknown
    var setupCheckState: SetupCheckState = .idle

    // MARK: - UserDefaults-backed preferences
    //
    // These are stored properties so that @Observable can track mutations.
    // Each didSet syncs the value back to UserDefaults for persistence.

    private static var defaults: UserDefaults {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let defaults = UserDefaults(suiteName: "com.neonwatty.GroqTalk.UITests") {
            return defaults
        }
        return .standard
    }

    var soundEffectsEnabled: Bool = true {
        didSet { Self.defaults.set(soundEffectsEnabled, forKey: "soundEffectsEnabled") }
    }

    var selectedModel: String = "whisper-large-v3-turbo" {
        didSet { Self.defaults.set(selectedModel, forKey: "whisperModel") }
    }

    var selectedAudioFormat: AudioFormat = .m4a {
        didSet { Self.defaults.set(selectedAudioFormat.rawValue, forKey: "audioFormat") }
    }

    var selectedLanguage: Language = .auto {
        didSet { Self.defaults.set(selectedLanguage.rawValue, forKey: "language") }
    }

    var transcriptProcessingMode: TranscriptProcessingMode = .raw {
        didSet { Self.defaults.set(transcriptProcessingMode.rawValue, forKey: "transcriptProcessingMode") }
    }

    var transcriptCleanupModel: String = "llama-3.3-70b-versatile" {
        didSet { Self.defaults.set(transcriptCleanupModel, forKey: "transcriptCleanupModel") }
    }

    var keepOnClipboard: Bool = false {
        didSet { Self.defaults.set(keepOnClipboard, forKey: "keepOnClipboard") }
    }

    var showFloatingStatus: Bool = false {
        didSet {
            Self.defaults.set(showFloatingStatus, forKey: "showFloatingStatus")
            if showFloatingStatus {
                floatingStatusDismissed = false
            }
        }
    }

    var asyncPasteEnabled: Bool = false {
        didSet { Self.defaults.set(asyncPasteEnabled, forKey: "asyncPasteEnabled") }
    }

    var experimentalSkyLightPasteEnabled: Bool = false {
        didSet { Self.defaults.set(experimentalSkyLightPasteEnabled, forKey: "experimentalSkyLightPasteEnabled") }
    }

    #if DEBUG
    var mockTranscriptionEnabled: Bool = false {
        didSet { Self.defaults.set(mockTranscriptionEnabled, forKey: "mockTranscriptionEnabled") }
    }
    #endif

    var recordingMode: HotkeyMonitor.RecordingMode = .hold {
        didSet { Self.defaults.set(recordingMode.rawValue, forKey: "recordingMode") }
    }

    var hotkeyChoice: HotkeyMonitor.HotkeyChoice = .rightCommand {
        didSet { Self.defaults.set(hotkeyChoice.rawValue, forKey: "hotkeyChoice") }
    }

    var selectedInputDeviceID: UInt32? {
        didSet {
            if let id = selectedInputDeviceID {
                Self.defaults.set(id, forKey: "selectedInputDeviceID")
            } else {
                Self.defaults.removeObject(forKey: "selectedInputDeviceID")
            }
        }
    }

    var hasApiKey: Bool { KeychainHelper.readApiKey() != nil }

    var isSetupReady: Bool {
        accessibilityState == .ready
            && microphoneState == .ready
            && apiKeyState == .ready
    }

    var needsSetupAttention: Bool {
        !isSetupReady
    }

    var isSetupCheckRunning: Bool {
        if case .running = setupCheckState { return true }
        return false
    }

    var isError: Bool {
        if case .error = status { return true }
        return false
    }

    var canStartRecordingControl: Bool {
        status == .idle && isSetupReady
    }

    var canStopRecordingControl: Bool {
        status == .recording
    }

    var canCancelRecordingControl: Bool {
        status == .recording
    }

    var shouldShowFloatingStatus: Bool {
        guard showFloatingStatus, !floatingStatusDismissed else { return false }
        switch status {
        case .recording, .transcribing, .error:
            return true
        case .idle:
            return floatingStatusTransientVisible
                && (feedbackMessage != nil || lastPasteSummary != nil || clipboardFeedback != nil)
        }
    }

    var menuBarIcon: String {
        switch status {
        case .idle:
            if needsSetupAttention {
                return "exclamationmark.triangle.fill"
            }
            switch transientResult {
            case .pasted:
                return "checkmark.circle.fill"
            case .clipboardFallback:
                return "clipboard"
            case nil:
                return "waveform"
            }
        case .recording:
            return "waveform.circle.fill"
        case .transcribing:
            return transcribingIconFrame == 0 ? "ellipsis.circle" : "ellipsis.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var statusText: String {
        switch status {
        case .idle: isSetupReady ? "Ready" : "Setup needed"
        case .recording: "Recording..."
        case .transcribing: "Transcribing..."
        case .error(let msg): msg
        }
    }

    var formattedRecordingDuration: String {
        let seconds = Int(recordingDuration)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Recording time warning

    static let maxRecordingDuration: TimeInterval = 600
    static let warningThreshold: TimeInterval = 540

    var isApproachingTimeLimit: Bool {
        status == .recording && recordingDuration >= Self.warningThreshold
    }

    var remainingRecordingTime: TimeInterval {
        max(0, Self.maxRecordingDuration - recordingDuration)
    }

    var formattedRemainingTime: String {
        let remaining = Int(remainingRecordingTime)
        return "\(remaining / 60):\(String(format: "%02d", remaining % 60))"
    }

    func sessionPresentation(
        hotkeyLabel: String,
        hasRetryableFailure: Bool,
        hasLastSuccess: Bool
    ) -> SessionPresentation {
        switch status {
        case .idle:
            if let setupPresentation = setupSessionPresentation() {
                return setupPresentation
            }
            switch transientResult {
            case .pasted:
                return SessionPresentation(
                    title: lastPasteSummary ?? "Pasted",
                    detail: clipboardFeedback ?? "Ready for the next dictation",
                    timerText: nil,
                    systemImage: "checkmark.circle.fill",
                    tone: .success,
                    primaryAction: hasLastSuccess ? .pasteAgain : nil
                )
            case .clipboardFallback:
                return SessionPresentation(
                    title: "Copied to clipboard",
                    detail: "Paste was blocked in the target app",
                    timerText: nil,
                    systemImage: "clipboard",
                    tone: .warning,
                    primaryAction: hasLastSuccess ? .copy : nil
                )
            case nil:
                return SessionPresentation(
                    title: "Ready",
                    detail: "\(hotkeyLabel) · \(asyncPasteEnabled ? "Pastes where recording starts" : "Pastes into current app")",
                    timerText: nil,
                    systemImage: "waveform",
                    tone: .neutral,
                    primaryAction: nil
                )
            }
        case .recording:
            let instruction = recordingMode == .hold
                ? "Release \(hotkeyLabel) to send"
                : "Press \(hotkeyLabel) again to stop"
            let target = capturedTargetName.map { "Target: \($0)" }
            return SessionPresentation(
                title: "Recording",
                detail: [target, instruction].compactMap { $0 }.joined(separator: " · "),
                timerText: formattedRecordingDuration,
                systemImage: "record.circle",
                tone: .active,
                primaryAction: nil
            )
        case .transcribing:
            return transcriptionSessionPresentation()
        case .error(let message):
            return SessionPresentation(
                title: message,
                detail: errorDetail(for: message, hasRetryableFailure: hasRetryableFailure),
                timerText: nil,
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                primaryAction: errorAction(for: message, hasRetryableFailure: hasRetryableFailure)
            )
        }
    }

    private func setupSessionPresentation() -> SessionPresentation? {
        if accessibilityState != .ready {
            return SessionPresentation(
                title: "Setup needed",
                detail: setupDetail(
                    for: accessibilityState,
                    unknown: "Check Accessibility before recording",
                    needsAction: "Enable Accessibility before recording"
                ),
                timerText: nil,
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                primaryAction: .openAccessibility
            )
        }
        if microphoneState != .ready {
            return SessionPresentation(
                title: "Setup needed",
                detail: setupDetail(
                    for: microphoneState,
                    unknown: "Check microphone access before recording",
                    needsAction: "Allow microphone access before recording"
                ),
                timerText: nil,
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                primaryAction: .openMicrophone
            )
        }
        if apiKeyState != .ready {
            return SessionPresentation(
                title: "Setup needed",
                detail: apiKeySetupDetail(),
                timerText: nil,
                systemImage: "exclamationmark.triangle.fill",
                tone: .warning,
                primaryAction: .addKey
            )
        }
        return nil
    }

    private func apiKeySetupDetail() -> String {
        switch apiKeyState {
        case .unknown:
            "Check Groq API key before recording"
        case .needsAction(let message):
            message
        case .ready:
            ""
        }
    }

    private func setupDetail(
        for state: PermissionState,
        unknown: String,
        needsAction: String
    ) -> String {
        switch state {
        case .unknown:
            unknown
        case .needsAction:
            needsAction
        case .ready:
            ""
        }
    }

    private func transcriptionSessionPresentation() -> SessionPresentation {
        switch transcriptionStage ?? .transcribingAudio {
        case .transcribingAudio:
            return SessionPresentation(
                title: "Transcribing",
                detail: transcriptionDetail,
                timerText: nil,
                systemImage: "waveform.badge.magnifyingglass",
                tone: .progress,
                primaryAction: nil
            )
        case .cleaningTranscript:
            return SessionPresentation(
                title: "Cleaning up",
                detail: "\(transcriptCleanupModel) · \(transcriptProcessingMode.displayName)",
                timerText: nil,
                systemImage: "sparkles",
                tone: .progress,
                primaryAction: nil
            )
        case .pasting:
            return SessionPresentation(
                title: "Pasting",
                detail: capturedTargetName.map { "Target: \($0)" } ?? "Inserting into current app",
                timerText: nil,
                systemImage: "arrow.down.doc",
                tone: .progress,
                primaryAction: nil
            )
        }
    }

    private var transcriptionDetail: String {
        switch transcriptProcessingMode {
        case .raw:
            "Groq · \(selectedModel)"
        case .cleanUp, .rewriteClearly:
            "Groq · cleanup next"
        }
    }

    private func errorDetail(for message: String, hasRetryableFailure: Bool) -> String {
        if message.localizedCaseInsensitiveContains("api key") {
            return "Add a Groq API key to transcribe"
        }
        if message.localizedCaseInsensitiveContains("accessibility") {
            return "Enable GroqTalk in Privacy & Security"
        }
        if message.localizedCaseInsensitiveContains("microphone") {
            return "Check Microphone privacy or audio input"
        }
        return hasRetryableFailure ? "Audio saved · Retry transcription" : "Open History for details"
    }

    private func errorAction(for message: String, hasRetryableFailure: Bool) -> SessionAction? {
        if message.localizedCaseInsensitiveContains("api key") {
            return .addKey
        }
        if message.localizedCaseInsensitiveContains("accessibility") {
            return .openAccessibility
        }
        if message.localizedCaseInsensitiveContains("microphone") {
            return .openMicrophone
        }
        return hasRetryableFailure ? .retry : nil
    }

    init() {
        let defaults = Self.defaults
        if ProcessInfo.processInfo.arguments.contains("--reset-defaults") {
            for key in [
                "soundEffectsEnabled",
                "whisperModel",
                "audioFormat",
                "keepOnClipboard",
                "showLiveFeedbackHUD",
                "showFloatingStatus",
                "asyncPasteEnabled",
                "experimentalSkyLightPasteEnabled",
                "mockTranscriptionEnabled",
                "recordingMode",
                "hotkeyChoice",
                "language",
                "transcriptProcessingMode",
                "transcriptCleanupModel",
                "selectedInputDeviceID"
            ] {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.register(defaults: [
            "soundEffectsEnabled": true,
            "whisperModel": "whisper-large-v3-turbo",
            "audioFormat": "m4a",
            "keepOnClipboard": false,
            "showFloatingStatus": false,
            "asyncPasteEnabled": false,
            "experimentalSkyLightPasteEnabled": false,
            "mockTranscriptionEnabled": false,
            "recordingMode": "hold",
            "hotkeyChoice": "rightCommand",
            "language": "auto",
            "transcriptProcessingMode": "raw",
            "transcriptCleanupModel": "llama-3.3-70b-versatile"
        ])

        // Load persisted values into stored properties.
        // didSet does NOT fire during init, so no redundant writes.
        soundEffectsEnabled = defaults.bool(forKey: "soundEffectsEnabled")
        selectedModel = defaults.string(forKey: "whisperModel") ?? "whisper-large-v3-turbo"
        selectedAudioFormat = AudioFormat(rawValue: defaults.string(forKey: "audioFormat") ?? "") ?? .m4a
        selectedLanguage = Language(rawValue: defaults.string(forKey: "language") ?? "") ?? .auto
        transcriptProcessingMode = TranscriptProcessingMode(rawValue: defaults.string(forKey: "transcriptProcessingMode") ?? "") ?? .raw
        transcriptCleanupModel = defaults.string(forKey: "transcriptCleanupModel") ?? "llama-3.3-70b-versatile"
        keepOnClipboard = defaults.bool(forKey: "keepOnClipboard")
        showFloatingStatus = defaults.bool(forKey: "showFloatingStatus")
        asyncPasteEnabled = defaults.bool(forKey: "asyncPasteEnabled")
        experimentalSkyLightPasteEnabled = defaults.bool(forKey: "experimentalSkyLightPasteEnabled")
        #if DEBUG
        mockTranscriptionEnabled = defaults.bool(forKey: "mockTranscriptionEnabled")
        #endif
        recordingMode = HotkeyMonitor.RecordingMode(rawValue: defaults.string(forKey: "recordingMode") ?? "") ?? .hold
        hotkeyChoice = HotkeyMonitor.HotkeyChoice(rawValue: defaults.string(forKey: "hotkeyChoice") ?? "") ?? .rightCommand
        let savedDevice = Self.defaults.object(forKey: "selectedInputDeviceID") as? UInt32
        selectedInputDeviceID = savedDevice
    }

    func setStatus(_ newStatus: Status) {
        status = newStatus
        switch newStatus {
        case .idle:
            transcriptionStage = nil
            break
        case .recording:
            transcriptionStage = nil
            floatingStatusDismissed = false
            floatingStatusTransientVisible = false
            transientResult = nil
            feedbackMessage = "Recording..."
            lastPasteSummary = nil
            clipboardFeedback = nil
        case .transcribing:
            floatingStatusDismissed = false
            floatingStatusTransientVisible = false
            transcriptionStage = transcriptionStage ?? .transcribingAudio
            feedbackMessage = "Sending audio..."
        case .error(let message):
            transcriptionStage = nil
            floatingStatusDismissed = false
            floatingStatusTransientVisible = false
            transientResult = nil
            feedbackMessage = message
        }
    }

    func showError(_ message: String) {
        status = .error(message)
        transcriptionStage = nil
        feedbackMessage = message
        transientResult = nil
        floatingStatusDismissed = false
        floatingStatusTransientVisible = false
    }

    func updateAccessibilityState(
        isTrusted: Bool,
        message: String = "Enable Accessibility"
    ) {
        accessibilityState = isTrusted
            ? .ready
            : .needsAction(message)
    }

    func updateMicrophoneState(isReady: Bool, message: String = "Allow microphone access") {
        microphoneState = isReady ? .ready : .needsAction(message)
    }

    func refreshApiKeyState() {
        apiKeyState = hasApiKey ? .ready : .needsAction("Add Groq API key")
    }

    func startSetupCheck() {
        setupCheckState = .running
    }

    func completeSetupCheck() {
        setupCheckState = .passed(Date())
    }

    func failSetupCheck(_ message: String) {
        setupCheckState = .failed(message)
    }

    func clearError() {
        if case .error = status {
            status = .idle
        }
    }

    func recordPaste(_ delivery: PasteDelivery) {
        lastPasteSummary = delivery.userMessage
        feedbackMessage = delivery.userMessage
        clipboardFeedback = delivery == .clipboardFallback
            ? "Text is on the clipboard"
            : (keepOnClipboard ? "Text kept on clipboard" : "Clipboard restored")
        transientResult = delivery == .clipboardFallback ? .clipboardFallback : .pasted(delivery)
        floatingStatusDismissed = false
        floatingStatusTransientVisible = true
    }

    func recordTargetCapture(_ target: PasteTarget?) {
        if let target {
            capturedTargetName = target.appName.isEmpty ? "Unknown app" : target.appName
            feedbackMessage = "Target: \(capturedTargetName!)"
        } else if asyncPasteEnabled {
            capturedTargetName = nil
            feedbackMessage = "Target unavailable"
        } else {
            capturedTargetName = nil
        }
    }

    func clearTransientFeedback() {
        capturedTargetName = nil
        feedbackMessage = nil
        clipboardFeedback = nil
        transientResult = nil
        floatingStatusTransientVisible = false
        floatingStatusDismissed = false
    }

    func hideFloatingStatus() {
        floatingStatusDismissed = true
    }

    func expireTransientSuccess() {
        guard case .idle = status else { return }
        if case .pasted = transientResult {
            transientResult = nil
            floatingStatusTransientVisible = false
        }
    }
}
