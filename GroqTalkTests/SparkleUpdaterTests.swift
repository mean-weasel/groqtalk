import XCTest
@testable import GroqTalk

@MainActor
final class SparkleUpdaterTests: XCTestCase {
    func testSparkleUpdaterInitializes() {
        let updater = SparkleUpdater.shared
        _ = updater.canCheckForUpdates
    }

    func testAutomaticallyChecksDefaultsToTrue() {
        let updater = SparkleUpdater.shared
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
    }

    func testCanToggleAutomaticUpdates() {
        let updater = SparkleUpdater.shared
        updater.automaticallyChecksForUpdates = false
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = true
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
    }
}
