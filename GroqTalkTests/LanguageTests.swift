import XCTest
@testable import GroqTalk

final class LanguageTests: XCTestCase {
    func testLanguageRawValues() {
        XCTAssertEqual(Language.auto.rawValue, "auto")
        XCTAssertEqual(Language.en.rawValue, "en")
        XCTAssertEqual(Language.ja.rawValue, "ja")
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
}
