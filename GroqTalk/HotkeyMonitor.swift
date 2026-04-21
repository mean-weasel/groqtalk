import Cocoa
import CoreGraphics

final class HotkeyMonitor {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onRecordingCancelled: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightCommandDown = false
    private var otherKeysDuringHold = false
    private var pressTime: Date?
    private let debounceInterval: TimeInterval = 0.2

    // Device-specific flag bits (from IOLLEvent.h / NSEvent.h)
    // These distinguish left vs right modifier keys in the raw flags
    private static let rightCommandDeviceFlag: UInt64 = 0x10  // NX_DEVICERCMDKEYMASK

    func start() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("HotkeyMonitor: failed to create event tap — is Accessibility enabled?")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("HotkeyMonitor: event tap created and enabled")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if macOS disabled it due to slow callback
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let rawFlags = event.flags.rawValue
            let rightCmdActive = (rawFlags & Self.rightCommandDeviceFlag) != 0

            if rightCmdActive && !rightCommandDown {
                rightCommandDown = true
                otherKeysDuringHold = false
                pressTime = Date()
                onRecordingStarted?()
            } else if !rightCmdActive && rightCommandDown {
                let wasSoloPress = !otherKeysDuringHold
                let longEnough = pressTime.map {
                    Date().timeIntervalSince($0) >= debounceInterval
                } ?? false

                rightCommandDown = false
                otherKeysDuringHold = false
                pressTime = nil

                if wasSoloPress && longEnough {
                    onRecordingStopped?()
                } else {
                    onRecordingCancelled?()
                }
            }
        } else if type == .keyDown && rightCommandDown {
            // A regular key pressed while Right Command held — cancel recording
            if !otherKeysDuringHold {
                otherKeysDuringHold = true
                onRecordingCancelled?()
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
