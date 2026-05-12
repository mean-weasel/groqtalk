import AppKit
import XCTest
@testable import GroqTalk

final class BackgroundPasteTests: XCTestCase {
    func testAttemptReturnsFalseWhenWindowIDIsNil() async {
        let target = PasteTarget(windowElement: nil, windowID: nil, pid: 999, appName: "App")
        let result = await BackgroundPaste.attempt(
            text: "hello", target: target, keepOnClipboard: false
        )
        XCTAssertEqual(result, .failed)
    }

    func testAttemptReturnsFalseForInvalidPid() async {
        let target = PasteTarget(windowElement: nil, windowID: 12345, pid: 0, appName: "")
        let result = await BackgroundPaste.attempt(
            text: "hello", target: target, keepOnClipboard: false
        )
        XCTAssertEqual(result, .failed)
    }

    func testAttemptReturnsFalseForTerminatedProcess() async {
        // pid 99999 is almost certainly not running
        let target = PasteTarget(windowElement: nil, windowID: 12345, pid: 99999, appName: "Ghost")
        let result = await BackgroundPaste.attempt(
            text: "hello", target: target, keepOnClipboard: false
        )
        XCTAssertEqual(result, .failed)
    }

    func testAttemptDoesNotUseSkyLightUnlessExplicitlyEnabled() async {
        let target = PasteTarget(
            windowElement: nil,
            windowID: 12345,
            pid: ProcessInfo.processInfo.processIdentifier,
            appName: "GroqTalkTests"
        )

        let result = await BackgroundPaste.attempt(
            text: "hello",
            target: target,
            keepOnClipboard: false,
            allowSkyLight: false
        )

        XCTAssertEqual(result, .failed)
    }

    func testBackgroundPasteNoLongerUsesArbitraryFirstTextField() async {
        let target = PasteTarget(
            windowElement: nil,
            windowID: nil,
            pid: ProcessInfo.processInfo.processIdentifier,
            appName: "GroqTalkTests"
        )

        let result = await BackgroundPaste.attempt(
            text: "hello",
            target: target,
            keepOnClipboard: false
        )

        XCTAssertEqual(result, .failed)
    }

    func testGuardedRestoreSkipsWhenClipboardChangesDuringPasteDelay() {
        let pasteboardName = NSPasteboard.Name("GroqTalkTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)
        let saved = TextInserter.savePasteboardContents(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("groqtalk paste text", forType: .string)
        let restoreChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("user copied something else", forType: .string)

        let restored = TextInserter.restorePasteboardContents(
            pasteboard,
            saved: saved,
            onlyIfChangeCount: restoreChangeCount
        )

        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "user copied something else")
    }

    func testGuardedRestoreRestoresWhenClipboardIsStillPastePayload() {
        let pasteboardName = NSPasteboard.Name("GroqTalkTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: pasteboardName)
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)
        let saved = TextInserter.savePasteboardContents(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("groqtalk paste text", forType: .string)
        let restoreChangeCount = pasteboard.changeCount

        let restored = TextInserter.restorePasteboardContents(
            pasteboard,
            saved: saved,
            onlyIfChangeCount: restoreChangeCount
        )

        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    func testClipboardFallbackLeavesTranscriptOnClipboardWhenKeepOff() async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard", forType: .string)

        let target = PasteTarget(windowElement: nil, windowID: nil, pid: 99999, appName: "Ghost")
        let delivery = await TextInserter().insertAtTarget(
            text: "private transcript",
            target: target,
            keepOnClipboard: false
        )

        XCTAssertEqual(delivery, .clipboardFallback)
        XCTAssertEqual(pasteboard.string(forType: .string), "private transcript")
    }

    func testClipboardFallbackKeepsTranscriptWhenKeepOnClipboardIsEnabled() async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard", forType: .string)

        let target = PasteTarget(windowElement: nil, windowID: nil, pid: 99999, appName: "Ghost")
        let delivery = await TextInserter().insertAtTarget(
            text: "private transcript",
            target: target,
            keepOnClipboard: true
        )

        XCTAssertEqual(delivery, .clipboardFallback)
        XCTAssertEqual(pasteboard.string(forType: .string), "private transcript")
    }

    func testCommandPostedDeliveryMessagesDoNotClaimVerifiedPaste() {
        XCTAssertEqual(
            PasteDelivery.currentAppCommandPosted.userMessage,
            "Paste command sent to the current app"
        )
        XCTAssertEqual(
            PasteDelivery.asyncCommandPosted.userMessage,
            "Paste command sent to the original app"
        )
        XCTAssertEqual(
            PasteDelivery.asyncChoreography.userMessage,
            "Paste command sent to the original app"
        )
    }

    func testCommandPostedDeliveryLabelsAreDistinctFromVerifiedPaste() {
        XCTAssertEqual(PasteDelivery.currentAppCommandPosted.label, "current app command posted")
        XCTAssertEqual(PasteDelivery.asyncCommandPosted.label, "original app command posted")
        XCTAssertEqual(PasteDelivery.asyncBackground.label, "original app")
        XCTAssertEqual(PasteDelivery.clipboardFallback.label, "clipboard")
    }
}
