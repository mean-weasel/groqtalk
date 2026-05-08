#!/usr/bin/env swift
//
// Real-app smoke test for GroqTalk's mock transcription + async paste path.
//
// This drives the installed menu bar app through the configured hotkey. It is
// intentionally visible desktop automation, not a headless test.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

let appBundleID = "com.neonwatty.GroqTalk"
let appPath = "/Applications/GroqTalk.app"
let diagnosticLog = "/tmp/groqtalk-diag.log"
let testTextPrefix = "Mock transcription automation smoke"

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

func windowTitle(_ element: AXUIElement) -> String {
    var titleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
    return titleRef as? String ?? ""
}

func findTextArea(in element: AXUIElement) -> AXUIElement? {
    var roleRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
    if roleRef as? String == "AXTextArea" { return element }

    var childrenRef: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
    guard let children = childrenRef as? [AXUIElement] else { return nil }
    for child in children {
        if let found = findTextArea(in: child) {
            return found
        }
    }
    return nil
}

func textValue(in window: AXUIElement) -> String {
    guard let textArea = findTextArea(in: window) else { return "" }
    var valueRef: CFTypeRef?
    AXUIElementCopyAttributeValue(textArea, kAXValueAttribute as CFString, &valueRef)
    return valueRef as? String ?? ""
}

func waitUntil(timeout: TimeInterval, poll: TimeInterval = 0.25, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: poll)
    }
    return condition()
}

func readDiagnosticLog() -> String {
    (try? String(contentsOfFile: diagnosticLog, encoding: .utf8)) ?? ""
}

print("=== GroqTalk Real-App Mock Async Paste Smoke Test ===")
print()

guard AXIsProcessTrusted() else {
    print("ERROR: Accessibility permission is required.")
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
    AXIsProcessTrustedWithOptions(opts)
    exit(1)
}

guard FileManager.default.fileExists(atPath: appPath) else {
    print("ERROR: \(appPath) not found. Run `make install` first.")
    exit(1)
}

try? "".write(toFile: diagnosticLog, atomically: true, encoding: .utf8)

run("/usr/bin/defaults", ["write", appBundleID, "mockTranscriptionEnabled", "-bool", "true"])
run("/usr/bin/defaults", ["write", appBundleID, "asyncPasteEnabled", "-bool", "true"])
run("/usr/bin/defaults", ["write", appBundleID, "keepOnClipboard", "-bool", "false"])
run("/usr/bin/defaults", ["write", appBundleID, "recordingMode", "hold"])
run("/usr/bin/defaults", ["write", appBundleID, "audioFormat", "m4a"])
run("/usr/bin/defaults", ["write", appBundleID, "transcriptProcessingMode", "raw"])

run("/usr/bin/pkill", ["-x", "GroqTalk"])
Thread.sleep(forTimeInterval: 1.0)
run("/usr/bin/open", ["-n", appPath, "--args", "--automation-smoke"])

guard waitUntil(timeout: 8, poll: 0.25, {
    NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).first != nil
}) else {
    print("ERROR: GroqTalk did not launch.")
    exit(1)
}
Thread.sleep(forTimeInterval: 1.5)

run("/usr/bin/pkill", ["-x", "TextEdit"])
Thread.sleep(forTimeInterval: 1.0)

let fileA = FileManager.default.temporaryDirectory.appendingPathComponent("GroqTalkAppSmokeTarget.txt")
try "GroqTalk app smoke target\n".write(to: fileA, atomically: true, encoding: .utf8)
defer {
    try? FileManager.default.removeItem(at: fileA)
}

NSWorkspace.shared.open(fileA)
Thread.sleep(forTimeInterval: 1.5)

guard let textEditApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
    print("ERROR: TextEdit did not launch.")
    exit(1)
}
let axTextEdit = AXUIElementCreateApplication(textEditApp.processIdentifier)
var windowsRef: CFTypeRef?
AXUIElementCopyAttributeValue(axTextEdit, kAXWindowsAttribute as CFString, &windowsRef)
guard let windows = windowsRef as? [AXUIElement] else {
    print("ERROR: Could not read TextEdit windows.")
    exit(1)
}

let targetWindow = windows.first { windowTitle($0).contains("GroqTalkAppSmokeTarget") }
guard let targetWindow else {
    print("ERROR: Could not identify TextEdit smoke window.")
    exit(1)
}

AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
AXUIElementSetAttributeValue(targetWindow, kAXMainAttribute as CFString, true as CFTypeRef)
AXUIElementSetAttributeValue(targetWindow, kAXFocusedAttribute as CFString, true as CFTypeRef)
textEditApp.activate()
Thread.sleep(forTimeInterval: 1.0)

print("Requesting automation mock transcription against TextEdit target...")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.neonwatty.GroqTalk.automation.mockSuccess"),
    object: nil,
    userInfo: nil,
    deliverImmediately: true
)
Thread.sleep(forTimeInterval: 0.8)
NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
Thread.sleep(forTimeInterval: 0.5)

let pasted = waitUntil(timeout: 9, poll: 0.5, {
    AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
    textEditApp.activate()
    Thread.sleep(forTimeInterval: 0.1)
    return textValue(in: targetWindow).contains(testTextPrefix)
})

let targetText = textValue(in: targetWindow)
let log = readDiagnosticLog()

print()
print("Diagnostic checks:")
print(log.contains("automation smoke: requested") ? "✓ automation mock transcription requested" : "✗ automation request not observed")
print(log.contains("ASYNC PATH") ? "✓ async paste path used" : "✗ async paste path not observed")
print(log.contains("automation smoke: enabled") ? "✓ automation smoke mode enabled" : "✗ automation smoke mode missing")

if log.contains("Microphone unavailable") {
    print("ERROR: GroqTalk reported microphone unavailable.")
    exit(1)
}

if pasted && targetText.contains(testTextPrefix) {
    print()
    print("✅ PASS: Installed GroqTalk used mock transcription and pasted into the TextEdit target.")
    exit(0)
}

if log.contains("windowElement: nil") {
    print()
    print("⚠️  SKIP: Installed GroqTalk entered the mock async path, but this desktop session did not expose the target AX window to the app process.")
    print("Grant or refresh Accessibility permission for /Applications/GroqTalk.app, then rerun `make test-app-smoke`.")
    exit(0)
}

print()
print("❌ FAIL: Mock transcription text was not found in the TextEdit target.")
print("Target prefix: \(targetText.prefix(120))")
exit(1)
