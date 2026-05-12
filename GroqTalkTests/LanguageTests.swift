import XCTest
@testable import GroqTalk

final class LanguageTests: XCTestCase {
    func testLanguageRawValues() {
        XCTAssertEqual(Language.auto.rawValue, "auto")
        XCTAssertEqual(Language.en.rawValue, "en")
        XCTAssertEqual(Language.es.rawValue, "es")
        XCTAssertEqual(Language.fr.rawValue, "fr")
        XCTAssertEqual(Language.de.rawValue, "de")
        XCTAssertEqual(Language.pt.rawValue, "pt")
        XCTAssertEqual(Language.it.rawValue, "it")
        XCTAssertEqual(Language.ja.rawValue, "ja")
        XCTAssertEqual(Language.zh.rawValue, "zh")
        XCTAssertEqual(Language.ko.rawValue, "ko")
        XCTAssertEqual(Language.hi.rawValue, "hi")
        XCTAssertEqual(Language.ar.rawValue, "ar")
        XCTAssertEqual(Language.ru.rawValue, "ru")
    }

    func testLanguageDisplayNames() {
        XCTAssertEqual(Language.auto.displayName, "Auto-detect")
        XCTAssertEqual(Language.en.displayName, "English")
        XCTAssertEqual(Language.es.displayName, "Spanish")
        XCTAssertEqual(Language.fr.displayName, "French")
        XCTAssertEqual(Language.de.displayName, "German")
        XCTAssertEqual(Language.pt.displayName, "Portuguese")
        XCTAssertEqual(Language.it.displayName, "Italian")
        XCTAssertEqual(Language.ja.displayName, "Japanese")
        XCTAssertEqual(Language.zh.displayName, "Chinese")
        XCTAssertEqual(Language.ko.displayName, "Korean")
        XCTAssertEqual(Language.hi.displayName, "Hindi")
        XCTAssertEqual(Language.ar.displayName, "Arabic")
        XCTAssertEqual(Language.ru.displayName, "Russian")
    }

    func testLanguageCaseIterable() {
        XCTAssertEqual(Language.allCases.count, 13)
    }

    func testLanguageCodableRoundTrip() throws {
        let original = Language.ja
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Language.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMultipartBodyOmitsLanguageWhenAuto() throws {
        let service = TranscriptionService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-lang.wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL, model: "m", format: .wav,
            language: .auto, boundary: "b"
        )
        let bodyString = String(data: body, encoding: .utf8)!
        XCTAssertFalse(bodyString.contains("name=\"language\""),
                       "Auto-detect should not include language field")
    }

    func testMultipartBodyIncludesLanguageWhenSet() throws {
        let service = TranscriptionService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-lang2.wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let body = try TranscriptionService.buildMultipartBody(
            audioFileURL: tempURL, model: "m", format: .wav,
            language: .ja, boundary: "b"
        )
        let bodyString = String(data: body, encoding: .utf8)!
        XCTAssertTrue(bodyString.contains("name=\"language\"\r\n\r\nja"),
                      "Japanese should send language=ja")
    }

    @MainActor
    func testAppStateDefaultLanguageIsAuto() {
        UserDefaults.standard.removeObject(forKey: "language")
        let state = AppState()
        XCTAssertEqual(state.selectedLanguage, .auto)
    }

    @MainActor
    func testAppStateLanguagePersists() {
        UserDefaults.standard.removeObject(forKey: "language")
        let state = AppState()
        state.selectedLanguage = .ja
        XCTAssertEqual(state.selectedLanguage, .ja)

        let state2 = AppState()
        XCTAssertEqual(state2.selectedLanguage, .ja)
        UserDefaults.standard.removeObject(forKey: "language")
    }

    @MainActor
    func testAppStateInvalidLanguageFallsBackToAuto() {
        UserDefaults.standard.set("invalid", forKey: "language")
        let state = AppState()
        XCTAssertEqual(state.selectedLanguage, .auto)
        UserDefaults.standard.removeObject(forKey: "language")
    }

    func testMultipartBodyLanguageFieldPerLanguage() throws {
        let service = TranscriptionService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-lang3.wav")
        try Data([0x00]).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        for lang in Language.allCases where lang != .auto {
            let body = try TranscriptionService.buildMultipartBody(
                audioFileURL: tempURL, model: "m", format: .wav,
                language: lang, boundary: "b"
            )
            let bodyString = String(data: body, encoding: .utf8)!
            XCTAssertTrue(
                bodyString.contains("name=\"language\"\r\n\r\n\(lang.rawValue)"),
                "\(lang.displayName) should send language=\(lang.rawValue)"
            )
        }
    }
}
