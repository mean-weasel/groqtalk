import AppKit
import ApplicationServices
import CoreGraphics

struct TextInserter {
    @discardableResult
    func insert(text: String, keepOnClipboard: Bool = false) async -> PasteDelivery {
        DiagnosticLog.write("TextInserter.insert: route=currentApp bytes=\(text.utf8.count) keepOnClipboard=\(keepOnClipboard)")
        let pasteboard = NSPasteboard.general
        let saved = keepOnClipboard ? [] : Self.savePasteboardContents(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let restoreChangeCount = pasteboard.changeCount

        simulatePaste()

        try? await Task.sleep(for: .milliseconds(100))

        if !keepOnClipboard {
            Self.restorePasteboardContents(
                pasteboard,
                saved: saved,
                onlyIfChangeCount: restoreChangeCount
            )
        }
        return .currentAppCommandPosted
    }

    /// Paste text into a previously captured target window, then return focus
    /// to wherever the user is currently working.
    ///
    /// Flow: snapshot current app → activate target → paste → reactivate current app.
    @discardableResult
    func insertAtTarget(text: String, target: PasteTarget, keepOnClipboard: Bool) async -> PasteDelivery {
        let currentApp = NSWorkspace.shared.frontmostApplication

        guard let targetApp = NSRunningApplication(processIdentifier: target.pid),
              !targetApp.isTerminated else {
            // Target app is gone. Leave the transcript on the clipboard as the
            // recovery path even when normal successful pastes restore it.
            DiagnosticLog.write("TextInserter.insertAtTarget: route=clipboardFallback target=\(target.appName) pid=\(target.pid)")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return .clipboardFallback
        }

        // Activate the app first, then raise the specific window.
        // Some apps (terminals, browsers) need the app to be active before
        // AXRaise will take effect on a specific window.
        targetApp.activate()
        try? await Task.sleep(for: .milliseconds(50))

        if let window = target.windowElement {
            let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
            DiagnosticLog.write("insertAtTarget: AXRaise result=\(raiseResult.rawValue) window=\(window)")
        }

        try? await Task.sleep(for: .milliseconds(200))

        _ = await insert(text: text, keepOnClipboard: keepOnClipboard)

        try? await Task.sleep(for: .milliseconds(150))

        currentApp?.activate()
        return .asyncChoreography
    }

    /// Primary entry point for async paste. Tries verified AX background paste
    /// first, optionally tries experimental SkyLight command posting, then
    /// falls back to window choreography.
    @discardableResult
    func insertAsync(
        text: String,
        target: PasteTarget,
        keepOnClipboard: Bool,
        allowSkyLight: Bool = false
    ) async -> PasteDelivery {
        // Tier 1: background paste (invisible when verified AX succeeds).
        let backgroundResult = await BackgroundPaste.attempt(
            text: text,
            target: target,
            keepOnClipboard: keepOnClipboard,
            allowSkyLight: allowSkyLight
        )
        if backgroundResult == .verified {
            DiagnosticLog.write("insertAsync: Tier 1 (AX) verified for \(target.appName)")
            return .asyncBackground
        } else if backgroundResult == .commandPosted {
            DiagnosticLog.write("insertAsync: Tier 1 (SkyLight) command posted for \(target.appName)")
            return .asyncCommandPosted
        }

        // Tier 2: Window choreography (existing behavior)
        DiagnosticLog.write("insertAsync: falling back to Tier 2 (choreography) for \(target.appName)")
        return await insertAtTarget(text: text, target: target, keepOnClipboard: keepOnClipboard)
    }

    static func savePasteboardContents(_ pb: NSPasteboard) -> [(NSPasteboard.PasteboardType, Data)] {
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

    @discardableResult
    static func restorePasteboardContents(
        _ pb: NSPasteboard,
        saved: [(NSPasteboard.PasteboardType, Data)],
        onlyIfChangeCount expectedChangeCount: Int? = nil
    ) -> Bool {
        if let expectedChangeCount, pb.changeCount != expectedChangeCount {
            DiagnosticLog.write("TextInserter.restorePasteboardContents: skipped — pasteboard changed during paste delay")
            return false
        }
        pb.clearContents()
        guard !saved.isEmpty else { return true }
        let item = NSPasteboardItem()
        for (type, data) in saved {
            item.setData(data, forType: type)
        }
        pb.writeObjects([item])
        return true
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
