import XCTest
@testable import MacOSXCore

final class AppLanguageTests: XCTestCase {
    func testOrderedSystemLanguageSelection() {
        XCTAssertEqual(AppLanguage.choose(["zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(AppLanguage.choose(["en-GB", "zh-Hant"]), .english)
        XCTAssertEqual(AppLanguage.choose(["fr-FR", "zh-TW"]), .chinese)
        XCTAssertEqual(AppLanguage.choose(["ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.choose([]), .english)
    }
    func testFormattingPreservesUserContentAndLiteralJSON() {
        let key = "已复制{0}"
        XCTAssertEqual(AppLanguage.localized(key, language: .chinese, arguments: ["{1} 😀 100%"]), "已复制{1} 😀 100%")
        XCTAssertEqual(AppLanguage.localized("{\"title\":\"user text\"}", language: .english), "{\"title\":\"user text\"}")
        XCTAssertEqual(AppLanguage.localized("{0} / {1}", language: .english, arguments: ["{1}", "second"]), "{1} / second")
    }
    func testEnglishCatalogHasNoChineseAndPreservesPlaceholders() throws {
        XCTAssertGreaterThan(AppLanguage.english.count, 500)
        let placeholders = try NSRegularExpression(pattern: "\\{[0-9]+\\}")
        let han = try NSRegularExpression(pattern: "[\\x{3400}-\\x{9fff}]")
        func slots(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        for (key, value) in AppLanguage.english {
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertEqual(han.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value)), 0, key)
            XCTAssertEqual(slots(key), slots(value), key)
        }
    }
}
