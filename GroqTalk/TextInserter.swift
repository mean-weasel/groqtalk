import AppKit
import ApplicationServices
import CoreGraphics

struct TextInserter {
    func insert(text: String, keepOnClipboard: Bool = false) async {
        let pasteboard = NSPasteboard.general
        let saved = keepOnClipboard ? [] : savePasteboardContents(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        try? await Task.sleep(for: .milliseconds(100))

        if !keepOnClipboard {
            restorePasteboardContents(pasteboard, saved: saved)
        }
    }

    /// Paste text into a previously captured target window, then return focus
    /// to wherever the user is currently working.
    ///
    /// Flow: snapshot current app → activate target → paste → reactivate current app.
    func insertAtTarget(text: String, target: PasteTarget, keepOnClipboard: Bool) async {
        // 1. Remember where the user is right now
        let currentApp = NSWorkspace.shared.frontmostApplication

        // 2. Activate the target app and raise the specific window
        guard let targetApp = NSRunningApplication(processIdentifier: target.pid),
              targetApp.isTerminated == false else {
            // Target app is gone — fall back to clipboard only
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }

        // Activate the app first, then forcefully raise the specific window.
        // Some apps (terminals, browsers) need the app to be active before
        // AXRaise will take effect on a specific window.
        targetApp.activate()
        try? await Task.sleep(for: .milliseconds(50))

        if let window = target.windowElement {
            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            // Also try setting this as the main/focused window
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
            DiagnosticLog.write("insertAtTarget: AXRaise result=\(raiseResult.rawValue) window=\(window)")
        }

        // Wait for activation + window raise to settle
        try? await Task.sleep(for: .milliseconds(200))

        // 4. Paste using the existing mechanism
        await insert(text: text, keepOnClipboard: keepOnClipboard)

        // 5. Wait for paste to land
        try? await Task.sleep(for: .milliseconds(150))

        // 6. Return focus to where the user was
        currentApp?.activate()
    }

    /// Primary entry point for async paste. Tries SkyLight background
    /// paste (Tier 1), falls back to window choreography (Tier 2).
    func insertAsync(text: String, target: PasteTarget, keepOnClipboard: Bool) async {
        // Tier 1: SkyLight background paste (invisible)
        if await BackgroundPaste.attempt(
            text: text, target: target, keepOnClipboard: keepOnClipboard
        ) {
            DiagnosticLog.write("insertAsync: Tier 1 (SkyLight) succeeded for \(target.appName)")
            return
        }

        // Tier 2: Window choreography (existing behavior)
        DiagnosticLog.write("insertAsync: falling back to Tier 2 (choreography) for \(target.appName)")
        await insertAtTarget(text: text, target: target, keepOnClipboard: keepOnClipboard)
    }

    private func savePasteboardContents(_ pb: NSPasteboard) -> [(NSPasteboard.PasteboardType, Data)] {
        var saved: [(NSPasteboard.PasteboardType, Data)] = []
        guard let items = pb.pasteboardItems else { return saved }
        for item in items {
            for type in item.types {
                if let data = item.data(forType: type) {
                    saved.append((type, data))
                }
            }
        }
        return saved
    }

    private func restorePasteboardContents(
        _ pb: NSPasteboard,
        saved: [(NSPasteboard.PasteboardType, Data)]
    ) {
        pb.clearContents()
        guard !saved.isEmpty else { return }
        let item = NSPasteboardItem()
        for (type, data) in saved {
            item.setData(data, forType: type)
        }
        pb.writeObjects([item])
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        // 0x09 is the virtual key code for "V"
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
