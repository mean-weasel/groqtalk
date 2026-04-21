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
        // Check accessibility permission
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        // Wire hotkey monitor
        hotkeyMonitor.onRecordingStarted = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.appState.setStatus(.recording)
                self.soundPlayer.playStartSound()
                self.audioRecorder.startRecording()
            }
        }
        hotkeyMonitor.onRecordingStopped = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard let url = await self.audioRecorder.stopRecording() else {
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
                } catch {
                    self.appState.showError("Transcription failed")
                }

                try? FileManager.default.removeItem(at: url)
            }
        }
        hotkeyMonitor.onRecordingCancelled = { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.audioRecorder.cancelRecording()
                self.appState.setStatus(.idle)
            }
        }
        hotkeyMonitor.start()
    }
}
