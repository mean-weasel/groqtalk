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
    var onOpenAccessibility: (() -> Void)?
    var onOpenMicrophone: (() -> Void)?
    var onRunSetupCheck: (() -> Void)?
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
                setupPanel
                feedbackPanel
                lastResultSection
                quickControls
            } else {
                embeddedSettings
            }
        }
        .accessibilityIdentifier("menu.controlCenter")
        .padding(14)
        .frame(width: 360)
        .onAppear {
            if !isUITesting {
                appState.refreshApiKeyState()
            }
        }
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
                    Toggle("Show floating status", isOn: $appState.showFloatingStatus)
                        .accessibilityIdentifier("menu.settings.floatingStatusToggle")
                    Toggle("Keep final text on clipboard", isOn: $appState.keepOnClipboard)
                        .accessibilityIdentifier("menu.settings.keepClipboardToggle")
                }

                settingsSection("Recording") {
                    permissionRow(
                        title: "Accessibility",
                        state: appState.accessibilityState,
                        actionTitle: "Open Settings",
                        recoveryDetail: "Open Privacy & Security and turn on GroqTalk.",
                        action: onOpenAccessibility
                    )
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
                    permissionRow(
                        title: "Groq API key",
                        state: appState.apiKeyState,
                        actionTitle: "Change",
                        recoveryDetail: "Add your Groq API key to enable transcription.",
                        action: { openWindow(id: "api-key-setup") }
                    )
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

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Setup")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Label(
                    appState.needsSetupAttention ? "Needs attention" : "Ready",
                    systemImage: appState.needsSetupAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(appState.needsSetupAttention ? .orange : .green)
                .accessibilityIdentifier("menu.setup.summary")
            }

            permissionRow(
                title: "Accessibility",
                state: appState.accessibilityState,
                actionTitle: "Open Settings",
                recoveryDetail: "Open Privacy & Security and turn on GroqTalk.",
                action: onOpenAccessibility
            )
            permissionRow(
                title: "Microphone",
                state: appState.microphoneState,
                actionTitle: "Open Settings",
                recoveryDetail: "Open Microphone privacy and allow GroqTalk.",
                action: onOpenMicrophone
            )
            permissionRow(
                title: "Groq API key",
                state: appState.apiKeyState,
                actionTitle: "Add Key",
                recoveryDetail: "Add your Groq API key to enable transcription.",
                action: { openWindow(id: "api-key-setup") }
            )

            Divider()
                .opacity(0.5)

            setupCheckRow
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("menu.setup.panel")
    }

    private var setupCheckRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(setupCheckTitle, systemImage: setupCheckIcon)
                    .foregroundStyle(setupCheckColor)
                    .accessibilityIdentifier("menu.setup.test.label")
                Spacer()
                Text(setupCheckDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("menu.setup.test.state")
                Button(setupCheckButtonTitle) {
                    onRunSetupCheck?()
                }
                .buttonStyle(.borderless)
                .disabled(appState.isSetupCheckRunning)
                .accessibilityIdentifier("menu.setup.test.action")
            }
            .font(.caption)

            if let recoveryDetail = setupCheckRecoveryDetail {
                Text(recoveryDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu.setup.test.recovery")
            }
        }
    }

    private func permissionRow(
        title: String,
        state: AppState.PermissionState,
        actionTitle: String?,
        recoveryDetail: String,
        action: (() -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Label(title, systemImage: permissionIcon(for: state))
                    .foregroundStyle(permissionColor(for: state))
                    .accessibilityIdentifier("menu.setup.\(title).label")
                Spacer()
                Text(permissionText(for: state))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("menu.setup.\(title).state")
                if let actionTitle, let action {
                    Button(actionTitle) {
                        action()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("menu.setup.\(title).action")
                }
            }
            .font(.caption)

            if permissionNeedsRecovery(state) {
                Text(recoveryDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu.setup.\(title).recovery")
            }
        }
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

    private var feedbackPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let target = appState.capturedTargetName {
                Label("Target: \(target)", systemImage: "scope")
                    .accessibilityIdentifier("menu.feedback.target")
            } else if appState.asyncPasteEnabled {
                Label("Target will be captured when recording starts", systemImage: "scope")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menu.feedback.targetHelp")
            }

            if let message = appState.feedbackMessage {
                Label(message, systemImage: feedbackIcon)
                    .accessibilityIdentifier("menu.feedback.message")
            }

            if let clipboard = appState.clipboardFeedback {
                Label(clipboard, systemImage: "clipboard")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("menu.feedback.clipboard")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
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
            Toggle("Show floating status", isOn: $appState.showFloatingStatus)
                .accessibilityIdentifier("menu.floatingStatusToggle")

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
        case .idle: appState.needsSetupAttention ? "Setup needed" : "Ready"
        case .recording: "Recording \(appState.formattedRecordingDuration)"
        case .transcribing: "Sending audio"
        case .error: "Needs attention"
        }
    }

    private var statusDetail: String {
        switch appState.status {
        case .idle:
            if appState.needsSetupAttention {
                return "Finish setup items below before recording."
            }
            return "\(hotkeyLabel) is ready. \(appState.asyncPasteEnabled ? "Original-app paste is on." : "Pastes into the current app.")"
        case .recording:
            return appState.recordingMode == .hold ? "Release \(hotkeyLabel) to transcribe." : "Press \(hotkeyLabel) again to stop."
        case .transcribing:
            return "Transcribing with Groq. Your result will paste automatically."
        case .error(let message):
            return message
        }
    }

    private var statusColor: Color {
        switch appState.status {
        case .idle: appState.needsSetupAttention ? .orange : .accentColor
        case .recording: .red
        case .transcribing: .blue
        case .error: .orange
        }
    }

    private var feedbackIcon: String {
        switch appState.status {
        case .idle:
            "checkmark.circle"
        case .recording:
            "record.circle"
        case .transcribing:
            "arrow.triangle.2.circlepath"
        case .error:
            "exclamationmark.triangle"
        }
    }

    private func permissionIcon(for state: AppState.PermissionState) -> String {
        switch state {
        case .ready:
            "checkmark.circle.fill"
        case .needsAction:
            "exclamationmark.triangle.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    private func permissionColor(for state: AppState.PermissionState) -> Color {
        switch state {
        case .ready:
            .green
        case .needsAction:
            .orange
        case .unknown:
            .secondary
        }
    }

    private func permissionText(for state: AppState.PermissionState) -> String {
        switch state {
        case .ready:
            "Ready"
        case .needsAction(let message):
            message
        case .unknown:
            "Not checked"
        }
    }

    private func permissionNeedsRecovery(_ state: AppState.PermissionState) -> Bool {
        if case .needsAction = state { return true }
        return false
    }

    private var setupCheckTitle: String {
        switch appState.setupCheckState {
        case .idle, .running:
            "Test Setup"
        case .passed:
            "Setup Tested"
        case .failed:
            "Setup Check Failed"
        }
    }

    private var setupCheckDetail: String {
        switch appState.setupCheckState {
        case .idle:
            "Run local check"
        case .running:
            "Checking..."
        case .passed:
            "Ready to record"
        case .failed(let message):
            message
        }
    }

    private var setupCheckButtonTitle: String {
        switch appState.setupCheckState {
        case .failed:
            "Retry"
        case .running:
            "Checking"
        default:
            "Test"
        }
    }

    private var setupCheckIcon: String {
        switch appState.setupCheckState {
        case .idle:
            "checklist"
        case .running:
            "arrow.triangle.2.circlepath"
        case .passed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var setupCheckColor: Color {
        switch appState.setupCheckState {
        case .passed:
            .green
        case .failed:
            .orange
        case .idle, .running:
            .secondary
        }
    }

    private var setupCheckRecoveryDetail: String? {
        guard case .failed(let message) = appState.setupCheckState else { return nil }
        if message.localizedCaseInsensitiveContains("api key") {
            return "Add a Groq API key, then run the setup test again."
        }
        if message.localizedCaseInsensitiveContains("accessibility") {
            return "Open Accessibility settings, enable GroqTalk, then rerun the test."
        }
        if message.localizedCaseInsensitiveContains("microphone") {
            return "Check Microphone privacy or audio input, then rerun the test."
        }
        return "Resolve the setup item above, then rerun the test."
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
