import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Tier 1 async paste: invisible background text insertion.
///
/// Two approaches, tried in order:
/// 1. **AX text insertion** — inserts into the focused editable element in
///    the captured target window. It does not guess at the first text field.
/// 2. **SkyLight CMD+V** — optional focus-without-raise + keyboard event
///    injection using private SPIs. This must be explicitly enabled.
///
/// Returns a verified result for direct AX insertion, a command-posted
/// result for SkyLight CMD+V, or failed so the caller can fall back to
/// Tier 2: window choreography.
struct BackgroundPaste {
    enum AttemptResult: Equatable {
        case failed
        case verified
        case commandPosted
    }

    static func attempt(
        text: String,
        target: PasteTarget,
        keepOnClipboard: Bool,
        allowSkyLight: Bool = false
    ) async -> AttemptResult {
        guard target.isValid else {
            DiagnosticLog.write("BackgroundPaste: skipped — invalid target (pid=\(target.pid))")
            return .failed
        }

        // Gate: target process must still be running
        guard let targetApp = NSRunningApplication(processIdentifier: target.pid),
              !targetApp.isTerminated
        else {
            DiagnosticLog.write("BackgroundPaste: skipped — target process terminated (pid=\(target.pid))")
            return .failed
        }

        // --- Approach 1: AX text insertion ---
        if let window = target.windowElement,
           let textArea = focusedEditableElement(in: window, targetPid: target.pid) {
            if insertViaAX(text: text, into: textArea) {
                if keepOnClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                DiagnosticLog.write("BackgroundPaste: AX insertion succeeded for \(target.appName)")
                return .verified
            }
        }

        // --- Approach 2: SkyLight focusWithoutRaise + CMD+V ---
        if allowSkyLight,
           SkyLightBridge.isAvailable,
           let targetWindowID = target.windowID {
            let result = await attemptSkyLightPaste(
                text: text, target: target,
                targetWindowID: targetWindowID,
                keepOnClipboard: keepOnClipboard
            )
            if result == .commandPosted {
                DiagnosticLog.write("BackgroundPaste: SkyLight CMD+V posted for \(target.appName)")
                return result
            }
        }
        if !allowSkyLight {
            DiagnosticLog.write("BackgroundPaste: SkyLight skipped — experimental background paste disabled")
        }

        DiagnosticLog.write("BackgroundPaste: both approaches failed for \(target.appName)")
        return .failed
    }

    // MARK: - AX text insertion

    /// Insert text at the cursor position via AX API.
    /// Avoid blind AXValue append because the first text field in a window is
    /// not necessarily the user's intended insertion target.
    private static func insertViaAX(text: String, into textArea: AXUIElement) -> Bool {
        let selectedResult = AXUIElementSetAttributeValue(
            textArea, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        if selectedResult == .success { return true }

        DiagnosticLog.write("BackgroundPaste: AX selected-text insertion failed (error \(selectedResult.rawValue))")
        return false
    }

    /// Return the focused editable element only when it belongs to the captured
    /// target window. This avoids writing into an arbitrary first text field.
    static func focusedEditableElement(in window: AXUIElement, targetPid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(targetPid)
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success,
              let focusedRef else {
            DiagnosticLog.write("BackgroundPaste: no focused UI element exposed for pid=\(targetPid)")
            return nil
        }

        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            DiagnosticLog.write("BackgroundPaste: focused UI element is not an AXUIElement")
            return nil
        }
        // swiftlint:disable:next force_cast
        let focused = focusedRef as! AXUIElement
        guard isEditableTextElement(focused) else {
            DiagnosticLog.write("BackgroundPaste: focused element is not editable text")
            return nil
        }

        guard element(focused, descendsFrom: window) else {
            DiagnosticLog.write("BackgroundPaste: focused editable element is outside captured window")
            return nil
        }

        return focused
    }

    static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        guard role == "AXTextArea" || role == "AXTextField" else { return false }

        var enabledRef: CFTypeRef?
        let enabledResult = AXUIElementCopyAttributeValue(
            element,
            kAXEnabledAttribute as CFString,
            &enabledRef
        )
        if enabledResult == .success,
           let enabled = enabledRef as? Bool,
           !enabled {
            return false
        }

        return true
    }

    static func element(_ element: AXUIElement, descendsFrom ancestor: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard let candidate = current else { return false }
            if CFEqual(candidate, ancestor) { return true }

            var parentRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parentRef
            )
            guard result == .success,
                  let parentRef else {
                return false
            }
            guard CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { return false }
            // swiftlint:disable:next force_cast
            current = (parentRef as! AXUIElement)
        }
        return false
    }

    // MARK: - SkyLight CMD+V

    private static func attemptSkyLightPaste(
        text: String,
        target: PasteTarget,
        targetWindowID: CGWindowID,
        keepOnClipboard: Bool
    ) async -> AttemptResult {
        guard let current = SkyLightBridge.currentFocus() else { return .failed }

        let pasteboard = NSPasteboard.general
        let saved = keepOnClipboard ? [] : TextInserter.savePasteboardContents(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let restoreChangeCount = pasteboard.changeCount

        let focused = SkyLightBridge.focusWithoutRaise(
            targetPid: target.pid, targetWindowID: targetWindowID
        )
        guard focused else {
            if !keepOnClipboard {
                TextInserter.restorePasteboardContents(
                    pasteboard,
                    saved: saved,
                    onlyIfChangeCount: restoreChangeCount
                )
            }
            return .failed
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

        // Send CMD+V, preferring auth-signed SkyLight post, falling back to CGEvent.postToPid
        var posted = false
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
            posted = true
        }

        try? await Task.sleep(for: .milliseconds(100))

        let restored = SkyLightBridge.focusWithoutRaise(
            targetPid: current.pid, targetWindowID: current.windowID
        )
        if !restored {
            DiagnosticLog.write("BackgroundPaste: failed to restore focus to pid=\(current.pid)")
        }

        if !keepOnClipboard {
            TextInserter.restorePasteboardContents(
                pasteboard,
                saved: saved,
                onlyIfChangeCount: restoreChangeCount
            )
        }

        return posted ? .commandPosted : .failed
    }

}
