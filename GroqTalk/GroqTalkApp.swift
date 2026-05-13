import AVFoundation
import AppKit
import SwiftUI

@main
struct GroqTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                appState: appDelegate.appState,
                history: appDelegate.history,
                onRetry: { [weak appDelegate] in appDelegate?.retryLast() },
                onPasteLast: { [weak appDelegate] in appDelegate?.pasteLastSuccess() },
                onStartRecording: { [weak appDelegate] in appDelegate?.startRecordingFromControl() },
                onStopRecording: { [weak appDelegate] in appDelegate?.stopRecordingFromControl() },
                onCancelRecording: { [weak appDelegate] in appDelegate?.cancelRecordingFromControl() },
                onHotkeyChanged: { [weak appDelegate] in appDelegate?.applyHotkeyConfig() },
                onOpenAccessibility: { [weak appDelegate] in appDelegate?.openAccessibilitySettings() },
                onOpenMicrophone: { [weak appDelegate] in appDelegate?.openMicrophoneSettings() },
                onRunSetupCheck: { [weak appDelegate] in appDelegate?.runSetupCheck() }
            )
        } label: {
            appDelegate.menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Window("GroqTalk Setup", id: "api-key-setup") {
            ApiKeySetupView(
                onSaved: { [weak appDelegate] in
                    appDelegate?.appState.refreshApiKeyState()
                }
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("History", id: "history") {
            HistoryPopoverView(
                history: appDelegate.history,
                onRetry: { [weak appDelegate] record in appDelegate?.retryRecord(record) },
                onPaste: { [weak appDelegate] text in appDelegate?.paste(text: text) },
                showsHeader: true
            )
        }
        .defaultSize(width: 620, height: 560)

        Settings {
            SettingsView(
                appState: appDelegate.appState,
                history: appDelegate.history,
                onHotkeyChanged: { [weak appDelegate] in appDelegate?.applyHotkeyConfig() }
            )
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let history: TranscriptionHistory

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let textInserter = TextInserter()
    private let soundPlayer = SoundPlayer()

    private var retryingRecordID: UUID?

    private var sparkleUpdater: SparkleUpdater!
    private var recordingController: RecordingController!
    private var transcriptionController: TranscriptionController!
    private var pasteController: PasteController!
    private var transcribingTimer: Timer?
    private var floatingStatusPanel: NSPanel?
    private var floatingStatusSyncTimer: Timer?
    private var transientSuccessAutoHideTimer: Timer?
    private var uiTestingController: UITestingController?
    private var onboardingWindow: NSWindow?
    private var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    override init() {
        self.appState = AppState()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("GroqTalkUITests", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.history = TranscriptionHistory(storageDirectory: dir)
        } else {
            self.history = TranscriptionHistory()
        }
        super.init()
    }
    // MARK: - Menu bar label

    @ViewBuilder
    var menuBarLabel: some View {
        switch appState.status {
        case .recording:
            HStack(spacing: 4) {
                Image(systemName: "waveform.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.red, .red)
                Text(appState.formattedRecordingDuration)
                    .monospacedDigit()
            }
        case .transcribing:
            HStack(spacing: 4) {
                Image(systemName: appState.menuBarIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                Text("Sending")
            }
        case .error:
            Image(systemName: appState.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)
        case .idle:
            switch appState.transientResult {
            case .pasted:
                Image(systemName: appState.menuBarIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
            case .clipboardFallback:
                Image(systemName: appState.menuBarIcon)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
            case nil:
                Image(systemName: appState.menuBarIcon)
            }
        }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.write("applicationDidFinishLaunching")
        _ = SparkleUpdater.shared
        recordingController = RecordingController(audioRecorder: audioRecorder, appState: appState)
        recordingController.delegate = self
        transcriptionController = TranscriptionController(transcriptionService: transcriptionService, appState: appState)
        transcriptionController.delegate = self
        pasteController = PasteController(textInserter: textInserter, appState: appState)
        pasteController.delegate = self
        let uiTestingCtrl = UITestingController(
            appState: appState,
            history: history,
            pasteController: pasteController,
            startTranscribingAnimation: { [weak self] in self?.startTranscribingAnimation() },
            stopTranscribingAnimation: { [weak self] in self?.stopTranscribingAnimation() },
            onRetry: { [weak self] in self?.retryLast() },
            onPasteLast: { [weak self] in self?.pasteLastSuccess() },
            onStartRecording: { [weak self] in self?.startRecordingFromControl() },
            onStopRecording: { [weak self] in self?.stopRecordingFromControl() },
            onCancelRecording: { [weak self] in self?.cancelRecordingFromControl() },
            onHotkeyChanged: { [weak self] in self?.applyHotkeyConfig() },
            onOpenAccessibility: { [weak self] in self?.openAccessibilitySettings() },
            onOpenMicrophone: { [weak self] in self?.openMicrophoneSettings() },
            onRunSetupCheck: { [weak self] in self?.runSetupCheck() },
            onRetryRecord: { [weak self] record in self?.retryRecord(record) },
            onPasteText: { [weak self] text in self?.paste(text: text) }
        )
        uiTestingController = uiTestingCtrl
        uiTestingCtrl.configureUITestingIfNeeded()
        uiTestingCtrl.configureAutomationSmokeIfNeeded()
        refreshSetupHealth()
        wireHotkeyMonitor()
        applyHotkeyConfig()
        startFloatingStatusSync()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            appState.setStatus(.idle)
        } else {
            startHotkeyMonitorWithRetry()
        }
        if !hasCompletedOnboarding && !ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            showOnboarding()
        }
        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            Task { await NotificationManager.shared.requestAuthorization() }
        }
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView(appState: appState) { [weak self] in
            self?.hasCompletedOnboarding = true
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to GroqTalk"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    // MARK: - Floating status

    private final class FloatingStatusPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private func startFloatingStatusSync() {
        floatingStatusSyncTimer?.invalidate()
        floatingStatusSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.syncFloatingStatus()
            }
        }
        syncFloatingStatus()
    }

    private func syncFloatingStatus() {
        guard appState.shouldShowFloatingStatus else {
            floatingStatusPanel?.orderOut(nil)
            return
        }

        let panel = floatingStatusPanel ?? makeFloatingStatusPanel()
        if floatingStatusPanel == nil {
            floatingStatusPanel = panel
        }
        positionFloatingStatusPanel(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func makeFloatingStatusPanel() -> NSPanel {
        let size = NSSize(width: 340, height: 96)
        let panel = FloatingStatusPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "GroqTalk Floating Status"
        panel.setAccessibilityIdentifier("floatingStatus.window")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(
            rootView: FloatingStatusView(
                appState: appState,
                onDismiss: { [weak self] in
                    self?.appState.hideFloatingStatus()
                    self?.syncFloatingStatus()
                }
            )
        )
        return panel
    }

    private func positionFloatingStatusPanel(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { screen in
            screen.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main

        guard let visibleFrame = screen?.visibleFrame else { return }
        let margin: CGFloat = 18
        let size = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.maxX - size.width - margin,
            y: visibleFrame.maxY - size.height - margin
        )
        panel.setFrameOrigin(origin)
    }

    private func recordPaste(_ delivery: PasteDelivery) {
        appState.recordPaste(delivery)
        if delivery != .clipboardFallback {
            scheduleTransientSuccessAutoHide()
        }
    }

    private func scheduleTransientSuccessAutoHide() {
        transientSuccessAutoHideTimer?.invalidate()
        transientSuccessAutoHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.appState.expireTransientSuccess()
                self?.syncFloatingStatus()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        floatingStatusSyncTimer?.invalidate()
        transientSuccessAutoHideTimer?.invalidate()
        recordingController?.invalidateTimers()
    }

    // MARK: - Hotkey configuration

    func applyHotkeyConfig() {
        hotkeyMonitor.configure(
            hotkeyChoice: appState.hotkeyChoice,
            recordingMode: appState.recordingMode
        )
        if appState.hotkeyChoice == .custom {
            hotkeyMonitor.configureCustomKey(
                keyCode: appState.customHotkeyKeyCode,
                modifiers: appState.customHotkeyModifiers
            )
        }
    }

    // MARK: - Transcribing animation

    private func startTranscribingAnimation() {
        appState.transcribingIconFrame = 0
        transcribingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appState.transcribingIconFrame = (self.appState.transcribingIconFrame + 1) % 2
            }
        }
    }

    private func stopTranscribingAnimation() {
        transcribingTimer?.invalidate()
        transcribingTimer = nil
        appState.transcribingIconFrame = 0
    }

    // MARK: - Retry

    func retryLast() {
        guard let record = history.retryableRecord else { return }
        retryRecord(record)
    }

    func pasteLastSuccess() {
        guard let text = history.records.first(where: { !$0.isFailure })?.text else { return }
        paste(text: text)
    }

    func paste(text: String) {
        Task {
            await pasteController.pasteDirectly(text: text)
        }
    }

    func startRecordingFromControl() {
        captureTargetThenStartRecording()
    }

    func stopRecordingFromControl() {
        recordingController.stopRecording()
    }

    func cancelRecordingFromControl() {
        recordingController.cancelRecording()
    }

    // MARK: - Wiring

    private func wireHotkeyMonitor() {
        hotkeyMonitor.onRecordingStarted = { [weak self] in
            self?.captureTargetThenStartRecording()
        }
        hotkeyMonitor.onRecordingStopped = { [weak self] in
            self?.recordingController.stopRecording()
        }
        hotkeyMonitor.onRecordingCancelled = { [weak self] in
            self?.recordingController.cancelRecording()
        }
    }

    private func captureTargetThenStartRecording() {
        pasteController.captureTarget()
        let capturedTarget = pasteController.pendingTarget
        DiagnosticLog.write("captureTargetThenStartRecording: asyncEnabled=\(appState.asyncPasteEnabled) capturedTarget=\(String(describing: capturedTarget))")
        appState.recordTargetCapture(capturedTarget)
        appState.clearError()
        recordingController.startRecording()
    }

    // MARK: - Transcription flow (now delegated to TranscriptionController)

    private func startHotkeyMonitorWithRetry() {
        appState.refreshApiKeyState()
        appState.updateAccessibilityState(isTrusted: AXIsProcessTrusted())
        if hotkeyMonitor.start() {
            appState.updateAccessibilityState(isTrusted: true)
            appState.setStatus(.idle)
            return
        }

        guard !AXIsProcessTrusted() else {
            DiagnosticLog.write("HotkeyMonitor: start failed despite Accessibility trust")
            appState.updateAccessibilityState(isTrusted: false, message: "Restart GroqTalk")
            appState.showError("Failed to start hotkey monitor -- restart GroqTalk")
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        appState.updateAccessibilityState(isTrusted: false)
        appState.setStatus(.error("Enable Accessibility in Settings"))

        Task {
            while !AXIsProcessTrusted() {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
            }
            if hotkeyMonitor.start() {
                appState.updateAccessibilityState(isTrusted: true)
                appState.setStatus(.idle)
            } else {
                appState.updateAccessibilityState(isTrusted: false, message: "Restart GroqTalk")
                appState.showError("Failed to start -- try restarting GroqTalk")
            }
        }
    }

    private func refreshSetupHealth() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--seed-setup-unknown") {
                appState.accessibilityState = .unknown
                appState.microphoneState = .unknown
                appState.apiKeyState = .unknown
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--seed-setup-failures") {
                appState.updateAccessibilityState(isTrusted: false)
                appState.updateMicrophoneState(isReady: false)
                appState.apiKeyState = .needsAction("Add Groq API key")
                appState.failSetupCheck("Enable Accessibility")
                return
            }
            appState.updateAccessibilityState(isTrusted: true)
            appState.updateMicrophoneState(isReady: true)
            appState.apiKeyState = .ready
            return
        }
        appState.refreshApiKeyState()
        appState.updateAccessibilityState(isTrusted: AXIsProcessTrusted())
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            appState.updateMicrophoneState(isReady: true)
        case .denied, .restricted:
            appState.updateMicrophoneState(isReady: false, message: "Allow microphone access")
        case .notDetermined:
            appState.microphoneState = .unknown
        @unknown default:
            appState.microphoneState = .unknown
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func runSetupCheck() {
        guard !appState.isSetupCheckRunning else { return }
        guard appState.status == .idle || appState.isError else {
            appState.failSetupCheck("Wait until recording finishes")
            return
        }

        appState.startSetupCheck()

        Task { @MainActor in
            refreshSetupHealth()

            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                appState.completeSetupCheck()
                return
            }

            guard appState.hasApiKey else {
                appState.refreshApiKeyState()
                appState.failSetupCheck("Add Groq API key")
                return
            }

            guard let apiKey = KeychainHelper.readApiKey() else {
                appState.refreshApiKeyState()
                appState.failSetupCheck("Add Groq API key")
                return
            }

            do {
                let requiredModels = requiredModelsForSetupCheck()
                try await transcriptionService.validateApiKey(
                    apiKey: apiKey,
                    requiredModels: requiredModels
                )
                appState.apiKeyState = .ready
            } catch TranscriptionService.TranscriptionError.invalidApiKey {
                appState.apiKeyState = .needsAction("Invalid Groq API key")
                appState.failSetupCheck("Invalid Groq API key")
                return
            } catch {
                let message = transcriptionController.errorMessage(from: error)
                appState.failSetupCheck(message)
                return
            }

            guard AXIsProcessTrusted() else {
                appState.updateAccessibilityState(isTrusted: false)
                appState.failSetupCheck("Enable Accessibility")
                return
            }
            appState.updateAccessibilityState(isTrusted: true)

            let microphoneReady = await requestMicrophoneAccessIfNeeded()
            guard microphoneReady else {
                appState.updateMicrophoneState(isReady: false)
                appState.failSetupCheck("Allow microphone access")
                return
            }
            appState.updateMicrophoneState(isReady: true)

            do {
                try audioRecorder.startRecording()
                try await Task.sleep(for: .milliseconds(250))
                let testRecordingURL = try await audioRecorder.stopRecordingAsync(format: .wav)
                if let testRecordingURL {
                    try? FileManager.default.removeItem(at: testRecordingURL)
                }
                appState.completeSetupCheck()
            } catch is CancellationError {
                audioRecorder.cancelRecording()
                appState.failSetupCheck("Setup check cancelled")
            } catch {
                audioRecorder.cancelRecording()
                DiagnosticLog.write("setupCheck: microphone engine failed error=\(error.localizedDescription)")
                appState.failSetupCheck("Microphone unavailable")
            }
        }
    }

    private func requiredModelsForSetupCheck() -> [String] {
        var models = [appState.selectedModel]
        if appState.transcriptProcessingMode != .raw {
            models.append(appState.transcriptCleanupModel)
        }
        return Array(Set(models))
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func retryRecord(_ record: TranscriptionRecord) {
        guard appState.status == .idle || appState.isError else { return }
        guard let audioURL = record.audioFileURL else {
            appState.showError("Recording no longer available for retry")
            return
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            appState.showError("Recording file was deleted -- cannot retry")
            return
        }

        appState.clearError()
        appState.transcriptionStage = .transcribingAudio
        appState.setStatus(.transcribing)
        appState.feedbackMessage = "Retrying transcription..."
        startTranscribingAnimation()

        // Tag the record ID so TranscriptionControllerDelegate callbacks know this is a retry
        retryingRecordID = record.id
        Task { @MainActor in
            await transcriptionController.retryTranscription(record: record)
        }
    }
}

// MARK: - TranscriptionControllerDelegate

extension AppDelegate: TranscriptionControllerDelegate {
    func transcriptionController(
        _ controller: TranscriptionController,
        didStartTranscribing audioURL: URL
    ) {
        DiagnosticLog.write("AppDelegate: transcriptionController didStartTranscribing=\(audioURL.lastPathComponent)")
        // Only set transcribing state if we're not already in it (retry path sets it earlier)
        if appState.status != .transcribing {
            soundPlayer.playStopSound()
            appState.transcriptionStage = .transcribingAudio
            appState.setStatus(.transcribing)
            startTranscribingAnimation()
        }

        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            NotificationManager.shared.postTranscriptionStarted()
        }

        let useMockTranscription: Bool
        #if DEBUG
        useMockTranscription = appState.mockTranscriptionEnabled
        #else
        useMockTranscription = false
        #endif
        if useMockTranscription {
            appState.feedbackMessage = "Mock transcription..."
        }
    }

    func transcriptionController(
        _ controller: TranscriptionController,
        didTranscribe text: String,
        audioURL: URL,
        cleanupFailed: Bool
    ) {
        DiagnosticLog.write("AppDelegate: transcriptionController didTranscribe textLength=\(text.count) cleanupFailed=\(cleanupFailed)")
        stopTranscribingAnimation()
        appState.feedbackMessage = "Transcription ready"

        if let retryID = retryingRecordID {
            // Retry path: resolve the existing history record
            history.resolveRetry(id: retryID, text: text)
            retryingRecordID = nil
            appState.transcriptionStage = .pasting
            Task {
                await pasteController.pasteDirectly(text: text)
                if cleanupFailed {
                    appState.feedbackMessage = "Cleanup failed; raw transcript used"
                }
                if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
                    NotificationManager.shared.postTranscriptionComplete(preview: text)
                }
                appState.setStatus(.idle)
            }
        } else {
            // Normal flow: add new success record, handle paste routing
            history.addSuccess(text: text)

            DiagnosticLog.write("paste decision: delegating to pasteController asyncOn=\(appState.asyncPasteEnabled) pendingTarget=\(String(describing: pasteController.pendingTarget))")
            appState.transcriptionStage = .pasting

            Task {
                await pasteController.paste(text: text)
                if cleanupFailed {
                    appState.feedbackMessage = "Cleanup failed; raw transcript used"
                }
                if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
                    NotificationManager.shared.postTranscriptionComplete(preview: text)
                }
                appState.setStatus(.idle)
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }

    func transcriptionController(
        _ controller: TranscriptionController,
        didFail error: Error,
        errorMessage: String,
        audioURL: URL,
        format: AudioFormat
    ) {
        DiagnosticLog.write("AppDelegate: transcriptionController didFail errorMessage=\(errorMessage)")
        stopTranscribingAnimation()

        if let retryID = retryingRecordID {
            // Retry path: update the existing history record
            history.resolveRetryFailure(id: retryID, error: errorMessage)
            retryingRecordID = nil
        } else if error is NoApiKeyError {
            // No API key: clear pending state, don't preserve audio
            pasteController.clearPendingTarget()
            appState.refreshApiKeyState()
            try? FileManager.default.removeItem(at: audioURL)
            history.addFailure(error: "No API key", audioFileURL: nil)
        } else {
            // Normal failure: preserve audio for retry
            pasteController.clearPendingTarget()
            history.addFailure(error: errorMessage, audioFileURL: audioURL)
            // Do NOT delete audio file -- preserved for retry
        }

        appState.showError(errorMessage)
        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            NotificationManager.shared.postTranscriptionFailed(errorMessage: errorMessage)
        }
    }
}

// MARK: - RecordingControllerDelegate

extension AppDelegate: RecordingControllerDelegate {
    func recordingControllerDidStart(_ controller: RecordingController) {
        DiagnosticLog.write("AppDelegate: recordingControllerDidStart")
        appState.updateMicrophoneState(isReady: true)
        soundPlayer.playStartSound()
    }

    func recordingController(
        _ controller: RecordingController,
        didStopWithURL audioURL: URL,
        format: AudioFormat
    ) {
        DiagnosticLog.write("AppDelegate: recordingController didStopWithURL=\(audioURL.lastPathComponent)")
        Task { @MainActor in
            await transcriptionController.transcribe(audioURL: audioURL, format: format)
        }
    }

    func recordingControllerDidStopWithNoAudio(_ controller: RecordingController) {
        DiagnosticLog.write("AppDelegate: recordingControllerDidStopWithNoAudio")
        stopTranscribingAnimation()
        appState.setStatus(.idle)
    }

    func recordingControllerDidCancel(_ controller: RecordingController) {
        DiagnosticLog.write("AppDelegate: recordingControllerDidCancel")
        appState.setStatus(.idle)
        appState.feedbackMessage = "Recording cancelled"
        pasteController.clearPendingTarget()
    }

    func recordingController(_ controller: RecordingController, didFailWithError error: Error) {
        DiagnosticLog.write("AppDelegate: recordingController didFailWithError=\(error)")
        pasteController.clearPendingTarget()
        appState.updateMicrophoneState(isReady: false, message: "Allow microphone access")
        appState.showError("Microphone unavailable")
    }
}

// MARK: - PasteControllerDelegate

extension AppDelegate: PasteControllerDelegate {
    func pasteController(_ controller: PasteController, didPaste text: String, delivery: PasteDelivery) {
        recordPaste(delivery)
    }
}
