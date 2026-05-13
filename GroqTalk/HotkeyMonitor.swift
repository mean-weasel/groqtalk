import Cocoa
import CoreGraphics
import IOKit
import IOKit.hid

final class HotkeyMonitor {
    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: (() -> Void)?
    var onRecordingCancelled: (() -> Void)?

    // MARK: - Configuration

    enum HotkeyChoice: String, CaseIterable {
        case rightCommand
        case rightOption
        case globeFn
        case custom

        var deviceFlagBit: UInt64 {
            switch self {
            case .rightCommand: 0x10   // NX_DEVICERCMDKEYMASK
            case .rightOption:  0x40   // NX_DEVICERALTKEYMASK
            case .globeFn:      0      // Not used — Globe/Fn uses IOKit HID, never CGEvent tap
            case .custom:       0      // Not used — custom uses key code + modifier matching
            }
        }

        var label: String {
            switch self {
            case .rightCommand: "Right Command"
            case .rightOption:  "Right Option"
            case .globeFn:      "Globe / Fn"
            case .custom:       "Custom"
            }
        }
    }

    enum RecordingMode: String {
        case hold
        case toggle
    }

    private(set) var hotkeyChoice: HotkeyChoice = .rightCommand
    private(set) var recordingMode: RecordingMode = .hold

    // MARK: - Custom key configuration

    var customKeyCode: UInt16 = 0
    var customModifiers: UInt64 = 0

    func configureCustomKey(keyCode: UInt16, modifiers: UInt64) {
        customKeyCode = keyCode
        customModifiers = modifiers
    }

    // MARK: - CGEvent state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - IOKit HID state (for Globe/Fn)

    private var hidManager: IOHIDManager?

    // MARK: - Shared state machine

    private var keyDown = false
    private var otherKeysDuringHold = false
    private var pressTime: Date?
    /// Quick-release threshold: releases shorter than this cancel the recording
    /// to prevent accidental single-key-tap transcriptions.
    private let debounceInterval: TimeInterval = 0.2

    // Toggle mode: tracks whether we are currently in an active recording
    private var toggleRecording = false

    deinit { stop() }

    func configure(hotkeyChoice: HotkeyChoice, recordingMode: RecordingMode) {
        let needsRestart = self.hotkeyChoice != hotkeyChoice && (eventTap != nil || hidManager != nil)
        self.hotkeyChoice = hotkeyChoice
        self.recordingMode = recordingMode
        self.toggleRecording = false
        if needsRestart {
            stop()
            start()
        }
    }

    @discardableResult
    func start() -> Bool {
        stop()
        if hotkeyChoice == .globeFn {
            return startHID()
        } else {
            return startCGEvent()
        }
    }

    func stop() {
        stopCGEvent()
        stopHID()
        keyDown = false
        otherKeysDuringHold = false
        pressTime = nil
        toggleRecording = false
    }

    // MARK: - CGEvent strategy (Right Command, Right Option, Custom)

    private func startCGEvent() -> Bool {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleCGEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            DiagnosticLog.write("HotkeyMonitor: failed to create CGEvent tap")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopCGEvent() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if hotkeyChoice == .custom {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown && keyCode == customKeyCode {
                let rawFlags = event.flags.rawValue
                if customModifiers == 0 || (rawFlags & customModifiers) == customModifiers {
                    handleKeyStateChange(pressed: true)
                }
            } else if type == .keyUp && keyCode == customKeyCode {
                handleKeyStateChange(pressed: false)
            } else if type == .keyDown && keyDown {
                if !otherKeysDuringHold {
                    otherKeysDuringHold = true
                    onRecordingCancelled?()
                    toggleRecording = false
                }
            }
        } else if type == .flagsChanged {
            let rawFlags = event.flags.rawValue
            let deviceBit = hotkeyChoice.deviceFlagBit
            let targetActive = (rawFlags & deviceBit) != 0
            DiagnosticLog.write("flagsChanged: rawFlags=\(String(rawFlags, radix: 16)) deviceBit=\(String(deviceBit, radix: 16)) targetActive=\(targetActive)")
            handleKeyStateChange(pressed: targetActive)
        } else if type == .keyDown && keyDown {
            if !otherKeysDuringHold {
                otherKeysDuringHold = true
                onRecordingCancelled?()
                toggleRecording = false
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - IOKit HID strategy (Globe/Fn)

    private func startHID() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: 0x00FF,  // Apple Vendor Top Case (undocumented usage page)
            kIOHIDDeviceUsageKey: 0x0001        // Keyboard
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.handleHIDValue(value)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, callback, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if status != kIOReturnSuccess {
            DiagnosticLog.write("HotkeyMonitor: failed to open HID manager status=\(status)")
        }
        return status == kIOReturnSuccess
    }

    private func stopHID() {
        guard let manager = hidManager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = nil
    }

    private func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) == 1

        if usage == 0x0003 {  // Globe/Fn key on Apple Vendor Top Case page
            handleKeyStateChange(pressed: pressed)
        } else if keyDown {
            if !otherKeysDuringHold {
                otherKeysDuringHold = true
                onRecordingCancelled?()
                toggleRecording = false
            }
        }
    }

    // MARK: - Shared state machine

    /// Internal for testing — called by handleCGEvent and handleHIDValue.
    func handleKeyStateChange(pressed: Bool) {
        if pressed && !keyDown {
            keyDown = true
            otherKeysDuringHold = false
            pressTime = Date()

            if recordingMode == .toggle {
                // Toggle: key down starts or stops
                if toggleRecording {
                    toggleRecording = false
                    onRecordingStopped?()
                } else {
                    toggleRecording = true
                    onRecordingStarted?()
                }
            } else {
                // Hold: key down starts
                onRecordingStarted?()
            }
        } else if !pressed && keyDown {
            let wasSoloPress = !otherKeysDuringHold
            let longEnough = pressTime.map {
                Date().timeIntervalSince($0) >= debounceInterval
            } ?? false

            keyDown = false
            otherKeysDuringHold = false
            pressTime = nil

            if recordingMode == .hold {
                // Hold: key up stops or cancels
                if wasSoloPress && longEnough {
                    onRecordingStopped?()
                } else {
                    onRecordingCancelled?()
                }
            }
            // Toggle mode: key up is ignored (start/stop happens on key down)
        }
    }
}
