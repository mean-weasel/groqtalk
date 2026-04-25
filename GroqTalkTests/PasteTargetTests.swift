import XCTest
@testable import GroqTalk

final class PasteTargetTests: XCTestCase {
    func testCaptureReturnsNilWithoutAccessibility() {
        // In the test runner, AX permissions may not be granted.
        // PasteTarget.captureCurrentTarget() should return nil gracefully
        // rather than crashing when AX queries fail.
        let target = PasteTarget.captureCurrentTarget()
        // Either nil (no AX) or a valid target — must not crash
        if let target {
            XCTAssertGreaterThan(target.pid, 0)
        }
    }

    func testManualInitStoresValues() {
        let target = PasteTarget(windowElement: nil, pid: 12345, appName: "TestApp")
        XCTAssertEqual(target.pid, 12345)
        XCTAssertEqual(target.appName, "TestApp")
        XCTAssertNil(target.windowElement)
    }

    func testTargetWithZeroPidIsInvalid() {
        let target = PasteTarget(windowElement: nil, pid: 0, appName: "")
        XCTAssertFalse(target.isValid)
    }

    func testTargetWithPositivePidIsValid() {
        let target = PasteTarget(windowElement: nil, pid: 999, appName: "App")
        XCTAssertTrue(target.isValid)
    }
}
