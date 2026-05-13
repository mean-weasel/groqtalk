import SwiftUI

struct FloatingStatusView: View {
    @Bindable var appState: AppState
    var onDismiss: (() -> Void)?

    private let dismissButtonSize: CGFloat = 28

    private var session: AppState.SessionPresentation {
        appState.sessionPresentation(
            hotkeyLabel: hotkeyLabel,
            hasRetryableFailure: false,
            hasLastSuccess: false
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(sessionColor.opacity(0.16))
                Image(systemName: session.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(sessionColor)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                        .accessibilityIdentifier("liveFeedback.title")

                    if let timerText = session.timerText {
                        Text(timerText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityIdentifier("liveFeedback.timer")
                    }

                    Spacer(minLength: 8)

                    if isDismissible {
                        dismissButton
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(session.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("liveFeedback.detail")

                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Transcribing")
                        .accessibilityIdentifier("liveFeedback.progress")
                }

                if let clipboard = appState.clipboardFeedback {
                    Label(clipboard, systemImage: "clipboard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("liveFeedback.clipboard")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(sessionColor.opacity(0.24), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("liveFeedback.hud")
    }

    private var dismissButton: some View {
        Button {
            onDismiss?()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: dismissButtonSize, height: dismissButtonSize)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Dismiss live feedback")
        .accessibilityIdentifier("liveFeedback.dismissButton")
        .accessibilitySortPriority(1)
        .keyboardShortcut(.cancelAction)
        .help("Dismiss live feedback")
    }

    private var sessionColor: Color {
        switch session.tone {
        case .neutral:
            .accentColor
        case .active:
            .red
        case .progress:
            .blue
        case .success:
            .green
        case .warning:
            .orange
        }
    }

    private var showsProgress: Bool {
        switch appState.status {
        case .transcribing:
            true
        default:
            false
        }
    }

    private var isDismissible: Bool {
        switch appState.status {
        case .idle, .error:
            true
        case .recording, .transcribing:
            false
        }
    }

    private var hotkeyLabel: String {
        switch appState.hotkeyChoice {
        case .rightCommand:
            "Right Command"
        case .rightOption:
            "Right Option"
        case .globeFn:
            "Globe/Fn"
        case .custom:
            appState.customHotkeyLabel.isEmpty ? "Custom" : appState.customHotkeyLabel
        }
    }
}
