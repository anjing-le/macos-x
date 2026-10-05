import XCTest
@testable import MacOSXCore

final class PromptLibraryTests: XCTestCase {
    func testMigrationRetainsFullTextAndStablePositions() {
        let original = ["我的标题\n第二行正文", "(๑•̀ㅂ•́)و✧", "", "  空白开头"]
        let entries = PromptLibrary.migrate(original)
        XCTAssertEqual(entries.count, 10)
        for index in original.indices { XCTAssertEqual(entries[index].content, original[index]) }
        XCTAssertEqual(entries[0].title, "我的标题")
        XCTAssertEqual(entries[2].title, "")
    }
    func testSearchUsesTitlesOnlyAndKeepsOriginalCopyIndices() {
        let entries = PromptLibrary.normalize([.init(title: "邮件回复", content: "正文"), .init(title: "Translate", content: "邮件内容"), .init(title: "邮件空槽", content: "")])
        XCTAssertEqual(PromptLibrary.matches(entries, query: " 邮件 "), [0])
        XCTAssertEqual(PromptLibrary.matches(entries, query: "translate"), [1])
        XCTAssertEqual(PromptLibrary.matches(entries, query: "正文"), [])
        XCTAssertEqual(PromptLibrary.matches(entries, query: " "), [0, 1])
        XCTAssertEqual(PromptLibrary.matches(entries, query: "不存在"), [])
    }
    func testTitlesAndContentBoundedWithoutBreakingUnicode() {
        let entries = PromptLibrary.normalize(Array(repeating: .init(title: String(repeating: "👨‍💻", count: 70), content: String(repeating: "好", count: 17_000)), count: 12))
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(entries[0].title.count, 64)
        XCTAssertEqual(entries[0].content.count, 16_384)
        XCTAssertEqual(PromptLibrary.matches(entries, query: ""), Array(0..<10))
    }
    func testRoundTripKeepsTitlesIndependentFromClipboardContent() throws {
        let entries = PromptLibrary.normalize([.init(title: "回复", content: "你好\n谢谢！")])
        XCTAssertEqual(try JSONDecoder().decode([PromptEntry].self, from: JSONEncoder().encode(entries)), entries)
    }
}
