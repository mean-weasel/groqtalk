import XCTest
@testable import GroqTalk

final class KeychainHelperTests: XCTestCase {
    private var testDirectory: URL!
    private var legacyPlaintextURL: URL {
        testDirectory.appendingPathComponent("api-key")
    }

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GroqTalkKeychainHelperTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        KeychainHelper.storageDirectoryOverride = testDirectory
        KeychainHelper.serviceOverride = "com.neonwatty.GroqTalk.tests.\(UUID().uuidString)"
        KeychainHelper.accountOverride = "groq-api-key-tests"
    }

    override func tearDown() {
        KeychainHelper.delete()
        KeychainHelper.delete(for: .openAICompatible)
        KeychainHelper.storageDirectoryOverride = nil
        KeychainHelper.serviceOverride = nil
        KeychainHelper.accountOverride = nil
        try? FileManager.default.removeItem(at: testDirectory)
        testDirectory = nil
    }

    func testReadReturnsNilWhenEmpty() {
        KeychainHelper.delete()
        XCTAssertNil(KeychainHelper.readApiKey())
    }

    func testSaveAndRead() throws {
        try KeychainHelper.save(apiKey: "test-key-abc")
        XCTAssertEqual(KeychainHelper.readApiKey(), "test-key-abc")
    }

    func testSaveOverwritesExisting() throws {
        try KeychainHelper.save(apiKey: "old-key")
        try KeychainHelper.save(apiKey: "new-key")
        XCTAssertEqual(KeychainHelper.readApiKey(), "new-key")
    }

    func testDeleteRemovesKey() throws {
        try KeychainHelper.save(apiKey: "doomed-key")
        KeychainHelper.delete()
        XCTAssertNil(KeychainHelper.readApiKey())
    }

    func testSaveTrimsWhitespace() throws {
        try KeychainHelper.save(apiKey: "  test-key-with-space\n")
        XCTAssertEqual(KeychainHelper.readApiKey(), "test-key-with-space")
    }

    func testEmptySaveDoesNotCreateKey() throws {
        try KeychainHelper.save(apiKey: "   \n")
        XCTAssertNil(KeychainHelper.readApiKey())
    }

    func testMigratesLegacyPlaintextFileIntoKeychainAndRemovesFile() throws {
        try Data("legacy-key\n".utf8).write(to: legacyPlaintextURL)

        XCTAssertEqual(KeychainHelper.readApiKey(), "legacy-key")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyPlaintextURL.path),
            "Successful migration should remove the plaintext API key file"
        )

        KeychainHelper.storageDirectoryOverride = testDirectory
            .appendingPathComponent("missing-legacy-dir", isDirectory: true)
        XCTAssertEqual(
            KeychainHelper.readApiKey(),
            "legacy-key",
            "Migrated key should be read from Keychain, not from the plaintext file"
        )
    }

    func testInvalidLegacyPlaintextFileIsRemovedAndIgnored() throws {
        try Data(" \n\t".utf8).write(to: legacyPlaintextURL)

        XCTAssertNil(KeychainHelper.readApiKey())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlaintextURL.path))
    }

    func testReadRemovesStaleLegacyPlaintextFileWhenKeychainHasKey() throws {
        try KeychainHelper.save(apiKey: "keychain-key")
        try Data("stale-legacy-key".utf8).write(to: legacyPlaintextURL)

        XCTAssertEqual(KeychainHelper.readApiKey(), "keychain-key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPlaintextURL.path))
    }

    func testProviderScopedKeysDoNotOverwriteEachOther() throws {
        try KeychainHelper.save(apiKey: "groq-key", for: .groq)
        try KeychainHelper.save(apiKey: "local-key", for: .openAICompatible)

        XCTAssertEqual(KeychainHelper.readApiKey(for: .groq), "groq-key")
        XCTAssertEqual(KeychainHelper.readApiKey(for: .openAICompatible), "local-key")
        XCTAssertEqual(KeychainHelper.readApiKey(), "groq-key")
    }

    func testDeletingCustomProviderKeyDoesNotDeleteGroqKey() throws {
        try KeychainHelper.save(apiKey: "groq-key", for: .groq)
        try KeychainHelper.save(apiKey: "local-key", for: .openAICompatible)

        KeychainHelper.delete(for: .openAICompatible)

        XCTAssertEqual(KeychainHelper.readApiKey(for: .groq), "groq-key")
        XCTAssertNil(KeychainHelper.readApiKey(for: .openAICompatible))
    }

    func testLegacyPlaintextMigrationOnlyAppliesToGroqProvider() throws {
        try Data("legacy-key\n".utf8).write(to: legacyPlaintextURL)

        XCTAssertNil(KeychainHelper.readApiKey(for: .openAICompatible))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPlaintextURL.path))
        XCTAssertEqual(KeychainHelper.readApiKey(for: .groq), "legacy-key")
    }
}
