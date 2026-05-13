import Carbon.HIToolbox
import SwiftUI

struct KeyRecorderView: View {
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @Binding var label: String
    @State private var isRecording = false

    var body: some View {
        HStack {
            Text(isRecording ? "Press a key..." : (label.isEmpty ? "Click to record" : label))
                .foregroundStyle(isRecording ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.3))
                )
                .onTapGesture { isRecording = true }
                .accessibilityIdentifier("settings.customHotkeyRecorder")
                .accessibilityLabel("Custom keyboard shortcut: \(label.isEmpty ? "not set" : label)")

            if !label.isEmpty {
                Button("Clear") {
                    keyCode = 0
                    modifiers = 0
                    label = ""
                }
                .accessibilityIdentifier("settings.clearHotkeyButton")
            }
        }
        .background(
            KeyEventCatcher(
                isRecording: $isRecording,
                keyCode: $keyCode,
                modifiers: $modifiers,
                label: $label
            )
        )
    }
}

// MARK: - NSViewRepresentable key event catcher

private struct KeyEventCatcher: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var keyCode: UInt16
    @Binding var modifiers: UInt64
    @Binding var label: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if isRecording {
            context.coordinator.startMonitoring()
        } else {
            context.coordinator.stopMonitoring()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: KeyEventCatcher
        var monitor: Any?

        init(_ parent: KeyEventCatcher) { self.parent = parent }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let kc = event.keyCode
                let mods = event.modifierFlags.rawValue & 0xFFFF_0000
                DispatchQueue.main.async {
                    self.parent.keyCode = kc
                    self.parent.modifiers = UInt64(mods)
                    self.parent.label = Self.labelFor(keyCode: kc, modifiers: event.modifierFlags)
                    self.parent.isRecording = false
                }
                return nil // consume the event
            }
        }

        func stopMonitoring() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        static func labelFor(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> String {
            var parts: [String] = []
            if modifiers.contains(.control) { parts.append("⌃") }
            if modifiers.contains(.option)  { parts.append("⌥") }
            if modifiers.contains(.shift)   { parts.append("⇧") }
            if modifiers.contains(.command) { parts.append("⌘") }

            switch Int(keyCode) {
            case kVK_Space:  parts.append("Space")
            case kVK_Return: parts.append("Return")
            case kVK_Tab:    parts.append("Tab")
            case kVK_Delete: parts.append("Delete")
            case kVK_Escape: parts.append("Escape")
            case kVK_F1:     parts.append("F1")
            case kVK_F2:     parts.append("F2")
            case kVK_F3:     parts.append("F3")
            case kVK_F4:     parts.append("F4")
            case kVK_F5:     parts.append("F5")
            case kVK_F6:     parts.append("F6")
            case kVK_F7:     parts.append("F7")
            case kVK_F8:     parts.append("F8")
            case kVK_F9:     parts.append("F9")
            case kVK_F10:    parts.append("F10")
            case kVK_F11:    parts.append("F11")
            case kVK_F12:    parts.append("F12")
            default:
                let source = CGEventSource(stateID: .combinedSessionState)
                if let cgEvent = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
                    var length = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    cgEvent.keyboardGetUnicodeString(
                        maxStringLength: 4,
                        actualStringLength: &length,
                        unicodeString: &chars
                    )
                    if length > 0 {
                        parts.append(String(utf16CodeUnits: chars, count: length).uppercased())
                    } else {
                        parts.append("Key \(keyCode)")
                    }
                } else {
                    parts.append("Key \(keyCode)")
                }
            }
            return parts.joined()
        }

        deinit { stopMonitoring() }
    }
}
