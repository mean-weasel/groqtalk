import XCTest
@testable import GroqTalk

final class HotkeyMonitorCustomKeyTests: XCTestCase {

    func testConfigureCustomKeySetsProperties() {
        let monitor = HotkeyMonitor()
        monitor.configureCustomKey(keyCode: 0x31, modifiers: 0x100108)
        XCTAssertEqual(monitor.customKeyCode, 0x31)
        XCTAssertEqual(monitor.customModifiers, 0x100108)
    }

    func testCustomHotkeyChoiceLabel() {
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.custom.label, "Custom")
    }

    func testAllHotkeyChoicesIncludesCustom() {
        XCTAssertTrue(HotkeyMonitor.HotkeyChoice.allCases.contains(.custom))
    }

    func testCustomHotkeyChoiceDeviceFlagBitIsZero() {
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.custom.deviceFlagBit, 0)
    }

    func testCustomHotkeyChoiceRawValue() {
        XCTAssertEqual(HotkeyMonitor.HotkeyChoice.custom.rawValue, "custom")
    }

    func testConfigureCustomKeyOverwritesPreviousValues() {
        let monitor = HotkeyMonitor()
        monitor.configureCustomKey(keyCode: 0x10, modifiers: 0xFF)
        monitor.configureCustomKey(keyCode: 0x31, modifiers: 0x100108)
        XCTAssertEqual(monitor.customKeyCode, 0x31)
        XCTAssertEqual(monitor.customModifiers, 0x100108)
    }

    func testCustomChoiceDefaultsToZeroKeyCodeAndModifiers() {
        let monitor = HotkeyMonitor()
        XCTAssertEqual(monitor.customKeyCode, 0)
        XCTAssertEqual(monitor.customModifiers, 0)
    }

    func testAllCasesContainsAllExpectedChoices() {
        let all = HotkeyMonitor.HotkeyChoice.allCases
        XCTAssertTrue(all.contains(.rightCommand))
        XCTAssertTrue(all.contains(.rightOption))
        XCTAssertTrue(all.contains(.globeFn))
        XCTAssertTrue(all.contains(.custom))
        XCTAssertEqual(all.count, 4)
    }
}
