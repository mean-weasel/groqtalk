import XCTest

final class GroqTalkUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-defaults",
            "--seed-history"
        ]
        app.launch()
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testControlCenterShowsSeededReadyState() {
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.staticTexts["Second searchable transcript."].exists)
        XCTAssertTrue(app.buttons["History"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.staticTexts["Test Setup"].exists)
        XCTAssertTrue(app.buttons["Test"].exists)
        XCTAssertTrue(app.checkBoxes["Paste where recording started"].exists)
        XCTAssertTrue(app.checkBoxes["Show floating status"].exists)
        XCTAssertTrue(app.checkBoxes["Mock Transcription"].exists)
    }

    func testSetupCheckCanBeRunInline() {
        app.buttons["Test"].click()

        XCTAssertTrue(app.staticTexts["Setup Tested"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ready to record"].exists)
    }

    func testSetupFailuresShowRecoveryDetails() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-defaults",
            "--seed-history",
            "--seed-setup-failures"
        ]
        app.launch()

        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Open Privacy & Security and turn on GroqTalk."].exists)
        XCTAssertTrue(app.staticTexts["Open Microphone privacy and allow GroqTalk."].exists)
        XCTAssertTrue(app.staticTexts["Add your Groq API key to enable transcription."].exists)
        XCTAssertTrue(app.staticTexts["Open Accessibility settings, enable GroqTalk, then rerun the test."].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    func testHistoryWindowOpensAndSearchesSeededRecords() {
        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))

        let searchField = app.textFields["Search transcriptions..."]
        XCTAssertTrue(searchField.exists)
        searchField.click()
        searchField.typeText("Second searchable")

        XCTAssertTrue(app.staticTexts["Second searchable transcript."].waitForExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["Seeded transcript for UI testing."].exists)
    }

    func testHistoryFilterShowsFailedRecords() {
        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))

        app.buttons["Failed"].click()

        XCTAssertTrue(app.staticTexts["Seeded network failure"].waitForExistence(timeout: 2))
    }

    func testHistoryDeleteAndClearActions() {
        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))

        XCTAssertTrue(app.staticTexts["Second searchable transcript."].exists)
        app.buttons["Delete"].firstMatch.click()
        XCTAssertFalse(app.staticTexts["Seeded network failure"].waitForExistence(timeout: 1))

        app.buttons["Clear"].click()
        XCTAssertTrue(app.staticTexts["No transcriptions yet"].waitForExistence(timeout: 2))
    }

    func testSettingsPanelOpensInsideMenuBarPopover() {
        app.buttons["Settings"].click()
        XCTAssertFalse(app.windows["Settings"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["General"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Recording"].exists)
        XCTAssertTrue(app.staticTexts["Transcription"].exists)
        XCTAssertTrue(app.staticTexts["Paste"].exists)
        XCTAssertTrue(app.staticTexts["Privacy"].exists)
        XCTAssertTrue(app.buttons["Change API Key"].exists)
    }

    func testMockTogglePersistsAcrossLaunches() {
        let toggle = app.checkBoxes["Mock Transcription"]
        XCTAssertTrue(toggle.exists)
        toggle.click()

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--seed-history"
        ]
        app.launch()

        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5))
        XCTAssertTrue(app.checkBoxes["Mock Transcription"].exists)
    }

    func testSimulatedRecordingUsesCurrentAppPasteWhenAsyncIsOff() {
        XCTAssertFalse(app.staticTexts["Mock async paste transcript"].exists)

        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Sending audio"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Done"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Mock async paste transcript"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Pasted into the current app"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Clipboard restored"].exists)
    }

    func testSimulatedRecordingUsesAsyncPasteWhenEnabled() {
        app.checkBoxes["Paste where recording started"].click()
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Sending audio"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Mock async paste transcript"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Pasted into the test target"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Target: GroqTalk UI Test"].exists)
    }

    func testSimulatedRecordingFailureKeepsRetryVisibleInHistory() {
        app.buttons["Simulate Failure"].click()

        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Simulated transcription failure"].exists)

        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Simulated transcription failure"].waitForExistence(timeout: 2))
    }

    func testFloatingStatusCanBeEnabled() {
        app.checkBoxes["Show floating status"].click()
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 3))
    }

    func testFloatingStatusAutoHidesAfterSuccessWhenEnabled() {
        app.checkBoxes["Show floating status"].click()
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Done"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Done"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.staticTexts["Pasted into the current app"].exists)
    }

    func testFloatingStatusIsDisabledByDefault() {
        app.buttons["Simulate Success"].click()

        XCTAssertFalse(app.windows["GroqTalk Floating Status"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Pasted into the current app"].waitForExistence(timeout: 2))
    }

    private var controlCenter: XCUIElement {
        app.windows["GroqTalk UI Test"].exists
            ? app.windows["GroqTalk UI Test"]
            : app.staticTexts["Ready"]
    }
}
