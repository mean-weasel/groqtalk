import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Thin wrapper around macOS SkyLight private framework APIs.
/// All raw dlsym / function-pointer work is confined here.
enum SkyLightBridge {

    // MARK: - Function pointer types

    private typealias PostEventRecordToFn =
        @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
    private typealias GetFrontProcessFn =
        @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias GetProcessForPIDFn =
        @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias AXGetWindowFn =
        @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32

    // MARK: - Symbol resolution

    private static let skyLightHandle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    }()

    /// Resolve a symbol from RTLD_DEFAULT after ensuring SkyLight is loaded.
    private static func resolve<T>(_ name: String, as _: T.Type) -> T? {
        _ = skyLightHandle
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    // MARK: - Resolved symbols

    private static let postEventRecordToFn = resolve("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
    private static let getFrontProcessFn = resolve("_SLPSGetFrontProcess", as: GetFrontProcessFn.self)
    private static let getProcessForPIDFn = resolve("GetProcessForPID", as: GetProcessForPIDFn.self)
    private static let axGetWindowFn = resolve("_AXUIElementGetWindow", as: AXGetWindowFn.self)

    // MARK: - SLEventPostToPid (auth-signed event posting)

    /// void SLEventPostToPid(pid_t, CGEventRef)
    private typealias SLPostToPidFn = @convention(c) (pid_t, CGEvent) -> Void

    /// void SLEventSetAuthenticationMessage(CGEventRef, id)
    private typealias SetAuthMessageFn = @convention(c) (CGEvent, AnyObject) -> Void

    /// objc_msgSend for +[SLSEventAuthenticationMessage messageWithEventRecord:pid:version:]
    private typealias FactoryMsgSendFn = @convention(c) (
        AnyObject, Selector, UnsafeMutableRawPointer, Int32, UInt32
    ) -> AnyObject?

    private static let slPostToPidFn = resolve("SLEventPostToPid", as: SLPostToPidFn.self)
    private static let setAuthMessageFn = resolve("SLEventSetAuthenticationMessage", as: SetAuthMessageFn.self)
    private static let factoryMsgSendFn = resolve("objc_msgSend", as: FactoryMsgSendFn.self)

    private static let authMessageClass: AnyClass? = {
        _ = skyLightHandle
        return NSClassFromString("SLSEventAuthenticationMessage")
    }()

    /// True when the auth-signed event post path is available.
    static var isAuthPostAvailable: Bool {
        slPostToPidFn != nil && setAuthMessageFn != nil
            && authMessageClass != nil && factoryMsgSendFn != nil
    }

    // MARK: - Public API

    /// True when all three core SkyLight SPIs resolved.
    static var isAvailable: Bool {
        postEventRecordToFn != nil
            && getFrontProcessFn != nil
            && getProcessForPIDFn != nil
    }

    /// Focus a window without raising it (SkyLight event injection).
    /// Returns true on success.
    static func focusWithoutRaise(targetPid: pid_t, targetWindowID: CGWindowID) -> Bool {
        guard let postEvent = postEventRecordToFn,
              let getFront = getFrontProcessFn,
              let getForPID = getProcessForPIDFn else { return false }

        // Get current frontmost PSN (8 bytes)
        var prevPSN = [UInt8](repeating: 0, count: 8)
        guard getFront(&prevPSN) == 0 else { return false }

        // Get target PSN
        var targetPSN = [UInt8](repeating: 0, count: 8)
        guard getForPID(targetPid, &targetPSN) == 0 else { return false }

        // Build 0xF8 (248) byte event record
        var buf = [UInt8](repeating: 0, count: 0xF8)
        buf[0x04] = 0xF8  // opcode high
        buf[0x08] = 0x0D  // opcode low

        // Little-endian UInt32 of targetWindowID at offset 0x3C
        let wid = UInt32(targetWindowID)
        buf[0x3C] = UInt8(wid & 0xFF)
        buf[0x3D] = UInt8((wid >> 8) & 0xFF)
        buf[0x3E] = UInt8((wid >> 16) & 0xFF)
        buf[0x3F] = UInt8((wid >> 24) & 0xFF)

        // Defocus previous window
        buf[0x8A] = 0x02
        let r1 = prevPSN.withUnsafeBufferPointer { psnPtr in
            buf.withUnsafeBufferPointer { bufPtr in
                postEvent(UnsafeRawPointer(psnPtr.baseAddress!), bufPtr.baseAddress!)
            }
        }

        usleep(40_000) // 40ms empirical delay (from yabai)

        // Focus target window
        buf[0x8A] = 0x01
        let r2 = targetPSN.withUnsafeBufferPointer { psnPtr in
            buf.withUnsafeBufferPointer { bufPtr in
                postEvent(UnsafeRawPointer(psnPtr.baseAddress!), bufPtr.baseAddress!)
            }
        }

        return r1 == 0 && r2 == 0
    }

    /// Extract the CGWindowID from an AXUIElement, if possible.
    static func windowID(from element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow = axGetWindowFn else { return nil }
        var wid: UInt32 = 0
        let result = axGetWindow(element, &wid)
        guard result == 0, wid != 0 else { return nil }
        return CGWindowID(wid)
    }

    /// Snapshot the currently focused window (pid + windowID).
    static func currentFocus() -> (pid: pid_t, windowID: CGWindowID)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard pid > 0 else { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        var value: AnyObject?
        let axResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )
        guard axResult == .success, let windowElement = value else { return nil }

        // AXUIElement is a CFTypeRef — validate type before casting
        guard CFGetTypeID(windowElement as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let axWindow = windowElement as! AXUIElement
        guard let wid = windowID(from: axWindow) else { return nil }
        return (pid: pid, windowID: wid)
    }

    /// Post a keyboard CGEvent to a specific PID via SLEventPostToPid
    /// with an SLSEventAuthenticationMessage attached. This is the
    /// trusted channel that Chrome/Electron accept.
    /// Falls back to CGEvent.postToPid if auth envelope can't be built.
    static func postKeyEventViaSkyLight(to pid: pid_t, event: CGEvent) -> Bool {
        guard let postFn = slPostToPidFn else { return false }

        // Attach auth message if available
        if let setAuth = setAuthMessageFn,
           let msgClass = authMessageClass,
           let msgSend = factoryMsgSendFn,
           let record = extractEventRecord(from: event) {
            let selector = NSSelectorFromString("messageWithEventRecord:pid:version:")
            if let msg = msgSend(msgClass as AnyObject, selector, record, pid, 0) {
                setAuth(event, msg)
            }
        }

        postFn(pid, event)
        return true
    }

    /// Extract the SLSEventRecord pointer embedded in a CGEvent.
    /// Layout: {CFRuntimeBase(16), uint32(4), padding(4), SLSEventRecord*}
    /// → pointer at offset 24. Probe adjacent offsets for resilience.
    private static func extractEventRecord(from event: CGEvent) -> UnsafeMutableRawPointer? {
        let base = Unmanaged.passUnretained(event).toOpaque()
        for offset in [24, 32, 16] {
            let slot = base.advanced(by: offset)
                .assumingMemoryBound(to: UnsafeMutableRawPointer?.self)
            if let p = slot.pointee { return p }
        }
        return nil
    }
}
