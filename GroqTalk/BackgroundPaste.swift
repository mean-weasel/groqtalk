import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Tier 1 async paste: invisible background text insertion.
///
/// Two approaches, tried in order:
/// 1. **AX text insertion** — directly sets the text value of the target
///    text area via Accessibility API. Works for native Cocoa apps without
///    any focus change. No clipboard involvement.
/// 2. **SkyLight CMD+V** — focus-without-raise + keyboard event injection.
///    Requires SkyLight SPIs and auth-signed event posting.
///
/// Returns true on success, false if unavailable or failed (caller
/// should fall back to Tier 2: window choreography).
struct BackgroundPaste {
    static func attempt(
        text: String,
        target: PasteTarget,
        keepOnClipboard: Bool
    ) async -> Bool {
        guard target.isValid else { return false }

        // Gate: target process must still be running
        guard let targetApp = NSRunningApplication(processIdentifier: target.pid),
              !targetApp.isTerminated
        else { return false }

        // --- Approach 1: AX text insertion ---
        if let window = target.windowElement,
           let textArea = findTextArea(in: window) {
            if insertViaAX(text: text, into: textArea) {
                if keepOnClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                DiagnosticLog.write("BackgroundPaste: AX insertion succeeded for \(target.appName)")
                return true
            }
        }

        // --- Approach 2: SkyLight focusWithoutRaise + CMD+V ---
        if SkyLightBridge.isAvailable,
           let targetWindowID = target.windowID {
            let success = await attemptSkyLightPaste(
                text: text, target: target,
                targetWindowID: targetWindowID,
                keepOnClipboard: keepOnClipboard
            )
            if success {
                DiagnosticLog.write("BackgroundPaste: SkyLight CMD+V succeeded for \(target.appName)")
                return true
            }
        }

        DiagnosticLog.write("BackgroundPaste: both approaches failed for \(target.appName)")
        return false
    }

    // MARK: - AX text insertion

    /// Insert text at the cursor position via AX API.
    /// Tries AXSelectedText first (insert at cursor), falls back to
    /// AXValue append.
    private static func insertViaAX(text: String, into textArea: AXUIElement) -> Bool {
        // Try 1: Replace selected text (inserts at cursor if no selection)
        let selectedResult = AXUIElementSetAttributeValue(
            textArea, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if selectedResult == .success { return true }

        // Try 2: Append to existing value
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(textArea, kAXValueAttribute as CFString, &valueRef)
        let currentText = (valueRef as? String) ?? ""
        let newText = currentText + text
        let valueResult = AXUIElementSetAttributeValue(
            textArea, kAXValueAttribute as CFString, newText as CFTypeRef
        )
        return valueResult == .success
    }

    /// Find a text area or text field within a window's AX tree.
    private static func findTextArea(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 20 else { return nil }

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if role == "AXTextArea" || role == "AXTextField" { return element }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                if let found = findTextArea(in: child, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    // MARK: - SkyLight CMD+V

    private static func attemptSkyLightPaste(
        text: String,
        target: PasteTarget,
        targetWindowID: CGWindowID,
        keepOnClipboard: Bool
    ) async -> Bool {
        guard let current = SkyLightBridge.currentFocus() else { return false }

        let pasteboard = NSPasteboard.general
        let saved = keepOnClipboard ? [] : savePasteboardContents(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let focused = SkyLightBridge.focusWithoutRaise(
            targetPid: target.pid, targetWindowID: targetWindowID
        )
        guard focused else {
            if !keepOnClipboard { restorePasteboardContents(pasteboard, saved: saved) }
            return false
        }

        // AX synthetic focus — sync AppKit's internal input routing
        if let window = target.windowElement {
            AXUIElementSetAttributeValue(
                window, kAXMainAttribute as CFString, true as CFTypeRef
            )
            AXUIElementSetAttributeValue(
                window, kAXFocusedAttribute as CFString, true as CFTypeRef
            )
        }

        try? await Task.sleep(for: .milliseconds(50))

        // Send CMD+V via auth-signed SkyLight path
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            if !SkyLightBridge.postKeyEventViaSkyLight(to: target.pid, event: keyDown) {
                keyDown.postToPid(target.pid)
            }
            if !SkyLightBridge.postKeyEventViaSkyLight(to: target.pid, event: keyUp) {
                keyUp.postToPid(target.pid)
            }
        }

        try? await Task.sleep(for: .milliseconds(100))

        let restored = SkyLightBridge.focusWithoutRaise(
            targetPid: current.pid, targetWindowID: current.windowID
        )
        if !restored {
            DiagnosticLog.write("BackgroundPaste: failed to restore focus to pid=\(current.pid)")
        }

        if !keepOnClipboard {
            restorePasteboardContents(pasteboard, saved: saved)
        }

        return true
    }

    // MARK: - Clipboard save/restore

    private static func savePasteboardContents(
        _ pb: NSPasteboard
    ) -> [(NSPasteboard.PasteboardType, Data)] {
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

    private static func restorePasteboardContents(
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
}
