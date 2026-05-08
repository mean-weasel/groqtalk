import ApplicationServices
import AppKit
import CoreGraphics

/// Captures the identity of the window that should receive a paste.
/// Stored at the moment the user triggers recording so that focus changes
/// during transcription don't redirect the paste to the wrong app.
struct PasteTarget {
    let windowElement: AXUIElement?
    let windowID: CGWindowID?
    let pid: pid_t
    let appName: String

    /// A target is valid when it refers to a real process.
    var isValid: Bool { pid > 0 }

    /// Captures the currently focused window and owning process.
    /// Falls back to the main window, then the first app window, because some
    /// apps intermittently expose no focused window even while frontmost.
    static func captureCurrentTarget() -> PasteTarget? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let pid = frontApp.processIdentifier
        guard pid > 0 else { return nil }

        let appName = frontApp.localizedName ?? ""
        let appElement = AXUIElementCreateApplication(pid)

        let window = firstWindow(
            appElement: appElement,
            attributes: [
                kAXFocusedWindowAttribute as String,
                kAXMainWindowAttribute as String
            ]
        ) ?? firstWindowInList(appElement: appElement)

        let windowID = window.flatMap { SkyLightBridge.windowID(from: $0) }
        return PasteTarget(windowElement: window, windowID: windowID, pid: pid, appName: appName)
    }

    private static func firstWindow(appElement: AXUIElement, attributes: [String]) -> AXUIElement? {
        for attribute in attributes {
            var windowRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                appElement,
                attribute as CFString,
                &windowRef
            )
            if result == .success, let ref = windowRef {
                // swiftlint:disable:next force_cast
                return (ref as! AXUIElement)
            }
        }
        return nil
    }

    private static func firstWindowInList(appElement: AXUIElement) -> AXUIElement? {
        var windowRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowRef
        )
        guard result == .success,
              let windows = windowRef as? [AXUIElement] else { return nil }
        return windows.first
    }
}
