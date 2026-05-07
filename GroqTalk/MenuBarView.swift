import AppKit
import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    var history: TranscriptionHistory
    var onRetry: (() -> Void)?
    var onPasteLast: (() -> Void)?
    var onHotkeyChanged: (() -> Void)?
    var onOpenHistory: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onSimulateSuccess: (() -> Void)?
    var onSimulateFailure: (() -> Void)?

    @State private var selectedPanel: Panel = .control

    @Environment(\.openWindow) private var openWindow

    private enum Panel {
        case control
        case settings
    }

    private var lastSuccess: TranscriptionRecord? {
        history.records.first { !$0.isFailure }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbarActions
            if selectedPanel == .control {
                statusHeader
                lastResultSection
                quickControls
            } else {
                embeddedSettings
            }
        }
        .accessibilityIdentifier("menu.controlCenter")
        .padding(14)
        .frame(width: 360)
    }

    private var toolbarActions: some View {
        HStack(spacing: 8) {
            Button {
                selectedPanel = .control
            } label: {
                Label("Control", systemImage: "waveform")
            }
            .accessibilityIdentifier("menu.controlButton")
            .foregroundStyle(selectedPanel == .control ? .primary : .secondary)

            Button {
                selectedPanel = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("menu.settingsButton")
            .foregroundStyle(selectedPanel == .settings ? .primary : .secondary)

            Button {
                openHistory()
            } label: {
                Image(systemName: "clock")
            }
            .accessibilityLabel("History")
            .accessibilityIdentifier("menu.historyButton")

            Spacer()

            if history.retryableRecord != nil {
                Button {
                    onRetry?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Retry Last Failure")
                .help("Retry Last Failure")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .accessibilityLabel("Quit GroqTalk")
            .help("Quit GroqTalk")
        }
        .buttonStyle(.borderless)
    }

    private var embeddedSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsSection("General") {
                    Toggle("Sound effects", isOn: $appState.soundEffectsEnabled)
                        .accessibilityIdentifier("menu.settings.soundEffectsToggle")
                    Toggle("Keep final text on clipboard", isOn: $appState.keepOnClipboard)
                        .accessibilityIdentifier("menu.settings.keepClipboardToggle")
                }

                settingsSection("Recording") {
                    Picker("Hotkey", selection: $appState.hotkeyChoice) {
                        Text("Right Command").tag(HotkeyMonitor.HotkeyChoice.rightCommand)
                        Text("Right Option").tag(HotkeyMonitor.HotkeyChoice.rightOption)
                        Text("Globe / Fn").tag(HotkeyMonitor.HotkeyChoice.globeFn)
                    }
                    .accessibilityIdentifier("menu.settings.hotkeyPicker")
                    .onChange(of: appState.hotkeyChoice) { _, _ in onHotkeyChanged?() }

                    Picker("Mode", selection: $appState.recordingMode) {
                        Text("Hold to record").tag(HotkeyMonitor.RecordingMode.hold)
                        Text("Toggle").tag(HotkeyMonitor.RecordingMode.toggle)
                    }
                    .accessibilityIdentifier("menu.settings.recordingModePicker")
                    .onChange(of: appState.recordingMode) { _, _ in onHotkeyChanged?() }

                    Picker("Audio format", selection: $appState.selectedAudioFormat) {
                        Text("M4A").tag(AudioFormat.m4a)
                        Text("WAV").tag(AudioFormat.wav)
                        Text("FLAC").tag(AudioFormat.flac)
                    }
                    .accessibilityIdentifier("menu.settings.audioFormatPicker")

                    Picker("Language", selection: $appState.selectedLanguage) {
                        ForEach(Language.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .accessibilityIdentifier("menu.settings.languagePicker")
                }

                settingsSection("Transcription") {
                    HStack {
                        Text("Groq API key")
                        Spacer()
                        Label(
                            appState.hasApiKey ? "Saved" : "Missing",
                            systemImage: appState.hasApiKey ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .foregroundStyle(appState.hasApiKey ? .green : .orange)
                    }

                    Button {
                        openWindow(id: "api-key-setup")
                    } label: {
                        Label("Change API Key", systemImage: "key")
                    }
                    .accessibilityIdentifier("menu.settings.changeApiKeyButton")

                    Picker("Whisper model", selection: $appState.selectedModel) {
                        Text("Large V3 Turbo").tag("whisper-large-v3-turbo")
                        Text("Large V3").tag("whisper-large-v3")
                    }
                    .accessibilityIdentifier("menu.settings.whisperModelPicker")

                    Picker("After transcription", selection: $appState.transcriptProcessingMode) {
                        ForEach(TranscriptProcessingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("menu.settings.transcriptProcessingPicker")

                    if appState.transcriptProcessingMode != .raw {
                        Picker("Cleanup model", selection: $appState.transcriptCleanupModel) {
                            Text("Llama 3.3 70B Versatile").tag("llama-3.3-70b-versatile")
                            Text("Llama 3.1 8B Instant").tag("llama-3.1-8b-instant")
                        }
                        .accessibilityIdentifier("menu.settings.cleanupModelPicker")
                    }

                    #if DEBUG
                    Toggle("Mock Transcription", isOn: $appState.mockTranscriptionEnabled)
                        .accessibilityIdentifier("menu.settings.mockToggle")
                    #endif
                }

                settingsSection("Paste") {
                    Toggle("Paste where recording started", isOn: $appState.asyncPasteEnabled)
                        .accessibilityIdentifier("menu.settings.asyncPasteToggle")
                    Text(appState.asyncPasteEnabled ? "Captures the target app when recording starts and returns focus after pasting." : "Pastes into the app active when transcription finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsSection("Privacy") {
                    LabeledContent("History retention", value: "Last \(TranscriptionHistory.maxRecords) records")
                    LabeledContent("Stored records", value: "\(history.records.count)")

                    Button("Clear History", role: .destructive) {
                        history.clear()
                    }
                    .accessibilityIdentifier("menu.settings.clearHistoryButton")
                    .disabled(history.records.isEmpty)
                }
            }
            .padding(.trailing, 4)
        }
        .frame(maxHeight: 560)
        .accessibilityIdentifier("menu.settingsPanel")
    }

    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.menuBarIcon)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("menu.status.title")
                Text(statusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("menu.status.detail")
            }

            Spacer()
        }
    }

    private var lastResultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Result")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    openHistory()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("menu.lastResult.openHistoryButton")
                .buttonStyle(.borderless)
                .help("Open History")
            }

            if let record = lastSuccess, let text = record.text {
                Text(text)
                    .font(.body)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("menu.lastResult.text")

                HStack {
                    Button {
                        copy(text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("menu.lastResult.copyButton")
                    Button {
                        onPasteLast?()
                    } label: {
                        Label("Paste Again", systemImage: "arrow.turn.down.left")
                    }
                    .accessibilityIdentifier("menu.lastResult.pasteAgainButton")
                    Spacer()
                    Text(record.relativeTimestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Text("No successful transcriptions yet.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("menu.lastResult.empty")
            }

            if let summary = appState.lastPasteSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menu.lastPaste.summary")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Controls")
                .font(.subheadline.weight(.semibold))

            Picker("Recording", selection: $appState.recordingMode) {
                Text("Hold").tag(HotkeyMonitor.RecordingMode.hold)
                Text("Toggle").tag(HotkeyMonitor.RecordingMode.toggle)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("menu.recordingModePicker")
            .onChange(of: appState.recordingMode) { _, _ in onHotkeyChanged?() }

            Toggle("Paste where recording started", isOn: $appState.asyncPasteEnabled)
                .accessibilityIdentifier("menu.asyncPasteToggle")
            Toggle("Keep final text on clipboard", isOn: $appState.keepOnClipboard)
                .accessibilityIdentifier("menu.keepClipboardToggle")

            Picker("Cleanup", selection: $appState.transcriptProcessingMode) {
                ForEach(TranscriptProcessingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .accessibilityIdentifier("menu.transcriptProcessingPicker")

            #if DEBUG
            Toggle("Mock Transcription", isOn: $appState.mockTranscriptionEnabled)
                .accessibilityIdentifier("menu.mockToggle")
            #endif

            if isUITesting {
                HStack {
                    Button("Simulate Success") {
                        onSimulateSuccess?()
                    }
                    .accessibilityIdentifier("menu.simulateSuccessButton")

                    Button("Simulate Failure") {
                        onSimulateFailure?()
                    }
                    .accessibilityIdentifier("menu.simulateFailureButton")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var statusTitle: String {
        switch appState.status {
        case .idle: "Ready"
        case .recording: "Recording \(appState.formattedRecordingDuration)"
        case .transcribing: "Sending audio"
        case .error: "Needs attention"
        }
    }

    private var statusDetail: String {
        switch appState.status {
        case .idle:
            "\(hotkeyLabel) is ready. \(appState.asyncPasteEnabled ? "Original-app paste is on." : "Pastes into the current app.")"
        case .recording:
            appState.recordingMode == .hold ? "Release \(hotkeyLabel) to transcribe." : "Press \(hotkeyLabel) again to stop."
        case .transcribing:
            "Transcribing with Groq. Your result will paste automatically."
        case .error(let message):
            message
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: .accentColor
        case .recording: .red
        case .transcribing: .blue
        case .error: .orange
        }
    }

    private var hotkeyLabel: String {
        switch appState.hotkeyChoice {
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        case .globeFn: "Globe/Fn"
        }
    }

    private var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openHistory() {
        if let onOpenHistory {
            onOpenHistory()
        } else {
            openWindow(id: "history")
        }
    }

    private func openSettingsView() {
        selectedPanel = .settings
    }
}
