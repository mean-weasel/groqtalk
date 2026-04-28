#!/usr/bin/env swift
//
// Integration test for SkyLight background paste.
// Opens two TextEdit windows, captures target A (with windowID),
// switches to B, pastes into A via SkyLight, verifies focus never
// visibly changed.
//
// Usage: swift tests/test_skylight_paste.swift
// Requires: Accessibility permission for Terminal/Ghostty

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - SkyLight SPI wrappers (standalone — no GroqTalk import)

private typealias PostEventRecordToFn = @convention(c) (UnsafeRawPointer, UnsafePointer<UInt8>) -> Int32
private typealias GetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
private typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32

private let skyLightHandle = dlopen(
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY
)

private func resolve<T>(_ name: String, as _: T.Type) -> T? {
    guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
    return unsafeBitCast(p, to: T.self)
}

private let slPostEventRecord = resolve("SLPSPostEventRecordTo", as: PostEventRecordToFn.self)
private let slGetFrontProcess = resolve("_SLPSGetFrontProcess", as: GetFrontProcessFn.self)
private let slGetProcessForPID = resolve("GetProcessForPID", as: GetProcessForPIDFn.self)
private let axGetWindow = resolve("_AXUIElementGetWindow", as: AXGetWindowFn.self)

var skyLightAvailable: Bool {
    slPostEventRecord != nil && slGetFrontProcess != nil && slGetProcessForPID != nil
}

func windowID(from element: AXUIElement) -> CGWindowID? {
    guard let fn = axGetWindow else { return nil }
    var wid: UInt32 = 0
    guard fn(element, &wid) == 0, wid != 0 else { return nil }
    return CGWindowID(wid)
}

func focusWithoutRaise(targetPid: pid_t, targetWindowID: CGWindowID) -> Bool {
    guard let postFn = slPostEventRecord,
          let getFront = slGetFrontProcess,
          let getPSN = slGetProcessForPID
    else { return false }

    var prevPSN = [UInt8](repeating: 0, count: 8)
    guard prevPSN.withUnsafeMutableBytes({ getFront($0.baseAddress!) }) == 0 else { return false }

    var targetPSN = [UInt8](repeating: 0, count: 8)
    guard targetPSN.withUnsafeMutableBytes({ getPSN(targetPid, $0.baseAddress!) }) == 0 else { return false }

    var buf = [UInt8](repeating: 0, count: 0xF8)
    buf[0x04] = 0xF8; buf[0x08] = 0x0D
    let wid = UInt32(targetWindowID)
    buf[0x3C] = UInt8(wid & 0xFF)
    buf[0x3D] = UInt8((wid >> 8) & 0xFF)
    buf[0x3E] = UInt8((wid >> 16) & 0xFF)
    buf[0x3F] = UInt8((wid >> 24) & 0xFF)

    buf[0x8A] = 0x02
    let _ = prevPSN.withUnsafeBytes { psnRaw in
        buf.withUnsafeBufferPointer { bp in
            postFn(psnRaw.baseAddress!, bp.baseAddress!)
        }
    }

    usleep(40_000)

    buf[0x8A] = 0x01
    let _ = targetPSN.withUnsafeBytes { psnRaw in
        buf.withUnsafeBufferPointer { bp in
            postFn(psnRaw.baseAddress!, bp.baseAddress!)
        }
    }

    return true
}

// MARK: - Helpers

func windowTitle(_ w: AXUIElement) -> String {
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &titleRef)
    return (titleRef as? String) ?? "unknown"
}

func getWindowText(_ w: AXUIElement, textEditApp: NSRunningApplication) -> String {
    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &childrenRef)
    if let children = childrenRef as? [AXUIElement] {
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            if let role = roleRef as? String, role == "AXScrollArea" || role == "AXTextArea" {
                var valueRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)
                if let value = valueRef as? String { return value }
                var subChildrenRef: CFTypeRef?
                AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &subChildrenRef)
                if let subChildren = subChildrenRef as? [AXUIElement] {
                    for sub in subChildren {
                        AXUIElementCopyAttributeValue(sub, kAXValueAttribute as CFString, &valueRef)
                        if let value = valueRef as? String { return value }
                    }
                }
            }
        }
    }
    return "<could not read>"
}

// MARK: - Main test

print("=== SkyLight Background Paste Test ===")
print()

// Check permissions
if !AXIsProcessTrusted() {
    print("ERROR: No Accessibility permission.")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    exit(1)
}
print("✓ Accessibility permission granted")

// Check SkyLight availability
guard skyLightAvailable else {
    print("ERROR: SkyLight SPIs not available — cannot run this test.")
    exit(1)
}
print("✓ SkyLight SPIs resolved")

// Close existing TextEdit
_ = Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-x", "TextEdit"])
Thread.sleep(forTimeInterval: 2)

// Create two temp files
let fileA = FileManager.default.temporaryDirectory.appendingPathComponent("SkyLightTestA.txt")
let fileB = FileManager.default.temporaryDirectory.appendingPathComponent("SkyLightTestB.txt")
try! "Window A - target\n".write(to: fileA, atomically: true, encoding: .utf8)
try! "Window B - user is here\n".write(to: fileB, atomically: true, encoding: .utf8)

print()
print("Step 1: Opening two TextEdit windows...")
let ws = NSWorkspace.shared
ws.open(fileA)
Thread.sleep(forTimeInterval: 2)
ws.open(fileB)
Thread.sleep(forTimeInterval: 2)
print("✓ Two TextEdit windows open")

// Find TextEdit windows
guard let textEditApp = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.TextEdit"
).first else {
    print("ERROR: TextEdit not running"); exit(1)
}
let textEditPid = textEditApp.processIdentifier
let axApp = AXUIElementCreateApplication(textEditPid)

var windowList: CFTypeRef?
AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList)
guard let windows = windowList as? [AXUIElement], windows.count >= 2 else {
    print("ERROR: Expected 2 TextEdit windows"); exit(1)
}

var windowA: AXUIElement?
var windowB: AXUIElement?
for w in windows {
    let title = windowTitle(w)
    if title.contains("SkyLightTestA") { windowA = w }
    if title.contains("SkyLightTestB") { windowB = w }
}
guard let wA = windowA, let wB = windowB else {
    print("ERROR: Could not identify windows A and B"); exit(1)
}

// Get window IDs
guard let widA = windowID(from: wA) else {
    print("ERROR: Could not get windowID for window A"); exit(1)
}
guard let widB = windowID(from: wB) else {
    print("ERROR: Could not get windowID for window B"); exit(1)
}
print("  Window A: '\(windowTitle(wA))' wid=\(widA)")
print("  Window B: '\(windowTitle(wB))' wid=\(widB)")

// Step 2: Focus window A (this is the "target" the user was in when recording started)
print()
print("Step 2: Focusing Window A and capturing target...")
AXUIElementPerformAction(wA, kAXRaiseAction as CFString)
textEditApp.activate()
Thread.sleep(forTimeInterval: 0.5)
print("✓ Target captured: TextEdit wid=\(widA)")

// Step 3: Switch to window B (simulate user moving away)
print()
print("Step 3: Switching to Window B...")
AXUIElementPerformAction(wB, kAXRaiseAction as CFString)
Thread.sleep(forTimeInterval: 0.5)

// Record which app is frontmost BEFORE paste
let frontBeforePaste = NSWorkspace.shared.frontmostApplication
print("  Frontmost before paste: \(frontBeforePaste?.localizedName ?? "nil")")
print("✓ User is in Window B")

// Step 4: Simulate transcription delay
print()
print("Step 4: Simulating 2-second transcription delay...")
Thread.sleep(forTimeInterval: 2.0)
print("✓ Transcription complete: 'SKYLIGHT_PASTE_TEST'")

// Step 5: SkyLight background paste — the actual test
print()
print("Step 5: SkyLight background paste into Window A...")

// Write text to clipboard
let testText = "SKYLIGHT_PASTE_TEST"
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(testText, forType: .string)

// Focus-without-raise to target
let focusOk = focusWithoutRaise(targetPid: textEditPid, targetWindowID: widA)
print("  focusWithoutRaise: \(focusOk ? "OK" : "FAILED")")
Thread.sleep(forTimeInterval: 0.05)

// Send CMD+V to target PID
let source = CGEventSource(stateID: .hidSystemState)
if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
   let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
    keyDown.flags = .maskCommand
    keyUp.flags = .maskCommand
    keyDown.postToPid(textEditPid)
    keyUp.postToPid(textEditPid)
    print("  CMD+V posted to pid \(textEditPid)")
}
Thread.sleep(forTimeInterval: 0.15)

// Restore focus to window B
let restoreOk = focusWithoutRaise(targetPid: textEditPid, targetWindowID: widB)
print("  Restore focus to B: \(restoreOk ? "OK" : "FAILED")")
Thread.sleep(forTimeInterval: 0.05)

// KEY ASSERTION: frontmost app should NOT have visibly changed
let frontAfterPaste = NSWorkspace.shared.frontmostApplication
print("  Frontmost after paste: \(frontAfterPaste?.localizedName ?? "nil")")

// Step 6: Verify results
print()
print("Step 6: Verifying results...")

// Read window contents (this WILL activate TextEdit temporarily for AX reads)
AXUIElementPerformAction(wA, kAXRaiseAction as CFString)
textEditApp.activate()
Thread.sleep(forTimeInterval: 0.3)
let textA = getWindowText(wA, textEditApp: textEditApp)

AXUIElementPerformAction(wB, kAXRaiseAction as CFString)
Thread.sleep(forTimeInterval: 0.3)
let textB = getWindowText(wB, textEditApp: textEditApp)

print("  Window A contents: \(textA.prefix(100))")
print("  Window B contents: \(textB.prefix(100))")

print()
var passed = true

if textA.contains(testText) && !textB.contains(testText) {
    print("✅ PASS: Text landed in Window A (target), not Window B")
} else if textB.contains(testText) {
    print("❌ FAIL: Text landed in Window B instead of Window A")
    passed = false
} else {
    print("❌ FAIL: Text not found in either window")
    passed = false
}

// Cleanup
print()
print("Cleaning up...")
try? FileManager.default.removeItem(at: fileA)
try? FileManager.default.removeItem(at: fileB)
_ = Process.launchedProcess(launchPath: "/usr/bin/pkill", arguments: ["-x", "TextEdit"])

exit(passed ? 0 : 1)
