import SwiftUI

@main
struct GroqTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appDelegate.appState)
        } label: {
            Image(systemName: appDelegate.appState.menuBarIcon)
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

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = TranscriptionService()
    private let textInserter = TextInserter()
    private let soundPlayer = SoundPlayer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire hotkey monitor
        hotkeyMonitor.onRecordingStarted = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try self.audioRecorder.startRecording()
                    self.appState.setStatus(.recording)
                    self.soundPlayer.playStartSound()
                } catch {
                    self.appState.showError("Microphone unavailable")
                }
            }
        }
        hotkeyMonitor.onRecordingStopped = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard let url = self.audioRecorder.stopRecording() else {
                    self.appState.setStatus(.idle)
                    return
                }
                self.soundPlayer.playStopSound()
                self.appState.setStatus(.transcribing)

                guard let apiKey = KeychainHelper.readApiKey() else {
                    self.appState.showError("No API key")
                    return
                }

                do {
                    let text = try await self.transcriptionService.transcribe(
                        audioFileURL: url, apiKey: apiKey, model: self.appState.selectedModel
                    )
                    await self.textInserter.insert(text: text)
                    self.appState.setStatus(.idle)
                } catch TranscriptionService.TranscriptionError.invalidApiKey {
                    self.appState.showError("Invalid API key")
                } catch TranscriptionService.TranscriptionError.fileTooLarge {
                    self.appState.showError("Recording too long")
                } catch TranscriptionService.TranscriptionError.apiError(let code, _) {
                    self.appState.showError("API error (\(code))")
                } catch let error as URLError where error.code == .notConnectedToInternet {
                    self.appState.showError("No internet connection")
                } catch {
                    self.appState.showError("Transcription failed")
                }

                try? FileManager.default.removeItem(at: url)
            }
        }
        hotkeyMonitor.onRecordingCancelled = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.audioRecorder.cancelRecording()
                self.appState.setStatus(.idle)
            }
        }
        startHotkeyMonitorWithRetry()
    }

    private func startHotkeyMonitorWithRetry() {
        if hotkeyMonitor.start() {
            appState.setStatus(.idle)
            return
        }

        // Prompt the user and show error
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        appState.setStatus(.error("Enable Accessibility in Settings"))

        // Poll until permission is granted, then start
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
