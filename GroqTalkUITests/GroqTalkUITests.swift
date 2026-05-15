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
        XCTAssertTrue(app.staticTexts["Right Command · Pastes into current app"].exists)
        XCTAssertTrue(app.staticTexts["Second searchable transcript."].exists)
        XCTAssertTrue(app.buttons["History"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Help"].exists)
        XCTAssertTrue(app.buttons["Start recording"].exists)
        XCTAssertTrue(app.buttons["Start recording"].isEnabled)
        XCTAssertTrue(app.buttons["Stop recording"].exists)
        XCTAssertFalse(app.buttons["Stop recording"].isEnabled)
        XCTAssertTrue(app.buttons["Cancel recording"].exists)
        XCTAssertFalse(app.buttons["Cancel recording"].isEnabled)
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
        XCTAssertTrue(app.staticTexts["Setup needed"].exists)
        XCTAssertTrue(app.staticTexts["Enable Accessibility before recording"].exists)
        XCTAssertTrue(app.staticTexts["Open Privacy & Security and turn on GroqTalk."].exists)
        XCTAssertTrue(app.staticTexts["Open Microphone privacy and allow GroqTalk."].exists)
        XCTAssertTrue(app.staticTexts["Add your Groq API key to enable transcription."].exists)
        XCTAssertTrue(app.staticTexts["Open Accessibility settings, enable GroqTalk, then rerun the test."].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
    }

    func testUnknownSetupStateDoesNotShowReadySession() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-defaults",
            "--seed-setup-unknown"
        ]
        app.launch()

        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Setup needed"].exists)
        XCTAssertTrue(app.staticTexts["Check Accessibility before recording"].exists)
        XCTAssertTrue(app.staticTexts["Not checked"].exists)
        XCTAssertFalse(app.staticTexts["Right Command · Pastes into current app"].exists)
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

        XCTAssertTrue(app.buttons["All"].isEnabled)
        app.buttons["Failed"].click()
        XCTAssertTrue(app.buttons["Failed"].isEnabled)

        XCTAssertTrue(app.staticTexts["Seeded network failure"].waitForExistence(timeout: 2))
    }

    func testHistoryDeleteAndClearActions() {
        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))

        XCTAssertTrue(app.staticTexts["Second searchable transcript."].exists)
        app.buttons["Delete"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Delete History Item?"].waitForExistence(timeout: 2))
        clickAlertButton("Cancel")
        XCTAssertTrue(app.staticTexts["Seeded network failure"].waitForExistence(timeout: 2))

        relaunchWithSeededHistory()
        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))

        app.buttons["Clear"].click()
        XCTAssertTrue(app.staticTexts["Clear History?"].waitForExistence(timeout: 2))
        clickAlertButton("Clear History")
        XCTAssertTrue(app.staticTexts["No transcriptions yet"].waitForExistence(timeout: 2))
    }

    func testHistoryDetailAllowsEditingAndExport() {
        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Export"].exists)

        let detailsButtons = app.windows["History"].buttons.matching(NSPredicate(format: "label == %@", "Details"))
        XCTAssertGreaterThanOrEqual(detailsButtons.count, 2, app.debugDescription)
        detailsButtons.element(boundBy: 1).click()
        let editor = app.textViews["history.detail.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.buttons["Save"].exists)
        XCTAssertTrue(app.buttons["Copy"].exists)
        XCTAssertTrue(app.buttons["Paste"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        app.buttons["Done"].click()
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
        XCTAssertTrue(app.checkBoxes["Experimental background paste"].exists)
        XCTAssertTrue(app.staticTexts["Retained failed audio"].exists)
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

        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Cleaning up"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Pasting"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["Done"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.staticTexts["Mock async paste transcript"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Paste command sent to the current app"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Clipboard restored"].exists)
    }

    func testSimulatedRecordingUsesAsyncPasteWhenEnabled() {
        app.checkBoxes["Paste where recording started"].click()
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Pasting"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Mock async paste transcript"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Pasted into the test target"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Target: GroqTalk UI Test"].exists)
    }

    func testSimulatedRecordingFailureKeepsRetryVisibleInHistory() {
        app.buttons["Simulate Failure"].click()

        XCTAssertTrue(app.staticTexts["Simulated transcription failure"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.staticTexts["Open History for details"].exists)

        app.buttons["History"].click()
        XCTAssertTrue(app.windows["History"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Simulated transcription failure"].waitForExistence(timeout: 2))
    }

    func testFloatingStatusCanBeEnabled() {
        app.checkBoxes["Show floating status"].click()
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Transcribing"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Paste command sent to the current app"].waitForExistence(timeout: 6))
    }

    func testFloatingStatusAutoHidesAfterSuccessWhenEnabled() {
        app.checkBoxes["Show floating status"].click()
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Paste command sent to the current app"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.windows["GroqTalk Floating Status"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Ready"].exists)
        XCTAssertTrue(app.staticTexts["Paste command sent to the current app"].exists)
    }

    func testFloatingStatusIsDisabledByDefault() {
        app.buttons["Simulate Success"].click()

        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.windows["GroqTalk Floating Status"].waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Paste command sent to the current app"].waitForExistence(timeout: 2))
    }

    func testOnboardingNotShownForReturningUser() {
        let app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launch()
        // UI testing mode should skip onboarding
        XCTAssertFalse(app.windows["Welcome to GroqTalk"].exists)
    }

    // MARK: - E2E Transcription (requires GROQ_API_KEY)

    func testE2ETranscription() throws {
        let env = ProcessInfo.processInfo.environment
        let isOpenAICompatibleE2E = env["E2E_TRANSCRIPTION_PROVIDER"] == "openai-compatible"
        let apiKey: String
        if isOpenAICompatibleE2E {
            apiKey = env["E2E_API_KEY"] ?? "local"
        } else if let envKey = env["GROQ_API_KEY"], !envKey.isEmpty {
            apiKey = envKey
        } else if env["RUN_LIVE_GROQ_TESTS"] != "1" {
            throw XCTSkip("Set RUN_LIVE_GROQ_TESTS=1 and GROQ_API_KEY to run live Groq E2E UI test")
        } else if let groqKey = readGroqKeyViaCLI() {
            apiKey = groqKey
        } else {
            throw XCTSkip("GROQ_API_KEY not in keychain — skipping E2E transcription test")
        }

        let resultPath = "/tmp/groqtalk-e2e-result.txt"
        try? FileManager.default.removeItem(atPath: resultPath)

        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-defaults",
            "--e2e-transcribe"
        ]
        app.launchEnvironment["E2E_API_KEY"] = apiKey
        if isOpenAICompatibleE2E {
            app.launchEnvironment["E2E_TRANSCRIPTION_PROVIDER"] = "openai-compatible"
            app.launchEnvironment["E2E_TRANSCRIPTION_BASE_URL"] = env["E2E_TRANSCRIPTION_BASE_URL"] ?? "http://127.0.0.1:8080/v1"
            app.launchEnvironment["E2E_TRANSCRIPTION_MODEL"] = env["E2E_TRANSCRIPTION_MODEL"] ?? "whisper-1"
        } else if let model = env["E2E_TRANSCRIPTION_MODEL"] {
            app.launchEnvironment["E2E_TRANSCRIPTION_MODEL"] = model
        }
        app.launch()

        XCTAssertTrue(controlCenter.waitForExistence(timeout: 10), "App should launch")

        let pasted = app.staticTexts["Paste command sent to the current app"]
        XCTAssertTrue(pasted.waitForExistence(timeout: 30),
                      "E2E transcription should complete and paste within 30 seconds")

        let transcript = (try? String(contentsOfFile: resultPath, encoding: .utf8)) ?? ""
        XCTAssertFalse(transcript.isEmpty, "E2E result file should contain the transcript")

        let expected = "the quick brown fox jumps over the lazy dog"
        let expectedWords = Set(expected.split(separator: " ").map { String($0) })
        let transcriptWords = Set(transcript.lowercased()
            .filter { $0.isLetter || $0.isWhitespace }
            .split(separator: " ")
            .map { String($0) })
        let missingWords = expectedWords.subtracting(transcriptWords)
        XCTAssertTrue(missingWords.count <= 1,
                      "Transcript '\(transcript)' missing words: \(missingWords.sorted()). Expected: '\(expected)'")
    }

    private func readGroqKeyViaCLI() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "com.neonwatty.GroqTalk",
            "-a", "groq-api-key",
            "-w"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return key?.isEmpty == false ? key : nil
        } catch {
            return nil
        }
    }

    private var controlCenter: XCUIElement {
        app.windows["GroqTalk UI Test"].exists
            ? app.windows["GroqTalk UI Test"]
            : app.staticTexts["Ready"]
    }

    private func clickAlertButton(_ title: String) {
        let sheetsButton = app.sheets.firstMatch.buttons[title]
        if sheetsButton.waitForExistence(timeout: 1) {
            sheetsButton.click()
            return
        }

        let dialogsButton = app.dialogs.firstMatch.buttons[title]
        if dialogsButton.waitForExistence(timeout: 1) {
            dialogsButton.click()
            return
        }

        let button = app.buttons[title].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 2), app.debugDescription)
        button.click()
    }

    private func relaunchWithSeededHistory() {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing",
            "--reset-defaults",
            "--seed-history"
        ]
        app.launch()
        XCTAssertTrue(controlCenter.waitForExistence(timeout: 5), app.debugDescription)
    }
}
