import AVFoundation
import AppKit
import SwiftUI

/// Encapsulates all UI-testing and automation-smoke helpers that were previously
/// inlined in AppDelegate.  Create one instance in `applicationDidFinishLaunching`
/// and call `configureUITestingIfNeeded()` / `configureAutomationSmokeIfNeeded()`.
@MainActor
final class UITestingController {

    // MARK: - Public constant

    static let automationMockSuccessNotification =
        Notification.Name("com.neonwatty.GroqTalk.automation.mockSuccess")

    // MARK: - Dependencies

    private let appState: AppState
    private let history: TranscriptionHistory
    private let pasteController: PasteController

    /// Starts the transcribing spinner animation in the host (AppDelegate).
    private let startTranscribingAnimation: () -> Void
    /// Stops the transcribing spinner animation in the host (AppDelegate).
    private let stopTranscribingAnimation: () -> Void

    // Callbacks used when building MenuBarView inside the test window.
    private let onRetry: () -> Void
    private let onPasteLast: () -> Void
    private let onStartRecording: () -> Void
    private let onStopRecording: () -> Void
    private let onCancelRecording: () -> Void
    private let onHotkeyChanged: () -> Void
    private let onOpenAccessibility: () -> Void
    private let onOpenMicrophone: () -> Void
    private let onRunSetupCheck: () -> Void
    private let onRetryRecord: (TranscriptionRecord) -> Void
    private let onPasteText: (String) -> Void
    private let onReplaceRecordingController: (RecordingController) -> Void

    // MARK: - Window storage

    private var uiTestWindow: NSWindow?
    private var uiTestHistoryWindow: NSWindow?
    private var uiTestSettingsWindow: NSWindow?

    // MARK: - Init

    init(
        appState: AppState,
        history: TranscriptionHistory,
        pasteController: PasteController,
        startTranscribingAnimation: @escaping () -> Void,
        stopTranscribingAnimation: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onPasteLast: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onCancelRecording: @escaping () -> Void,
        onHotkeyChanged: @escaping () -> Void,
        onOpenAccessibility: @escaping () -> Void,
        onOpenMicrophone: @escaping () -> Void,
        onRunSetupCheck: @escaping () -> Void,
        onRetryRecord: @escaping (TranscriptionRecord) -> Void,
        onPasteText: @escaping (String) -> Void,
        onReplaceRecordingController: @escaping (RecordingController) -> Void
    ) {
        self.appState = appState
        self.history = history
        self.pasteController = pasteController
        self.startTranscribingAnimation = startTranscribingAnimation
        self.stopTranscribingAnimation = stopTranscribingAnimation
        self.onRetry = onRetry
        self.onPasteLast = onPasteLast
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording
        self.onCancelRecording = onCancelRecording
        self.onHotkeyChanged = onHotkeyChanged
        self.onOpenAccessibility = onOpenAccessibility
        self.onOpenMicrophone = onOpenMicrophone
        self.onRunSetupCheck = onRunSetupCheck
        self.onRetryRecord = onRetryRecord
        self.onPasteText = onPasteText
        self.onReplaceRecordingController = onReplaceRecordingController
    }

    // MARK: - Configuration entry points

    func configureUITestingIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--ui-testing") else { return }

        if args.contains("--reset-defaults") {
            history.clear()
            appState.soundEffectsEnabled = true
            appState.keepOnClipboard = false
            appState.asyncPasteEnabled = false
            appState.selectedModel = "whisper-large-v3-turbo"
            appState.selectedAudioFormat = .m4a
            appState.selectedLanguage = .auto
            appState.transcriptProcessingMode = .raw
            appState.transcriptCleanupModel = "llama-3.3-70b-versatile"
            appState.hotkeyChoice = .rightCommand
            appState.recordingMode = .hold
            appState.showFloatingStatus = false
            appState.updateAccessibilityState(isTrusted: true)
            appState.updateMicrophoneState(isReady: true)
            appState.apiKeyState = .ready
            appState.experimentalSkyLightPasteEnabled = false
            appState.lastPasteSummary = nil
            #if DEBUG
            appState.mockTranscriptionEnabled = false
            #endif
        }

        if args.contains("--seed-setup-ready") {
            appState.updateAccessibilityState(isTrusted: true)
            appState.updateMicrophoneState(isReady: true)
            appState.apiKeyState = .ready
        }

        if args.contains("--seed-microphone-unknown") {
            appState.updateAccessibilityState(isTrusted: true)
            appState.microphoneState = .unknown
            appState.apiKeyState = .ready
        }

        if args.contains("--seed-microphone-denied") {
            appState.updateAccessibilityState(isTrusted: true)
            appState.updateMicrophoneState(isReady: false, message: "Allow microphone access")
            appState.apiKeyState = .ready
        }

        if args.contains("--seed-history") {
            history.clear()
            history.addSuccess(text: "Seeded transcript for UI testing.")
            history.addSuccess(text: "Second searchable transcript.")
            history.addFailure(error: "Seeded network failure", audioFileURL: nil)
        }

        if args.contains("--seed-local-provider") {
            appState.selectedTranscriptionProviderPresetID = .localWhisperCPP
        }

        if args.contains("--seed-invalid-custom-provider") {
            appState.selectedTranscriptionProviderPresetID = .customOpenAICompatible
            appState.customTranscriptionBaseURL = "file:///tmp/whisper"
            appState.customTranscriptionModel = "whisper-1"
        }

        if args.contains("--seed-custom-provider") {
            appState.selectedTranscriptionProviderPresetID = .customOpenAICompatible
            appState.customTranscriptionBaseURL = "http://127.0.0.1:9090/v1"
            appState.customTranscriptionModel = "tiny-test-model"
        }

        UserDefaults(suiteName: "com.neonwatty.GroqTalk.UITests")?.synchronize()

        showUITestWindow()
        configureLiveMicrophoneSmokeIfNeeded(args: args)
    }

    func configureAutomationSmokeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--automation-smoke") else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runAutomationMockSuccess),
            name: UITestingController.automationMockSuccessNotification,
            object: nil
        )
        DiagnosticLog.write("automation smoke: enabled")
    }

    // MARK: - E2E transcription

    func configureE2ETranscribeIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--e2e-transcribe") else { return }
        configureE2EProviderOverrides()

        let wavURL: URL
        if let envPath = ProcessInfo.processInfo.environment["E2E_WAV_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            wavURL = URL(fileURLWithPath: envPath)
            DiagnosticLog.write("E2E: using WAV from environment at \(wavURL.path)")
        } else if let bundleURL = Bundle.main.url(forResource: "e2e-test-audio", withExtension: "wav") {
            wavURL = bundleURL
            DiagnosticLog.write("E2E: using bundled WAV at \(wavURL.path)")
        } else {
            DiagnosticLog.write("E2E: no WAV file found — set E2E_WAV_PATH or include e2e-test-audio.wav in bundle")
            return
        }

        let stub = E2EAudioStub(fileURL: wavURL)
        let controller = RecordingController(audioRecorder: stub, appState: appState)
        onReplaceRecordingController(controller)

        appState.selectedAudioFormat = .wav

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            DiagnosticLog.write("E2E: starting simulated recording")
            onStartRecording()
            try? await Task.sleep(for: .milliseconds(200))
            DiagnosticLog.write("E2E: stopping simulated recording")
            onStopRecording()
        }
        #endif
    }

    private func configureE2EProviderOverrides() {
        let env = ProcessInfo.processInfo.environment
        if env["E2E_TRANSCRIPTION_PROVIDER"] == TranscriptionProviderID.openAICompatible.rawValue {
            appState.selectedTranscriptionProviderID = .openAICompatible
            appState.customTranscriptionBaseURL = env["E2E_TRANSCRIPTION_BASE_URL"] ?? appState.customTranscriptionBaseURL
            appState.customTranscriptionModel = env["E2E_TRANSCRIPTION_MODEL"] ?? appState.customTranscriptionModel
            appState.apiKeyState = .ready
            DiagnosticLog.write(
                "E2E: provider=openai-compatible baseURL=\(appState.customTranscriptionBaseURL) model=\(appState.customTranscriptionModel)"
            )
            return
        }

        appState.selectedTranscriptionProviderID = .groq
        if let model = env["E2E_TRANSCRIPTION_MODEL"], !model.isEmpty {
            appState.selectedModel = model
        }
        if env["E2E_API_KEY"]?.isEmpty == false {
            appState.apiKeyState = .ready
        } else {
            appState.refreshApiKeyState()
        }
        DiagnosticLog.write("E2E: provider=groq model=\(appState.selectedModel)")
    }

    // MARK: - Live microphone smoke

    private func configureLiveMicrophoneSmokeIfNeeded(args: [String]) {
        #if DEBUG
        guard args.contains("--live-microphone-smoke") else { return }

        let env = ProcessInfo.processInfo.environment
        let resultPath = env["LIVE_MICROPHONE_RESULT_PATH"] ?? "/tmp/groqtalk-live-microphone-result.txt"
        let duration = TimeInterval(env["LIVE_MICROPHONE_DURATION_SECONDS"] ?? "") ?? 2
        let signingIdentity = env["LIVE_MICROPHONE_SIGNING_IDENTITY"] ?? "unknown"
        try? FileManager.default.removeItem(atPath: resultPath)

        DiagnosticLog.write("live microphone smoke: starting duration=\(duration) resultPath=\(resultPath)")
        Task.detached {
            let recorder = AudioRecorder()
            let startedAt = Date()
            let appPath = Bundle.main.bundlePath
            let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            Self.writeLiveMicrophoneResult(
                path: resultPath,
                status: "started",
                detail: "Recorder start requested; waiting for stop result.",
                elapsed: 0,
                bytes: 0,
                appPath: appPath,
                signingIdentity: signingIdentity,
                microphonePermissionStatus: Self.microphonePermissionDescription(permissionStatus),
                recordingStarted: false,
                recordingStopped: false
            )
            do {
                try recorder.startRecording()
                Self.writeLiveMicrophoneResult(
                    path: resultPath,
                    status: "recording",
                    detail: "Recorder started; waiting to stop.",
                    elapsed: Date().timeIntervalSince(startedAt),
                    bytes: 0,
                    appPath: appPath,
                    signingIdentity: signingIdentity,
                    microphonePermissionStatus: Self.microphonePermissionDescription(permissionStatus),
                    recordingStarted: true,
                    recordingStopped: false
                )
                try await Task.sleep(for: .milliseconds(Int(duration * 1000)))
                guard let audioURL = try await recorder.stopRecordingAsync(format: .wav) else {
                    Self.writeLiveMicrophoneResult(
                        path: resultPath,
                        status: "fail",
                        detail: "No audio buffers were captured. Check microphone permission, selected input device, and input level.",
                        elapsed: Date().timeIntervalSince(startedAt),
                        bytes: 0,
                        appPath: appPath,
                        signingIdentity: signingIdentity,
                        microphonePermissionStatus: Self.microphonePermissionDescription(permissionStatus),
                        recordingStarted: true,
                        recordingStopped: true
                    )
                    return
                }
                let bytes = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? FileManager.default.removeItem(at: audioURL)
                Self.writeLiveMicrophoneResult(
                    path: resultPath,
                    status: bytes > 0 ? "pass" : "fail",
                    detail: bytes > 0 ? "Captured microphone audio." : "Captured audio file was empty.",
                    elapsed: Date().timeIntervalSince(startedAt),
                    bytes: bytes,
                    appPath: appPath,
                    signingIdentity: signingIdentity,
                    microphonePermissionStatus: Self.microphonePermissionDescription(permissionStatus),
                    recordingStarted: true,
                    recordingStopped: true
                )
            } catch {
                recorder.cancelRecording()
                Self.writeLiveMicrophoneResult(
                    path: resultPath,
                    status: "fail",
                    detail: "Recorder failed: \(error.localizedDescription)",
                    elapsed: Date().timeIntervalSince(startedAt),
                    bytes: 0,
                    appPath: appPath,
                    signingIdentity: signingIdentity,
                    microphonePermissionStatus: Self.microphonePermissionDescription(permissionStatus),
                    recordingStarted: false,
                    recordingStopped: false
                )
            }
        }
        #endif
    }

    nonisolated private static func writeLiveMicrophoneResult(
        path: String,
        status: String,
        detail: String,
        elapsed: TimeInterval,
        bytes: Int,
        appPath: String,
        signingIdentity: String,
        microphonePermissionStatus: String,
        recordingStarted: Bool,
        recordingStopped: Bool
    ) {
        let body = [
            "status=\(status)",
            "app_path=\(appPath)",
            "signing_identity=\(signingIdentity)",
            "microphone_permission_status=\(microphonePermissionStatus)",
            "recording_started=\(recordingStarted)",
            "recording_stopped=\(recordingStopped)",
            "bytes=\(bytes)",
            "elapsed_seconds=\(String(format: "%.3f", elapsed))",
            "detail=\(detail)"
        ].joined(separator: "\n") + "\n"
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
        DiagnosticLog.write("live microphone smoke: \(body.replacingOccurrences(of: "\n", with: " "))")
    }

    nonisolated private static func microphonePermissionDescription(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            "authorized"
        case .denied:
            "denied"
        case .restricted:
            "restricted"
        case .notDetermined:
            "not_determined"
        @unknown default:
            "unknown"
        }
    }

    // MARK: - Automation smoke

    @objc private func runAutomationMockSuccess() {
        let target = PasteTarget.captureCurrentTarget()
        DiagnosticLog.write("automation smoke: requested target=\(String(describing: target))")
        Task { @MainActor in
            appState.asyncPasteEnabled = true
            appState.recordTargetCapture(target)
            #if DEBUG
            appState.mockTranscriptionEnabled = true
            #endif
            appState.clearError()
            appState.transcriptionStage = .transcribingAudio
            appState.setStatus(.transcribing)
            startTranscribingAnimation()
            try? await Task.sleep(for: .milliseconds(500))
            stopTranscribingAnimation()

            let text = "Mock transcription automation smoke"
            history.addSuccess(text: text)
            appState.setStatus(.idle)

            pasteController.setPendingTarget(target)
            if target != nil {
                DiagnosticLog.write("ASYNC PATH: automation smoke pasting via pasteController target=\(target!.appName) pid=\(target!.pid)")
            }
            await pasteController.paste(text: text)
        }
    }

    // MARK: - UI test windows

    private func showUITestWindow() {
        let view = MenuBarView(
            appState: appState,
            history: history,
            onRetry: onRetry,
            onPasteLast: onPasteLast,
            onStartRecording: onStartRecording,
            onStopRecording: onStopRecording,
            onCancelRecording: onCancelRecording,
            onHotkeyChanged: onHotkeyChanged,
            onOpenHistory: { [weak self] in self?.showUITestHistoryWindow() },
            onOpenSettings: { [weak self] in self?.showUITestSettingsWindow() },
            onOpenAccessibility: onOpenAccessibility,
            onOpenMicrophone: onOpenMicrophone,
            onCheckMicrophone: { [weak self] in self?.appState.updateMicrophoneState(isReady: true) },
            onRunSetupCheck: onRunSetupCheck,
            onSimulateSuccess: { [weak self] in self?.simulateUITestTranscription(success: true) },
            onSimulateFailure: { [weak self] in self?.simulateUITestTranscription(success: false) }
        )
        .accessibilityIdentifier("uiTest.controlCenter")
        .frame(width: 460, height: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GroqTalk UI Test"
        window.contentView = fixedHostingView(rootView: view, size: NSSize(width: 460, height: 620))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        uiTestWindow = window
    }

    private func showUITestHistoryWindow() {
        let view = HistoryPopoverView(
            history: history,
            onRetry: { [weak self] record in self?.onRetryRecord(record) },
            onPaste: { [weak self] text in self?.onPasteText(text) },
            showsHeader: true
        )
        .accessibilityIdentifier("history.testHost")
        .frame(width: 620, height: 560)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History"
        window.contentView = fixedHostingView(rootView: view, size: NSSize(width: 620, height: 560))
        window.center()
        window.makeKeyAndOrderFront(nil)
        uiTestHistoryWindow = window
    }

    private func showUITestSettingsWindow() {
        let view = SettingsView(
            appState: appState,
            history: history,
            onHotkeyChanged: onHotkeyChanged
        )
        .accessibilityIdentifier("settings.testHost")
        .frame(width: 560, height: 400)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = fixedHostingView(rootView: view, size: NSSize(width: 560, height: 400))
        window.center()
        window.makeKeyAndOrderFront(nil)
        uiTestSettingsWindow = window
    }

    // MARK: - Simulate transcription (UI testing)

    func simulateUITestTranscription(success: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        Task { @MainActor in
            appState.clearError()
            appState.setStatus(.recording)
            // Use inline state mutation for the UI simulation -- does not go through RecordingController
            appState.recordingStartTime = Date()
            appState.recordingDuration = 0
            try? await Task.sleep(for: .milliseconds(300))
            appState.recordingStartTime = nil
            appState.recordingDuration = 0
            appState.transcriptionStage = .transcribingAudio
            appState.setStatus(.transcribing)
            startTranscribingAnimation()
            try? await Task.sleep(for: .milliseconds(1_200))
            appState.transcriptionStage = .cleaningTranscript
            try? await Task.sleep(for: .milliseconds(1_200))
            appState.transcriptionStage = .pasting
            try? await Task.sleep(for: .milliseconds(1_200))
            stopTranscribingAnimation()

            if success {
                let text = "Mock async paste transcript"
                history.addSuccess(text: text)
                appState.setStatus(.idle)
                if appState.asyncPasteEnabled {
                    let target = PasteTarget(
                        windowElement: nil,
                        windowID: nil,
                        pid: ProcessInfo.processInfo.processIdentifier,
                        appName: "GroqTalk UI Test"
                    )
                    appState.recordTargetCapture(target)
                    pasteController.setPendingTarget(target)
                    await pasteController.paste(text: text)
                } else {
                    await pasteController.pasteDirectly(text: text)
                }
            } else {
                history.addFailure(error: "Simulated transcription failure", audioFileURL: nil)
                appState.showError("Simulated transcription failure")
            }
        }
    }

    // MARK: - Helpers

    private func fixedHostingView<Content: View>(rootView: Content, size: NSSize) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        return hostingView
    }

}
