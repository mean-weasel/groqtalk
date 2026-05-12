import AppKit
import XCTest
@testable import GroqTalk

final class TextInserterTests: XCTestCase {
    // MARK: - Helpers

    /// Creates a unique, isolated named pasteboard for the test.
    private func makeTestPasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("com.neonwatty.GroqTalkTests.TextInserterTests.\(UUID().uuidString)")
        return NSPasteboard(name: name)
    }

    // MARK: - savePasteboardContents

    func testSavePasteboardContentsPreservesText() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        // Set initial text on the pasteboard.
        pasteboard.clearContents()
        pasteboard.setString("original text", forType: .string)

        // Save contents.
        let saved = TextInserter.savePasteboardContents(pasteboard)

        // Replace with something else.
        pasteboard.clearContents()
        pasteboard.setString("replacement text", forType: .string)

        // Restore and verify.
        let restoreResult = TextInserter.restorePasteboardContents(pasteboard, saved: saved)
        XCTAssertTrue(restoreResult, "Restore should succeed on the happy path")
        let restored = pasteboard.string(forType: .string)

        XCTAssertEqual(restored, "original text", "Restored pasteboard should contain the original text")
    }

    func testSavePasteboardContentsHandlesEmptyPasteboard() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        // Clear the pasteboard before saving.
        pasteboard.clearContents()

        // Saving an empty pasteboard should not crash and should return an empty array.
        let saved = TextInserter.savePasteboardContents(pasteboard)

        XCTAssertTrue(saved.isEmpty, "Saving an empty pasteboard should return an empty array")
    }

    func testSavePasteboardContentsIncludesStringType() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)

        let saved = TextInserter.savePasteboardContents(pasteboard)

        // At minimum the .string type should be captured.
        XCTAssertFalse(saved.isEmpty, "Save should capture at least one type entry")
        let types = saved.map { $0.0 }
        XCTAssertTrue(types.contains(.string), "Saved entries should include the .string type")
    }

    // MARK: - restorePasteboardContents

    func testRestorePasteboardSkipsWhenChangeCountMismatch() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        // Save original content.
        pasteboard.clearContents()
        pasteboard.setString("original text", forType: .string)
        let saved = TextInserter.savePasteboardContents(pasteboard)

        // Place transcribed text and capture the expected change count.
        pasteboard.clearContents()
        pasteboard.setString("transcribed text", forType: .string)
        let restoreChangeCount = pasteboard.changeCount

        // Simulate an external app advancing the change count.
        pasteboard.clearContents()
        pasteboard.setString("external app changed this", forType: .string)

        // Attempt restore with the now-stale change count — should be skipped.
        let result = TextInserter.restorePasteboardContents(
            pasteboard,
            saved: saved,
            onlyIfChangeCount: restoreChangeCount
        )

        XCTAssertFalse(result, "Restore should return false when change count has advanced")
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "external app changed this",
            "Pasteboard should retain the external content when restore is skipped"
        )
    }

    func testRestorePasteboardSucceedsWhenChangeCountMatches() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        // Save original content.
        pasteboard.clearContents()
        pasteboard.setString("original text", forType: .string)
        let saved = TextInserter.savePasteboardContents(pasteboard)

        // Place transcribed text and capture change count.
        pasteboard.clearContents()
        pasteboard.setString("transcribed text", forType: .string)
        let restoreChangeCount = pasteboard.changeCount

        // No external change — restore with matching change count should succeed.
        let result = TextInserter.restorePasteboardContents(
            pasteboard,
            saved: saved,
            onlyIfChangeCount: restoreChangeCount
        )

        XCTAssertTrue(result, "Restore should return true when change count matches")
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "original text",
            "Pasteboard should be restored to the original content"
        )
    }

    func testRestorePasteboardWithNilChangeCountAlwaysRestores() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("original text", forType: .string)
        let saved = TextInserter.savePasteboardContents(pasteboard)

        // Advance change count with new content.
        pasteboard.clearContents()
        pasteboard.setString("something else entirely", forType: .string)

        // Restore with nil expectedChangeCount should always succeed.
        let result = TextInserter.restorePasteboardContents(pasteboard, saved: saved, onlyIfChangeCount: nil)

        XCTAssertTrue(result, "Restore with nil change count should always succeed")
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "original text",
            "Pasteboard should be restored when no change count guard is used"
        )
    }

    func testRestorePasteboardEmptySavedClearsContentsAndReturnsTrue() {
        let pasteboard = makeTestPasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("some text", forType: .string)

        // Restoring empty saved contents should clear and return true.
        let result = TextInserter.restorePasteboardContents(pasteboard, saved: [], onlyIfChangeCount: nil)

        XCTAssertTrue(result, "Restoring empty saved contents should return true")
        XCTAssertNil(
            pasteboard.string(forType: .string),
            "Pasteboard should be empty after restoring empty saved contents"
        )
    }
}
