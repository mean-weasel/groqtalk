import XCTest
@testable import GroqTalk

@MainActor
final class TranscriptionHistoryTests: XCTestCase {
    private var history: TranscriptionHistory!
    private var testDir: URL!

    override func setUp() {
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("groqtalk-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        history = TranscriptionHistory(storageDirectory: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
    }

    func testStartsEmpty() {
        XCTAssertTrue(history.records.isEmpty)
    }

    func testAddSuccess() {
        history.addSuccess(text: "hello world")
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.text, "hello world")
        XCTAssertNil(history.records.first?.error)
    }

    func testAddFailure() {
        let audioURL = testDir.appendingPathComponent("test.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))

        history.addFailure(error: "API error (429)", audioFileURL: audioURL)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertNil(history.records.first?.text)
        XCTAssertEqual(history.records.first?.error, "API error (429)")
        XCTAssertNotNil(history.records.first?.audioFileURL)
    }

    func testCapsAt500() {
        for i in 0..<505 {
            history.addSuccess(text: "entry \(i)")
        }
        XCTAssertEqual(history.records.count, 500)
        // Oldest entries should be removed — first remaining should be "entry 5"
        XCTAssertEqual(history.records.last?.text, "entry 5")
        // Newest should be "entry 504"
        XCTAssertEqual(history.records.first?.text, "entry 504")
    }

    func testPersistsToDisk() {
        history.addSuccess(text: "persisted")
        // Create a new instance reading from the same directory
        let history2 = TranscriptionHistory(storageDirectory: testDir)
        XCTAssertEqual(history2.records.count, 1)
        XCTAssertEqual(history2.records.first?.text, "persisted")
    }

    func testRetryUpdatesRecord() {
        let audioURL = testDir.appendingPathComponent("retry.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))

        history.addFailure(error: "timeout", audioFileURL: audioURL)
        let recordID = history.records.first!.id

        history.resolveRetry(id: recordID, text: "retried text")

        XCTAssertEqual(history.records.first?.text, "retried text")
        XCTAssertNil(history.records.first?.error)
        XCTAssertNil(history.records.first?.audioFileURL)
        // Audio file should be deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRetryFailureUpdatesError() {
        let audioURL = testDir.appendingPathComponent("retry2.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))

        history.addFailure(error: "timeout", audioFileURL: audioURL)
        let recordID = history.records.first!.id

        history.resolveRetryFailure(id: recordID, error: "still broken")

        XCTAssertEqual(history.records.first?.error, "still broken")
        // Audio file should still exist for another retry attempt
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testRetryableRecord() {
        let audioURL = testDir.appendingPathComponent("retryable.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))

        history.addFailure(error: "fail", audioFileURL: audioURL)
        XCTAssertNotNil(history.retryableRecord)

        history.addSuccess(text: "ok")
        // Most recent is a success — no retryable record
        XCTAssertNil(history.retryableRecord)
    }

    func testCapCleanupDeletesAudioFiles() {
        // Fill history with failures that have audio files
        for i in 0..<TranscriptionHistory.maxRecords {
            let audioURL = testDir.appendingPathComponent("audio-\(i).wav")
            FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
            history.addFailure(error: "fail \(i)", audioFileURL: audioURL)
        }
        // All retained audio files should exist
        XCTAssertEqual(history.records.count, TranscriptionHistory.maxRecords)

        // Adding one more should evict the oldest and delete its audio file
        let evictedURL = testDir.appendingPathComponent("audio-0.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: evictedURL.path))

        history.addSuccess(text: "new")
        XCTAssertEqual(history.records.count, TranscriptionHistory.maxRecords)
        XCTAssertFalse(FileManager.default.fileExists(atPath: evictedURL.path))
    }

    func testDeleteRemovesRecordAndAudioFile() {
        let audioURL = testDir.appendingPathComponent("delete-me.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "fail", audioFileURL: audioURL)
        let id = history.records.first!.id

        history.delete(id: id)

        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testClearRemovesAllRecordsAndAudioFiles() {
        let audioURL = testDir.appendingPathComponent("clear-me.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "fail", audioFileURL: audioURL)
        history.addSuccess(text: "ok")

        history.clear()

        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testUpdateSuccessEditsTranscript() {
        history.addSuccess(text: "original")
        let id = history.records.first!.id

        history.updateSuccess(id: id, text: " edited ")

        XCTAssertEqual(history.records.first?.text, "edited")
    }

    func testUpdateSuccessIgnoresFailures() {
        history.addFailure(error: "fail", audioFileURL: nil)
        let id = history.records.first!.id

        history.updateSuccess(id: id, text: "not allowed")

        XCTAssertEqual(history.records.first?.error, "fail")
        XCTAssertNil(history.records.first?.text)
    }

    func testRetentionLimitTrimsRecordsAndAudio() {
        let audioURL = testDir.appendingPathComponent("old.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "old", audioFileURL: audioURL)
        history.addSuccess(text: "middle")
        history.addSuccess(text: "new")

        history.retentionLimit = 2

        XCTAssertEqual(history.records.count, 2)
        XCTAssertEqual(history.records.last?.text, "middle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testDisabledPersistenceDoesNotStoreRecords() {
        let disabled = TranscriptionHistory(
            storageDirectory: testDir,
            retentionLimit: 500,
            isPersistenceEnabled: false
        )

        disabled.addSuccess(text: "private")

        XCTAssertTrue(disabled.records.isEmpty)
    }

    func testClearRetainedFailedAudioRemovesAudioButKeepsFailureRecord() {
        let audioURL = testDir.appendingPathComponent("retained.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "fail", audioFileURL: audioURL)

        XCTAssertEqual(history.retainedFailedAudioCount, 1)

        history.clearRetainedFailedAudio()

        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.error, "fail")
        XCTAssertNil(history.records.first?.audioFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(history.retainedFailedAudioCount, 0)
    }

    func testExportMarkdownIncludesTranscriptsAndFailures() {
        history.addFailure(error: "timeout", audioFileURL: nil)
        history.addSuccess(text: "hello")

        let markdown = history.exportMarkdown()

        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("hello"))
        XCTAssertTrue(markdown.contains("## Failure"))
        XCTAssertTrue(markdown.contains("timeout"))
    }

    func testExportJSONContainsRecords() throws {
        history.addSuccess(text: "hello")

        let json = try history.exportJSON()

        XCTAssertTrue(json.contains("hello"))
        XCTAssertTrue(json.contains("timestamp"))
    }

    func testPreviewText() {
        history.addSuccess(text: "This is a long transcription that should be truncated for display in the menu")
        let record = history.records.first!
        XCTAssertTrue(record.previewText.count <= 43) // 40 chars + "..."
    }

    // MARK: - Additional edge cases

    func testPreviewTextShortStringNotTruncated() {
        history.addSuccess(text: "short")
        XCTAssertEqual(history.records.first?.previewText, "short")
    }

    func testPreviewTextExactly40CharsNotTruncated() {
        let text = String(repeating: "a", count: 40)
        history.addSuccess(text: text)
        XCTAssertEqual(history.records.first?.previewText, text)
    }

    func testPreviewTextForFailedRecordShowsError() {
        history.addFailure(error: "API error (429)", audioFileURL: nil)
        XCTAssertEqual(history.records.first?.previewText, "API error (429)")
    }

    func testNewestRecordIsFirst() {
        history.addSuccess(text: "first")
        history.addSuccess(text: "second")
        history.addSuccess(text: "third")
        XCTAssertEqual(history.records[0].text, "third")
        XCTAssertEqual(history.records[1].text, "second")
        XCTAssertEqual(history.records[2].text, "first")
    }

    func testRetryableRecordNilWhenNoAudioFile() {
        history.addFailure(error: "fail", audioFileURL: nil)
        XCTAssertNil(history.retryableRecord, "Should not be retryable without audio file")
    }

    func testRetryableRecordNilWhenAudioFileDeleted() {
        let audioURL = testDir.appendingPathComponent("deleted.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "fail", audioFileURL: audioURL)

        // Delete the file externally
        try? FileManager.default.removeItem(at: audioURL)

        XCTAssertNil(history.retryableRecord, "Should not be retryable when file is gone")
    }

    func testRetryableRecordOnlyChecksNewest() {
        // Old failure with audio
        let oldAudio = testDir.appendingPathComponent("old.wav")
        FileManager.default.createFile(atPath: oldAudio.path, contents: Data([0x00]))
        history.addFailure(error: "old fail", audioFileURL: oldAudio)

        // Newer success
        history.addSuccess(text: "ok")

        // Most recent is success — no retryable, even though older failure has audio
        XCTAssertNil(history.retryableRecord)
    }

    func testResolveRetryPreservesTimestamp() {
        let audioURL = testDir.appendingPathComponent("ts.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "fail", audioFileURL: audioURL)

        let originalTimestamp = history.records.first!.timestamp
        let recordID = history.records.first!.id

        // Small delay to ensure timestamps would differ
        Thread.sleep(forTimeInterval: 0.01)
        history.resolveRetry(id: recordID, text: "fixed")

        XCTAssertEqual(history.records.first?.timestamp, originalTimestamp,
                       "Retry should preserve the original timestamp")
    }

    func testResolveRetryPreservesID() {
        let audioURL = testDir.appendingPathComponent("id.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "fail", audioFileURL: audioURL)

        let originalID = history.records.first!.id
        history.resolveRetry(id: originalID, text: "fixed")
        XCTAssertEqual(history.records.first?.id, originalID)
    }

    func testResolveRetryWithInvalidIDDoesNothing() {
        history.addSuccess(text: "original")
        history.resolveRetry(id: UUID(), text: "ghost")
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.text, "original")
    }

    func testPersistencePreservesOrder() {
        history.addSuccess(text: "A")
        history.addSuccess(text: "B")
        history.addSuccess(text: "C")

        let history2 = TranscriptionHistory(storageDirectory: testDir)
        XCTAssertEqual(history2.records.count, 3)
        XCTAssertEqual(history2.records[0].text, "C")
        XCTAssertEqual(history2.records[1].text, "B")
        XCTAssertEqual(history2.records[2].text, "A")
    }

    func testPersistencePreservesFailureState() {
        history.addFailure(error: "timeout", audioFileURL: nil)

        let history2 = TranscriptionHistory(storageDirectory: testDir)
        XCTAssertEqual(history2.records.first?.error, "timeout")
        XCTAssertTrue(history2.records.first!.isFailure)
        XCTAssertNil(history2.records.first?.text)
    }

    func testIsFailureProperty() {
        history.addSuccess(text: "ok")
        XCTAssertFalse(history.records.first!.isFailure)

        history.addFailure(error: "fail", audioFileURL: nil)
        XCTAssertTrue(history.records.first!.isFailure)
    }

    func testRelativeTimestampJustNow() {
        history.addSuccess(text: "now")
        let ts = history.records.first!.relativeTimestamp
        XCTAssertEqual(ts, "just now")
    }

    // MARK: - Bulk delete operations

    func testDeleteOlderThanRemovesOldRecords() {
        history.addSuccess(text: "old record")
        history.deleteOlderThan(Date())
        XCTAssertTrue(history.records.isEmpty)
    }

    func testDeleteOlderThanKeepsRecentRecords() {
        history.addSuccess(text: "recent")
        let cutoff = Date(timeIntervalSinceNow: -86400) // 1 day ago
        history.deleteOlderThan(cutoff)
        XCTAssertEqual(history.records.count, 1) // just added, newer than cutoff
    }

    func testDeleteAllByIDs() {
        history.addSuccess(text: "keep")
        history.addSuccess(text: "delete1")
        history.addSuccess(text: "delete2")
        let ids = Set(history.records.filter { $0.text != "keep" }.map(\.id))
        history.deleteAll(ids: ids)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.text, "keep")
    }

    func testDeleteFilteredRemovesMatchingRecords() {
        history.addSuccess(text: "success")
        history.addFailure(error: "fail", audioFileURL: nil)
        let failures = history.records.filter { $0.isFailure }
        history.deleteFiltered(failures)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertFalse(history.records.first!.isFailure)
    }

    // MARK: - Outcome enum

    func testSuccessRecordHasNoAudioFile() {
        history.addSuccess(text: "test")
        XCTAssertNil(history.records.first?.audioFileURL)
        XCTAssertFalse(history.records.first!.isFailure)
    }

    func testFailureRecordHasNoText() {
        history.addFailure(error: "err", audioFileURL: nil)
        XCTAssertNil(history.records.first?.text)
        XCTAssertTrue(history.records.first!.isFailure)
    }

    func testResolveRetryFailurePreservesAudioFile() {
        let audioURL = testDir.appendingPathComponent("preserve.wav")
        FileManager.default.createFile(atPath: audioURL.path, contents: Data([0x00]))
        history.addFailure(error: "first error", audioFileURL: audioURL)
        let recordID = history.records.first!.id

        history.resolveRetryFailure(id: recordID, error: "second error")

        XCTAssertEqual(history.records.first?.error, "second error")
        XCTAssertEqual(history.records.first?.audioFileURL, audioURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    // MARK: - Corrupted JSON resilience

    func testCorruptedJSONLoadsAsEmpty() {
        let historyFile = testDir.appendingPathComponent("history.json")
        try! Data("not valid json {{{}".utf8).write(to: historyFile)

        let history2 = TranscriptionHistory(storageDirectory: testDir)
        XCTAssertTrue(history2.records.isEmpty,
                      "Corrupted JSON should result in empty records, not a crash")
    }

    func testEmptyFileLoadsAsEmpty() {
        let historyFile = testDir.appendingPathComponent("history.json")
        try! Data().write(to: historyFile)

        let history2 = TranscriptionHistory(storageDirectory: testDir)
        XCTAssertTrue(history2.records.isEmpty)
    }
}
