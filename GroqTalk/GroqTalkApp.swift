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

    private var recordingTimer: Timer?
    private var transcribingTimer: Timer?

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
        wireHotkeyMonitor()
        applyHotkeyConfig()
        startHotkeyMonitorWithRetry()
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
        guard let record = history.retryableRecord,
              let audioURL = record.audioFileURL else { return }

        appState.clearError()
        appState.setStatus(.transcribing)
        startTranscribingAnimation()

        Task {
            guard let apiKey = KeychainHelper.readApiKey() else {
                stopTranscribingAnimation()
                appState.showError("No API key")
                return
            }

            do {
                let text = try await transcriptionService.transcribe(
                    audioFileURL: audioURL,
                    apiKey: apiKey,
                    model: appState.selectedModel,
                    format: appState.selectedAudioFormat,
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

                guard let apiKey = KeychainHelper.readApiKey() else {
                    self.stopTranscribingAnimation()
                    self.history.addFailure(error: "No API key", audioFileURL: url)
                    self.appState.showError("No API key — set one via the menu")
                    return
                }

                do {
                    let text = try await self.transcriptionService.transcribe(
                        audioFileURL: url,
                        apiKey: apiKey,
                        model: self.appState.selectedModel,
                        format: self.appState.selectedAudioFormat,
                        language: self.appState.selectedLanguage
                    )
                    self.stopTranscribingAnimation()
                    self.history.addSuccess(text: text)
                    await self.textInserter.insert(
                        text: text,
                        keepOnClipboard: self.appState.keepOnClipboard
                    )
                    self.appState.setStatus(.idle)
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
}
