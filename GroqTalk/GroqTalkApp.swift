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
            ApiKeySetupView()
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
    static let automationMockSuccessNotification = Notification.Name("com.neonwatty.GroqTalk.automation.mockSuccess")

    let appState: AppState
    let history: TranscriptionHistory

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let textInserter = TextInserter()
    private let soundPlayer = SoundPlayer()

    private var pendingTarget: PasteTarget?
    private var pasteQueue: PasteQueue!

    private var recordingTimer: Timer?
    private var transcribingTimer: Timer?
    private var floatingStatusPanel: NSPanel?
    private var floatingStatusSyncTimer: Timer?
    private var transientSuccessAutoHideTimer: Timer?
    private var uiTestWindow: NSWindow?
    private var uiTestHistoryWindow: NSWindow?
    private var uiTestSettingsWindow: NSWindow?

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
        pasteQueue = PasteQueue { [weak self] text, target, keepOnClipboard in
            guard let self else { return .clipboardFallback }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                DiagnosticLog.write("UITest paste queue: route=asyncQueued target=\(target.appName) bytes=\(text.utf8.count)")
                return .asyncQueued
            }
            return await self.textInserter.insertAsync(text: text, target: target, keepOnClipboard: keepOnClipboard)
        }
        configureUITestingIfNeeded()
        configureAutomationSmokeIfNeeded()
        refreshSetupHealth()
        wireHotkeyMonitor()
        applyHotkeyConfig()
        startFloatingStatusSync()
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            appState.setStatus(.idle)
        } else {
            startHotkeyMonitorWithRetry()
        }
    }

    private func configureUITestingIfNeeded() {
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
            appState.lastPasteSummary = nil
            #if DEBUG
            appState.mockTranscriptionEnabled = false
            #endif
        }

        if args.contains("--seed-history") {
            history.clear()
            history.addSuccess(text: "Seeded transcript for UI testing.")
            history.addSuccess(text: "Second searchable transcript.")
            history.addFailure(error: "Seeded network failure", audioFileURL: nil)
        }

        showUITestWindow()
    }

    private func configureAutomationSmokeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("--automation-smoke") else { return }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(runAutomationMockSuccess),
            name: Self.automationMockSuccessNotification,
            object: nil
        )
        DiagnosticLog.write("automation smoke: enabled")
    }

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
            appState.setStatus(.transcribing)
            startTranscribingAnimation()
            try? await Task.sleep(for: .milliseconds(500))
            stopTranscribingAnimation()

            let text = "Mock transcription automation smoke"
            history.addSuccess(text: text)
            appState.setStatus(.idle)

            if let target,
               let delivery = await pasteQueue.enqueue(
                   text: text,
                   target: target,
                   keepOnClipboard: appState.keepOnClipboard
               ) {
                DiagnosticLog.write("ASYNC PATH: automation smoke pasted into \(target.appName) pid=\(target.pid)")
                recordPaste(delivery)
            } else {
                let delivery = await textInserter.insert(
                    text: text,
                    keepOnClipboard: appState.keepOnClipboard
                )
                recordPaste(delivery)
            }
        }
    }

    private func showUITestWindow() {
        let view = MenuBarView(
            appState: appState,
            history: history,
            onRetry: { [weak self] in self?.retryLast() },
            onPasteLast: { [weak self] in self?.pasteLastSuccess() },
            onHotkeyChanged: { [weak self] in self?.applyHotkeyConfig() },
            onOpenHistory: { [weak self] in self?.showUITestHistoryWindow() },
            onOpenSettings: { [weak self] in self?.showUITestSettingsWindow() },
            onOpenAccessibility: { [weak self] in self?.openAccessibilitySettings() },
            onOpenMicrophone: { [weak self] in self?.openMicrophoneSettings() },
            onRunSetupCheck: { [weak self] in self?.runSetupCheck() },
            onSimulateSuccess: { [weak self] in self?.simulateUITestTranscription(success: true) },
            onSimulateFailure: { [weak self] in self?.simulateUITestTranscription(success: false) }
        )
        .accessibilityIdentifier("uiTest.controlCenter")
        .frame(width: 360, height: 620)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GroqTalk UI Test"
        window.contentView = fixedHostingView(rootView: view, size: NSSize(width: 360, height: 620))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        uiTestWindow = window
    }

    private func showUITestHistoryWindow() {
        let view = HistoryPopoverView(
            history: history,
            onRetry: { [weak self] record in self?.retryRecord(record) },
            onPaste: { [weak self] text in self?.paste(text: text) },
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
            onHotkeyChanged: { [weak self] in self?.applyHotkeyConfig() }
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

    private func fixedHostingView<Content: View>(rootView: Content, size: NSSize) -> NSHostingView<Content> {
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hostingView.sizingOptions = []
        }
        return hostingView
    }

    // MARK: - Floating status

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
        let size = NSSize(width: 340, height: 132)
        let panel = NSPanel(
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
    }

    // MARK: - Hotkey configuration

    func applyHotkeyConfig() {
        hotkeyMonitor.configure(
            hotkeyChoice: appState.hotkeyChoice,
            recordingMode: appState.recordingMode
        )
    }

    // MARK: - Recording timer

    private func startRecordingTimer() {
        appState.recordingStartTime = Date()
        appState.recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.appState.recordingStartTime else { return }
                self.appState.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        appState.recordingStartTime = nil
        appState.recordingDuration = 0
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
            let delivery = await textInserter.insert(text: text, keepOnClipboard: appState.keepOnClipboard)
            recordPaste(delivery)
        }
    }

    func simulateUITestTranscription(success: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        Task { @MainActor in
            appState.clearError()
            appState.setStatus(.recording)
            startRecordingTimer()
            try? await Task.sleep(for: .milliseconds(300))
            stopRecordingTimer()
            appState.setStatus(.transcribing)
            startTranscribingAnimation()
            try? await Task.sleep(for: .milliseconds(800))
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
                    if let delivery = await pasteQueue.enqueue(
                        text: text,
                        target: target,
                        keepOnClipboard: appState.keepOnClipboard
                    ) {
                        recordPaste(delivery)
                    }
                } else {
                    let delivery = await textInserter.insert(
                        text: text,
                        keepOnClipboard: appState.keepOnClipboard
                    )
                    recordPaste(delivery)
                }
            } else {
                history.addFailure(error: "Simulated transcription failure", audioFileURL: nil)
                appState.showError("Simulated transcription failure")
            }
        }
    }

    // MARK: - Wiring

    private func wireHotkeyMonitor() {
        hotkeyMonitor.onRecordingStarted = { [weak self] in
            guard let self else { return }
            // Don't start a new recording while transcription is in-flight.
            // The CGEvent callback runs on the main run loop, so we can read
            // appState.status synchronously here.
            guard self.appState.status != .transcribing else {
                DiagnosticLog.write("onRecordingStarted: SKIPPED — transcription in flight")
                return
            }
            let asyncEnabled = self.appState.asyncPasteEnabled
            // Only capture on the FIRST press. If a debounce-cancel caused a
            // re-trigger, the user may have already moved — keep the original target.
            let capturedTarget: PasteTarget?
            if asyncEnabled && self.pendingTarget == nil {
                capturedTarget = PasteTarget.captureCurrentTarget()
            } else {
                capturedTarget = nil  // signal: don't overwrite
            }
            DiagnosticLog.write("onRecordingStarted: asyncEnabled=\(asyncEnabled) capturedTarget=\(String(describing: capturedTarget)) existingTarget=\(self.pendingTarget != nil)")
            Task { @MainActor in
                // Only set if we actually captured a new target
                if let target = capturedTarget {
                    self.pendingTarget = target
                }
                self.appState.recordTargetCapture(capturedTarget ?? self.pendingTarget)
                self.appState.clearError()
                do {
                    try self.audioRecorder.startRecording()
                    self.appState.updateMicrophoneState(isReady: true)
                    self.appState.setStatus(.recording)
                    self.startRecordingTimer()
                    self.soundPlayer.playStartSound()
                } catch {
                    self.appState.updateMicrophoneState(isReady: false, message: "Allow microphone access")
                    self.appState.showError("Microphone unavailable")
                }
            }
        }
        hotkeyMonitor.onRecordingStopped = { [weak self] in
            guard let self else { return }
            guard self.appState.status == .recording else {
                DiagnosticLog.write("onRecordingStopped: SKIPPED — not recording (status=\(self.appState.status))")
                return
            }
            DiagnosticLog.write("onRecordingStopped fired")
            Task { @MainActor in
                DiagnosticLog.write("onRecordingStopped Task executing")
                self.stopRecordingTimer()

                let url: URL
                do {
                    guard let recordedURL = try self.audioRecorder.stopRecording(
                        format: self.appState.selectedAudioFormat
                    ) else {
                        DiagnosticLog.write("onRecordingStopped: no audio file, returning")
                        self.appState.setStatus(.idle)
                        return
                    }
                    url = recordedURL
                } catch {
                    DiagnosticLog.write("onRecordingStopped: error \(error)")
                    self.appState.showError("Failed to save recording")
                    return
                }

                let useMockTranscription: Bool
                #if DEBUG
                useMockTranscription = self.appState.mockTranscriptionEnabled
                #else
                useMockTranscription = false
                #endif
                DiagnosticLog.write("transcription mode: mock=\(useMockTranscription)")

                self.soundPlayer.playStopSound()
                self.appState.setStatus(.transcribing)
                if useMockTranscription {
                    self.appState.feedbackMessage = "Mock transcription..."
                }
                self.startTranscribingAnimation()

                let apiKey: String?
                if useMockTranscription {
                    apiKey = nil
                } else {
                    guard let storedApiKey = KeychainHelper.readApiKey() else {
                        self.stopTranscribingAnimation()
                        self.appState.refreshApiKeyState()
                        self.history.addFailure(error: "No API key", audioFileURL: url)
                        self.appState.showError("No API key — set one via the menu")
                        return
                    }
                    apiKey = storedApiKey
                }

                do {
                    let text: String
                    if useMockTranscription {
                        try await Task.sleep(for: .seconds(2))
                        text = "Mock transcription at \(Date().formatted(date: .omitted, time: .standard))"
                    } else if let apiKey {
                        let rawText = try await self.transcriptionService.transcribe(
                            audioFileURL: url,
                            apiKey: apiKey,
                            model: self.appState.selectedModel,
                            format: self.appState.selectedAudioFormat,
                            language: self.appState.selectedLanguage
                        )
                        text = try await self.transcriptionService.processTranscript(
                            rawText,
                            apiKey: apiKey,
                            mode: self.appState.transcriptProcessingMode,
                            model: self.appState.transcriptCleanupModel
                        )
                    } else {
                        throw TranscriptionService.TranscriptionError.invalidResponse
                    }
                    self.stopTranscribingAnimation()
                    self.appState.feedbackMessage = "Transcription ready"
                    self.history.addSuccess(text: text)
                    self.appState.setStatus(.idle)

                    let asyncOn = self.appState.asyncPasteEnabled
                    let target = self.pendingTarget
                    self.pendingTarget = nil
                    DiagnosticLog.write("paste decision: asyncOn=\(asyncOn) target=\(String(describing: target))")

                    if asyncOn, let target {
                        DiagnosticLog.write("ASYNC PATH: pasting into \(target.appName) pid=\(target.pid)")
                        if let delivery = await self.pasteQueue.enqueue(
                            text: text, target: target,
                            keepOnClipboard: self.appState.keepOnClipboard
                        ) {
                            self.recordPaste(delivery)
                        }
                    } else {
                        DiagnosticLog.write("SYNC PATH: pasting into current app")
                        let delivery = await self.textInserter.insert(
                            text: text,
                            keepOnClipboard: self.appState.keepOnClipboard
                        )
                        self.recordPaste(delivery)
                    }
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    self.stopTranscribingAnimation()
                    self.pendingTarget = nil
                    let errorMsg = self.errorMessage(from: error)
                    self.history.addFailure(error: errorMsg, audioFileURL: url)
                    self.appState.showError(errorMsg)
                    // Do NOT delete audio file — preserved for retry
                }
            }
        }
        hotkeyMonitor.onRecordingCancelled = { [weak self] in
            guard let self else { return }
            DiagnosticLog.write("onRecordingCancelled")
            Task { @MainActor in
                self.stopRecordingTimer()
                self.audioRecorder.cancelRecording()
                self.appState.setStatus(.idle)
                self.appState.feedbackMessage = "Recording cancelled"
                // Do NOT clear pendingTarget here — a debounce-cancel is often
                // followed immediately by a new onRecordingStarted, and we want
                // to preserve the original capture from the first press.
                // pendingTarget is cleared after a successful paste or when
                // the transcription result is delivered.
            }
        }
    }

    private func errorMessage(from error: Error) -> String {
        switch error {
        case TranscriptionService.TranscriptionError.invalidApiKey:
            "Invalid API key"
        case TranscriptionService.TranscriptionError.fileTooLarge:
            "Recording too long"
        case TranscriptionService.TranscriptionError.apiError(let code, _):
            "API error (\(code))"
        case let urlError as URLError where urlError.code == .notConnectedToInternet:
            "No internet connection"
        case let urlError as URLError where urlError.code == .timedOut:
            "Request timed out"
        case let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost:
            "Cannot reach server"
        default:
            "Transcription failed: \(error.localizedDescription)"
        }
    }

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
            appState.showError("Failed to start hotkey monitor — restart GroqTalk")
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
                appState.showError("Failed to start — try restarting GroqTalk")
            }
        }
    }

    private func refreshSetupHealth() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
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
                let testRecordingURL = try audioRecorder.stopRecording(format: .wav)
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
            appState.showError("Recording file was deleted — cannot retry")
            return
        }
        // Infer format from the file extension to match the original recording
        let format = AudioFormat(rawValue: audioURL.pathExtension) ?? appState.selectedAudioFormat

        appState.clearError()
        appState.setStatus(.transcribing)
        appState.feedbackMessage = "Retrying transcription..."
        startTranscribingAnimation()

        Task {
            guard let apiKey = KeychainHelper.readApiKey() else {
                stopTranscribingAnimation()
                appState.showError("No API key — set one via the menu")
                return
            }

            do {
                let rawText = try await transcriptionService.transcribe(
                    audioFileURL: audioURL,
                    apiKey: apiKey,
                    model: appState.selectedModel,
                    format: format,
                    language: appState.selectedLanguage
                )
                let text = try await transcriptionService.processTranscript(
                    rawText,
                    apiKey: apiKey,
                    mode: appState.transcriptProcessingMode,
                    model: appState.transcriptCleanupModel
                )
                stopTranscribingAnimation()
                history.resolveRetry(id: record.id, text: text)
                let delivery = await textInserter.insert(text: text, keepOnClipboard: appState.keepOnClipboard)
                recordPaste(delivery)
                appState.setStatus(.idle)
            } catch {
                stopTranscribingAnimation()
                let errorMsg = errorMessage(from: error)
                history.resolveRetryFailure(id: record.id, error: errorMsg)
                appState.showError(errorMsg)
            }
        }
    }
}
