import XCTest
@testable import MacOSXCore

final class PromptCollectionTests: XCTestCase {
    private func document(_ json:String) throws -> PromptImport { try .parse(Data(json.utf8)) }
    func testLegacyMigrationPreservesTitlesBodiesAndPositions() throws {
        let value = PromptCollection(legacy:[.init(title:"旧标题",content:"第一行\n第二行")])
        try value.validate()
        XCTAssertEqual(value.slots[0],"legacy-1")
        XCTAssertEqual(value.wheelEntries[0].content,"第一行\n第二行")
        XCTAssertEqual(value.slots.count,10)
    }
    func testUnplacedPromptsAreSearchableAndNeverReplaceWheelByDefault() throws {
        let base = PromptCollection(legacy:[.init(title:"常用",content:"保留")])
        let value = try base.merging(document("{\"version\":1,\"prompts\":[{\"title\":\"邮件\",\"content\":\"正文\\n全文\"}]}"))
        XCTAssertEqual(value.slots,base.slots)
        XCTAssertEqual(value.search("邮件"),[1])
        XCTAssertEqual(value.search("正文"),[])
        XCTAssertEqual(value.prompts[1].content,"正文\n全文")
    }
    func testExplicitIdUpdatesAndSlotMovesWithoutDeletingDisplacedPrompt() throws {
        let base = PromptCollection(legacy:[.init(title:"原位置",content:"原正文")])
        let first = try base.merging(document("{\"version\":1,\"prompts\":[{\"id\":\"new\",\"title\":\"新\",\"content\":\"内容\",\"slot\":1}]}"))
        XCTAssertEqual(first.prompts[0].content,"原正文")
        XCTAssertEqual(first.slots[0],"new")
        let changed = try first.merging(document("{\"version\":1,\"prompts\":[{\"id\":\"new\",\"title\":\"更新\",\"content\":\"更新内容\",\"slot\":10}]}"))
        XCTAssertEqual(changed.prompts.count,2)
        XCTAssertNil(changed.slots[0]); XCTAssertEqual(changed.slots[9],"new")
        XCTAssertEqual(changed.prompts[1].content,"更新内容")
    }
    func testNoIdRepeatedImportsAreIdempotent() throws {
        let d = try document("{\"version\":1,\"prompts\":[{\"title\":\"标题\",\"content\":\"内容\"}]}")
        let first = try PromptCollection(legacy:[]).merging(d)
        XCTAssertEqual(try first.merging(d),first)
    }
    func testInvalidProtocolRejectsWholeBatch() throws {
        for s in ["{}","{\"version\":2,\"prompts\":[]}","{\"version\":1,\"prompts\":[{\"title\":\"a\",\"content\":\"b\",\"slot\":11}]}","{\"version\":1,\"prompts\":[{\"title\":\"a\",\"content\":\"b\",\"id\":\"same\"},{\"title\":\"c\",\"content\":\"d\",\"id\":\"same\"}]}","{\"version\":1,\"prompts\":[{\"title\":\"a\",\"content\":\"b\",\"slot\":1},{\"title\":\"c\",\"content\":\"d\",\"slot\":1}]}"] { XCTAssertThrowsError(try document(s)) }
        XCTAssertThrowsError(try PromptImport.parse(Data(repeating:32,count:PromptCollection.byteLimit+1)))
    }
    func testSearchBeyondTenAndRoundTripPreserveAllRecords() throws {
        var value = PromptCollection(legacy:[])
        value.prompts = (0..<31).map { LibraryPrompt(id:"p\($0)",title:"标题\($0)",content:"正文\($0)") }
        value.assign("p30",to:9); try value.validate()
        XCTAssertEqual(value.search("标题"),Array(0..<31))
        XCTAssertEqual(value.search("标题30"),[30])
        XCTAssertEqual(try JSONDecoder().decode(PromptCollection.self,from:JSONEncoder().encode(value)),value)
    }
    func testLimitsAndDanglingSlotsAreRejected() throws {
        var value = PromptCollection(legacy:[])
        value.slots[0] = "missing"; XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try PromptCollection.check(title:String(repeating:"字",count:65),content:""))
        XCTAssertThrowsError(try PromptCollection.check(title:"a",content:String(repeating:"字",count:16385)))
        let example = try PromptImport.parse(Data(PromptImport.example.utf8))
        XCTAssertEqual(example.prompts[0].slot,1)
        XCTAssertNil(example.prompts[1].slot)
    }
    func testIdUpdateKeepsNoIdDeduplicationOfOtherIdenticalRecord() throws {
        var base = PromptCollection(legacy:[])
        base.prompts = [.init(id:"a",title:"same",content:"body"),.init(id:"b",title:"same",content:"body")]
        let updated = try base.merging(document("{\"version\":1,\"prompts\":[{\"id\":\"a\",\"title\":\"changed\",\"content\":\"new\"},{\"title\":\"same\",\"content\":\"body\"}]}"))
        XCTAssertEqual(updated.prompts.count,2)
        XCTAssertEqual(updated.prompts[1].id,"b")
    }
    func testCapacityFailureDoesNotMutateOriginalCollection() throws {
        var base = PromptCollection(legacy:[])
        base.prompts = (0..<500).map { .init(id:"p\($0)",title:"\($0)",content:"body") }
        let before = base
        XCTAssertThrowsError(try base.merging(document("{\"version\":1,\"prompts\":[{\"id\":\"overflow\",\"title\":\"extra\",\"content\":\"body\"}]}")))
        XCTAssertEqual(base,before)
    }
    func testExactDeduplicationDoesNotCollapseDifferentTitleContentPairs() throws {
        var base = PromptCollection(legacy:[])
        base.prompts = [.init(id:"original",title:"a\u{0}b",content:"c")]
        let imported = try document("{\"version\":1,\"prompts\":[{\"title\":\"a\",\"content\":\"b\\u0000c\"}]}")
        XCTAssertEqual(try base.merging(imported).prompts.count,2)
    }
}
