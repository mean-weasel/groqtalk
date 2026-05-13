import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    var history: TranscriptionHistory
    var onHotkeyChanged: (() -> Void)?

    @Environment(\.openWindow) private var openWindow
    @State private var isShowingClearHistoryConfirmation = false
    @State private var launchAtLoginManager = LaunchAtLoginManager()
    @State private var notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
    private var sparkleUpdater: SparkleUpdater { SparkleUpdater.shared }

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
                .accessibilityIdentifier("settings.tab.general")

            recordingSettings
                .tabItem { Label("Recording", systemImage: "mic") }
                .accessibilityIdentifier("settings.tab.recording")

            transcriptionSettings
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .accessibilityIdentifier("settings.tab.transcription")

            pasteSettings
                .tabItem { Label("Paste", systemImage: "text.cursor") }
                .accessibilityIdentifier("settings.tab.paste")

            privacySettings
                .tabItem { Label("Privacy", systemImage: "lock") }
                .accessibilityIdentifier("settings.tab.privacy")
        }
        .accessibilityIdentifier("settings.root")
        .scenePadding()
        .frame(width: 520, height: 360)
        .alert("Clear History?", isPresented: $isShowingClearHistoryConfirmation) {
            Button("Clear History", role: .destructive) {
                history.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes all stored transcripts and any retained failed-audio retry files from this Mac.")
        }
    }

    private var generalSettings: some View {
        Form {
            Toggle("Sound effects", isOn: $appState.soundEffectsEnabled)
                .accessibilityIdentifier("settings.soundEffectsToggle")
            Toggle("Show floating status", isOn: $appState.showFloatingStatus)
                .accessibilityIdentifier("settings.floatingStatusToggle")
            Toggle("Keep final text on clipboard", isOn: $appState.keepOnClipboard)
                .accessibilityIdentifier("settings.keepClipboardToggle")
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLoginManager.isEnabled },
                set: { launchAtLoginManager.setEnabled($0) }
            ))
            .accessibilityIdentifier("settings.launchAtLoginToggle")
            Toggle("Show Notifications", isOn: $notificationsEnabled)
                .accessibilityIdentifier("settings.notificationsToggle")
                .onChange(of: notificationsEnabled) { _, enabled in
                    UserDefaults.standard.set(enabled, forKey: "notificationsEnabled")
                    if enabled {
                        Task {
                            let granted = await NotificationManager.shared.requestAuthorization()
                            if !granted {
                                notificationsEnabled = false
                                UserDefaults.standard.set(false, forKey: "notificationsEnabled")
                            }
                        }
                    }
                }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { sparkleUpdater.automaticallyChecksForUpdates },
                    set: { sparkleUpdater.automaticallyChecksForUpdates = $0 }
                ))

                Button("Check for Updates…") {
                    sparkleUpdater.checkForUpdates()
                }
                .disabled(!sparkleUpdater.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
    }

    private var recordingSettings: some View {
        Form {
            Picker("Hotkey", selection: $appState.hotkeyChoice) {
                ForEach(HotkeyMonitor.HotkeyChoice.allCases, id: \.self) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .accessibilityIdentifier("settings.hotkeyPicker")
            .onChange(of: appState.hotkeyChoice) { _, _ in onHotkeyChanged?() }

            if appState.hotkeyChoice == .custom {
                KeyRecorderView(
                    keyCode: $appState.customHotkeyKeyCode,
                    modifiers: $appState.customHotkeyModifiers,
                    label: $appState.customHotkeyLabel
                )
                .onChange(of: appState.customHotkeyKeyCode) { _, _ in onHotkeyChanged?() }
            }

            Picker("Mode", selection: $appState.recordingMode) {
                Text("Hold to record").tag(HotkeyMonitor.RecordingMode.hold)
                Text("Toggle").tag(HotkeyMonitor.RecordingMode.toggle)
            }
            .accessibilityIdentifier("settings.recordingModePicker")
            .onChange(of: appState.recordingMode) { _, _ in onHotkeyChanged?() }

            Picker("Audio format", selection: $appState.selectedAudioFormat) {
                Text("M4A").tag(AudioFormat.m4a)
                Text("WAV").tag(AudioFormat.wav)
                Text("FLAC").tag(AudioFormat.flac)
            }

            Picker("Language", selection: $appState.selectedLanguage) {
                ForEach(Language.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Picker("Input Device", selection: $appState.selectedInputDeviceUID) {
                Text("System Default").tag(nil as String?)
                ForEach(AudioRecorder.availableInputDevices()) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .accessibilityIdentifier("settings.inputDevicePicker")
        }
        .formStyle(.grouped)
    }

    private var transcriptionSettings: some View {
        Form {
            HStack {
                Text("Groq API key")
                Spacer()
                Label(appState.hasApiKey ? "Saved" : "Missing", systemImage: appState.hasApiKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(appState.hasApiKey ? .green : .orange)
                Button("Change...") {
                    openWindow(id: "api-key-setup")
                }
                .accessibilityIdentifier("settings.changeApiKeyButton")
            }

            Picker("Whisper model", selection: $appState.selectedModel) {
                Text("Large V3 Turbo").tag("whisper-large-v3-turbo")
                Text("Large V3").tag("whisper-large-v3")
            }

            Picker("After transcription", selection: $appState.transcriptProcessingMode) {
                ForEach(TranscriptProcessingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("settings.transcriptProcessingPicker")

            if appState.transcriptProcessingMode != .raw {
                Picker("Cleanup model", selection: $appState.transcriptCleanupModel) {
                    Text("Llama 3.3 70B Versatile").tag("llama-3.3-70b-versatile")
                    Text("Llama 3.1 8B Instant").tag("llama-3.1-8b-instant")
                }
                .accessibilityIdentifier("settings.cleanupModelPicker")
            }

            #if DEBUG
            Toggle("Mock transcription", isOn: $appState.mockTranscriptionEnabled)
                .accessibilityIdentifier("settings.mockToggle")
            #endif
        }
        .formStyle(.grouped)
    }

    private var pasteSettings: some View {
        Form {
            Toggle("Paste where recording started", isOn: $appState.asyncPasteEnabled)
                .accessibilityIdentifier("settings.asyncPasteToggle")
            Text(appState.asyncPasteEnabled ? "GroqTalk captures the target app when recording starts and returns focus after pasting." : "GroqTalk pastes into the app that is active when transcription finishes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Experimental background paste", isOn: $appState.experimentalSkyLightPasteEnabled)
                .accessibilityIdentifier("settings.experimentalSkyLightPasteToggle")
            Text("Uses private macOS paste routing when available. Leave off unless you are testing app-specific paste behavior.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Picker("History retention", selection: retentionBinding) {
                Text("Off").tag(0)
                Text("Last 100 records").tag(100)
                Text("Last 500 records").tag(500)
                Text("Last 1000 records").tag(1000)
            }
            .accessibilityIdentifier("settings.historyRetentionPicker")
            LabeledContent("Stored records", value: "\(history.records.count)")
            LabeledContent("Retained failed audio", value: "\(history.retainedFailedAudioCount)")
            Text("History is stored locally on this Mac. Successful audio files are deleted after transcription. When transcription fails, the failed audio may be retained locally only so you can retry it, and Clear History deletes those retained retry files.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Open App Data Folder") {
                    openAppDataFolder()
                }
                .accessibilityIdentifier("settings.openDataFolderButton")
                Button("Clear History", role: .destructive) {
                    isShowingClearHistoryConfirmation = true
                }
                .accessibilityIdentifier("settings.clearHistoryButton")
                .disabled(history.records.isEmpty)
                Button("Clear Failed Audio", role: .destructive) {
                    history.clearRetainedFailedAudio()
                }
                .accessibilityIdentifier("settings.clearRetainedAudioButton")
                .disabled(history.retainedFailedAudioCount == 0)
            }
        }
        .formStyle(.grouped)
    }

    private var retentionBinding: Binding<Int> {
        Binding(
            get: { history.isPersistenceEnabled ? history.retentionLimit : 0 },
            set: { value in
                if value == 0 {
                    history.isPersistenceEnabled = false
                } else {
                    history.isPersistenceEnabled = true
                    history.retentionLimit = value
                }
            }
        )
    }

    private func openAppDataFolder() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let dir = appSupport.appendingPathComponent("GroqTalk", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}
