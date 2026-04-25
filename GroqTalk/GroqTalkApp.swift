import SwiftUI

@main
struct GroqTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                appState: appDelegate.appState,
                history: appDelegate.history,
                onRetry: { [weak appDelegate] in appDelegate?.retryLast() },
                onHotkeyChanged: { [weak appDelegate] in appDelegate?.applyHotkeyConfig() }
            )
        } label: {
            appDelegate.menuBarLabel
        }

        Window("GroqTalk Setup", id: "api-key-setup") {
            ApiKeySetupView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let history = TranscriptionHistory()

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let textInserter = TextInserter()
    private let soundPlayer = SoundPlayer()

    private var pendingTarget: PasteTarget?
    private var pasteQueue: PasteQueue!

    private var recordingTimer: Timer?
    private var transcribingTimer: Timer?
    private var historyPopover: NSPopover?
    private var popoverObserver: Any?

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
        default:
            Image(systemName: appState.menuBarIcon)
        }
    }

    // MARK: - App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        pasteQueue = PasteQueue { [weak self] text, target, keepOnClipboard in
            guard let self else { return }
            await self.textInserter.insertAtTarget(text: text, target: target, keepOnClipboard: keepOnClipboard)
        }
        wireHotkeyMonitor()
        applyHotkeyConfig()
        startHotkeyMonitorWithRetry()
        setupHistoryPopover()
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

    // MARK: - Wiring

    private func wireHotkeyMonitor() {
        hotkeyMonitor.onRecordingStarted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.appState.clearError()
                do {
                    try self.audioRecorder.startRecording()
                    self.appState.setStatus(.recording)
                    self.startRecordingTimer()
                    self.soundPlayer.playStartSound()
                    if self.appState.asyncPasteEnabled {
                        self.pendingTarget = PasteTarget.captureCurrentTarget()
                    }
                } catch {
                    self.appState.showError("Microphone unavailable")
                }
            }
        }
        hotkeyMonitor.onRecordingStopped = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.stopRecordingTimer()

                let url: URL
                do {
                    guard let recordedURL = try self.audioRecorder.stopRecording(
                        format: self.appState.selectedAudioFormat
                    ) else {
                        self.appState.setStatus(.idle)
                        return
                    }
                    url = recordedURL
                } catch {
                    self.appState.showError("Failed to save recording")
                    return
                }

                self.soundPlayer.playStopSound()
                self.appState.setStatus(.transcribing)
                self.startTranscribingAnimation()

                #if !MOCK_TRANSCRIPTION
                guard let apiKey = KeychainHelper.readApiKey() else {
                    self.stopTranscribingAnimation()
                    self.history.addFailure(error: "No API key", audioFileURL: url)
                    self.appState.showError("No API key — set one via the menu")
                    return
                }
                #endif

                do {
                    let text: String
                    #if MOCK_TRANSCRIPTION
                    try await Task.sleep(for: .seconds(2))
                    text = "Mock transcription at \(Date().formatted(date: .omitted, time: .standard))"
                    #else
                    text = try await self.transcriptionService.transcribe(
                        audioFileURL: url,
                        apiKey: apiKey,
                        model: self.appState.selectedModel,
                        format: self.appState.selectedAudioFormat,
                        language: self.appState.selectedLanguage
                    )
                    #endif
                    self.stopTranscribingAnimation()
                    self.history.addSuccess(text: text)
                    self.appState.setStatus(.idle)

                    if self.appState.asyncPasteEnabled, let target = self.pendingTarget {
                        self.pendingTarget = nil
                        await self.pasteQueue.enqueue(
                            text: text, target: target,
                            keepOnClipboard: self.appState.keepOnClipboard
                        )
                    } else {
                        await self.textInserter.insert(
                            text: text,
                            keepOnClipboard: self.appState.keepOnClipboard
                        )
                    }
                    try? FileManager.default.removeItem(at: url)
                } catch {
                    self.stopTranscribingAnimation()
                    let errorMsg = self.errorMessage(from: error)
                    self.history.addFailure(error: errorMsg, audioFileURL: url)
                    self.appState.showError(errorMsg)
                    // Do NOT delete audio file — preserved for retry
                }
            }
        }
        hotkeyMonitor.onRecordingCancelled = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.stopRecordingTimer()
                self.audioRecorder.cancelRecording()
                self.appState.setStatus(.idle)
                self.pendingTarget = nil
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
        if hotkeyMonitor.start() {
            appState.setStatus(.idle)
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
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
                appState.setStatus(.idle)
            } else {
                appState.showError("Failed to start — try restarting GroqTalk")
            }
        }
    }

    // MARK: - History popover

    private func setupHistoryPopover() {
        popoverObserver = NotificationCenter.default.addObserver(
            forName: .showHistoryPopover, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.toggleHistoryPopover()
            }
        }
    }

    private func toggleHistoryPopover() {
        if let popover = historyPopover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: HistoryPopoverView(
                history: history,
                onRetry: { [weak self] record in
                    self?.retryRecord(record)
                }
            )
        )

        // Heuristic: find the status bar button to anchor the popover.
        // Relies on AppKit's internal view hierarchy and may fail if the structure changes.
        if let button = NSApp.windows
            .compactMap({ $0.contentView?.subviews.first as? NSStatusBarButton })
            .first {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.historyPopover = popover
        }
    }

    private func retryRecord(_ record: TranscriptionRecord) {
        guard appState.status == .idle || appState.isError else { return }
        guard let audioURL = record.audioFileURL else {
            appState.showError("Recording no longer available for retry")
            return
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            appState.showError("Recording file was deleted — cannot retry")
            return
        }
        historyPopover?.performClose(nil)

        // Infer format from the file extension to match the original recording
        let format = AudioFormat(rawValue: audioURL.pathExtension) ?? appState.selectedAudioFormat

        appState.clearError()
        appState.setStatus(.transcribing)
        startTranscribingAnimation()

        Task {
            guard let apiKey = KeychainHelper.readApiKey() else {
                stopTranscribingAnimation()
                appState.showError("No API key — set one via the menu")
                return
            }

            do {
                let text = try await transcriptionService.transcribe(
                    audioFileURL: audioURL,
                    apiKey: apiKey,
                    model: appState.selectedModel,
                    format: format,
                    language: appState.selectedLanguage
                )
                stopTranscribingAnimation()
                history.resolveRetry(id: record.id, text: text)
                await textInserter.insert(text: text, keepOnClipboard: appState.keepOnClipboard)
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
