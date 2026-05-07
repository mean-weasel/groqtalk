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

    @Environment(\.openWindow) private var openWindow

    private var lastSuccess: TranscriptionRecord? {
        history.records.first { !$0.isFailure }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbarActions
            statusHeader
            lastResultSection
            quickControls
        }
        .accessibilityIdentifier("menu.controlCenter")
        .padding(14)
        .frame(width: 360)
    }

    private var toolbarActions: some View {
        HStack(spacing: 8) {
            Button {
                openHistory()
            } label: {
                Label("History", systemImage: "clock")
            }
            .accessibilityIdentifier("menu.historyButton")

            Button {
                openSettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("menu.settingsButton")

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
        if let onOpenSettings {
            onOpenSettings()
        } else {
            openWindow(id: "settings")
        }
    }
}
