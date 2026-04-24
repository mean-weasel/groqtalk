import XCTest
@testable import GroqTalk

final class HotkeyMonitorTests: XCTestCase {
    private var monitor: HotkeyMonitor!
    private var events: [String] = []

    override func setUp() {
        monitor = HotkeyMonitor()
        events = []
        monitor.onRecordingStarted = { [weak self] in self?.events.append("started") }
        monitor.onRecordingStopped = { [weak self] in self?.events.append("stopped") }
        monitor.onRecordingCancelled = { [weak self] in self?.events.append("cancelled") }
    }

    // MARK: - Hold mode (default)

    func testHoldModeIsDefault() {
        XCTAssertEqual(monitor.recordingMode, .hold)
    }

    func testHoldModeStartsOnKeyDown() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        monitor.handleKeyStateChange(pressed: true)
        XCTAssertEqual(events, ["started"])
    }

    func testHoldModeStopsOnKeyUpAfterDebounce() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        monitor.handleKeyStateChange(pressed: true)
        // Wait past the 0.2s debounce interval
        Thread.sleep(forTimeInterval: 0.25)
        monitor.handleKeyStateChange(pressed: false)
        XCTAssertEqual(events, ["started", "stopped"])
    }

    func testHoldModeCancelsOnQuickRelease() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        monitor.handleKeyStateChange(pressed: true)
        // Release immediately — before debounce
        monitor.handleKeyStateChange(pressed: false)
        XCTAssertEqual(events, ["started", "cancelled"])
    }

    func testHoldModeIgnoresDoublePress() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        monitor.handleKeyStateChange(pressed: true)
        monitor.handleKeyStateChange(pressed: true) // duplicate — already pressed
        XCTAssertEqual(events, ["started"], "Second press while held should be ignored")
    }

    func testHoldModeIgnoresDoubleRelease() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        monitor.handleKeyStateChange(pressed: true)
        Thread.sleep(forTimeInterval: 0.25)
        monitor.handleKeyStateChange(pressed: false)
        monitor.handleKeyStateChange(pressed: false) // duplicate — already released
        XCTAssertEqual(events, ["started", "stopped"], "Second release should be ignored")
    }

    func testHoldModeFullCycle() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        // First recording
        monitor.handleKeyStateChange(pressed: true)
        Thread.sleep(forTimeInterval: 0.25)
        monitor.handleKeyStateChange(pressed: false)
        // Second recording
        monitor.handleKeyStateChange(pressed: true)
        Thread.sleep(forTimeInterval: 0.25)
        monitor.handleKeyStateChange(pressed: false)
        XCTAssertEqual(events, ["started", "stopped", "started", "stopped"])
    }

    // MARK: - Toggle mode

    func testToggleModeStartsOnFirstPress() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        monitor.handleKeyStateChange(pressed: true)
        XCTAssertEqual(events, ["started"])
    }

    func testToggleModeIgnoresKeyUp() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        monitor.handleKeyStateChange(pressed: true) // start
        monitor.handleKeyStateChange(pressed: false) // release — should be ignored
        XCTAssertEqual(events, ["started"], "Key up should not trigger stop in toggle mode")
    }

    func testToggleModeStopsOnSecondPress() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        monitor.handleKeyStateChange(pressed: true) // start
        monitor.handleKeyStateChange(pressed: false) // release
        monitor.handleKeyStateChange(pressed: true) // stop
        XCTAssertEqual(events, ["started", "stopped"])
    }

    func testToggleModeFullCycle() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        // First recording
        monitor.handleKeyStateChange(pressed: true) // start
        monitor.handleKeyStateChange(pressed: false)
        monitor.handleKeyStateChange(pressed: true) // stop
        monitor.handleKeyStateChange(pressed: false)
        // Second recording
        monitor.handleKeyStateChange(pressed: true) // start
        monitor.handleKeyStateChange(pressed: false)
        monitor.handleKeyStateChange(pressed: true) // stop
        XCTAssertEqual(events, ["started", "stopped", "started", "stopped"])
    }

    func testToggleModeNoDebounceNeeded() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        // Quick tap should still work in toggle mode (no debounce gating)
        monitor.handleKeyStateChange(pressed: true)
        monitor.handleKeyStateChange(pressed: false)
        monitor.handleKeyStateChange(pressed: true) // immediate second press
        XCTAssertEqual(events, ["started", "stopped"])
    }

    // MARK: - Configure

    func testConfigureResetsToggleState() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        monitor.handleKeyStateChange(pressed: true) // start recording
        monitor.handleKeyStateChange(pressed: false) // release
        XCTAssertEqual(events, ["started"])

        // Reconfigure — should reset toggleRecording state
        monitor.configure(hotkeyChoice: .rightOption, recordingMode: .toggle)
        monitor.handleKeyStateChange(pressed: true)
        // Should start a NEW recording (not stop the old one), because toggle was reset
        XCTAssertEqual(events, ["started", "started"])
    }

    func testConfigureChangesMode() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        XCTAssertEqual(monitor.recordingMode, .hold)
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        XCTAssertEqual(monitor.recordingMode, .toggle)
    }

    func testConfigureChangesHotkeyChoice() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .hold)
        XCTAssertEqual(monitor.hotkeyChoice, .rightCommand)
        monitor.configure(hotkeyChoice: .globeFn, recordingMode: .hold)
        XCTAssertEqual(monitor.hotkeyChoice, .globeFn)
    }

    // MARK: - HotkeyChoice properties

    func testHotkeyChoiceLabels() {
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.rightCommand.label, "Right Command")
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.rightOption.label, "Right Option")
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.globeFn.label, "Globe / Fn")
    }

    func testHotkeyChoiceDeviceFlagBits() {
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.rightCommand.deviceFlagBit, 0x10)
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.rightOption.deviceFlagBit, 0x40)
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.globeFn.deviceFlagBit, 0)
    }

    func testHotkeyChoiceRawValues() {
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.rightCommand.rawValue, "rightCommand")
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.rightOption.rawValue, "rightOption")
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.globeFn.rawValue, "globeFn")
    }

    func testRecordingModeRawValues() {
        XCTAssertEqual(HotkeyMonitor.RecordingMode.hold.rawValue, "hold")
        XCTAssertEqual(HotkeyMonitor.RecordingMode.toggle.rawValue, "toggle")
    }

    // MARK: - Stop resets state

    func testStopResetsAllState() {
        monitor.configure(hotkeyChoice: .rightCommand, recordingMode: .toggle)
        monitor.handleKeyStateChange(pressed: true) // start toggle recording
        monitor.stop()

        // After stop, next press should start fresh
        events = []
        monitor.handleKeyStateChange(pressed: true)
        XCTAssertEqual(events, ["started"], "After stop(), first press should start recording")
    }
}
