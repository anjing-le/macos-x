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
    func testSlotSwapPreservesBothPromptsAndHiddenPositions() throws {
        var value = PromptCollection(legacy:[.init(title:"一",content:"正文一"),.init(title:"二",content:"正文二")])
        value.assign("legacy-2",to:9)
        let originalPrompts = value.prompts
        XCTAssertTrue(value.swapSlots(0,9))
        XCTAssertEqual(value.slots[0],"legacy-2")
        XCTAssertEqual(value.slots[9],"legacy-1")
        XCTAssertEqual(value.prompts,originalPrompts)
        XCTAssertTrue(value.swapSlots(9,4))
        XCTAssertNil(value.slots[9]); XCTAssertEqual(value.slots[4],"legacy-1")
        try value.validate()
    }
    func testDroppingAssignedLibraryPromptSwapsButUnassignedPromptRetainsDisplacedEntry() throws {
        var value = PromptCollection(legacy:[.init(title:"一",content:"正文一"),.init(title:"二",content:"正文二")])
        XCTAssertTrue(value.place("legacy-1",to:1))
        XCTAssertEqual(Array(value.slots.prefix(2)),["legacy-2","legacy-1"])
        value.prompts.append(.init(id:"unplaced",title:"搜索",content:"完整正文"))
        XCTAssertTrue(value.place("unplaced",to:0))
        XCTAssertEqual(value.slots[0],"unplaced")
        XCTAssertEqual(value.prompts.first(where: { $0.id == "legacy-2" })?.content,"正文二")
        let before = value
        XCTAssertFalse(value.place("unplaced",to:0))
        XCTAssertFalse(value.place("missing",to:0))
        XCTAssertFalse(value.place("legacy-1",to:-1))
        XCTAssertFalse(value.swapSlots(0,10))
        XCTAssertFalse(value.swapSlots(5,6))
        XCTAssertEqual(value,before)
        try value.validate()
    }
    func testDeleteAndUndoRestoreOrderBodyAndFormerEmptySlot() throws {
        var value = PromptCollection(legacy:[.init(title:"一",content:"正文一"),.init(title:"二",content:"正文二")])
        let before = value
        let deleted = try XCTUnwrap(value.remove(id:"legacy-1"))
        XCTAssertNil(value.slots[0]); XCTAssertEqual(value.prompts.map(\.id),["legacy-2"])
        XCTAssertNil(value.remove(id:"missing"))
        try value.restore(deleted)
        XCTAssertEqual(value,before)
    }
    func testUndoDoesNotOverwriteInterveningEditsOrOccupiedFormerSlot() throws {
        var value = PromptCollection(legacy:[.init(title:"一",content:"正文一"),.init(title:"二",content:"正文二")])
        let deleted = try XCTUnwrap(value.remove(id:"legacy-1"))
        value.prompts[0].content = "删除后的编辑"
        value.place("legacy-2",to:0)
        value.prompts.append(.init(id:"new",title:"新",content:"之后新增"))
        try value.restore(deleted)
        XCTAssertEqual(value.prompts.map(\.id),["legacy-1","legacy-2","new"])
        XCTAssertEqual(value.prompts[1].content,"删除后的编辑")
        XCTAssertEqual(value.slots[0],"legacy-2")
        XCTAssertFalse(value.slots.contains("legacy-1"))
        try value.validate()
    }
    func testUndoCollisionAndCapacityFailureAreAtomic() throws {
        var value = PromptCollection(legacy:[.init(title:"一",content:"正文一")])
        let deleted = try XCTUnwrap(value.remove(id:"legacy-1"))
        value.prompts.append(.init(id:"legacy-1",title:"新版本",content:"更新过"))
        var before = value
        XCTAssertThrowsError(try value.restore(deleted))
        XCTAssertEqual(value,before)
        value.prompts = (0..<500).map { .init(id:"p\($0)",title:"\($0)",content:"正文") }
        before = value
        XCTAssertThrowsError(try value.restore(deleted))
        XCTAssertEqual(value,before)
    }
    func testExportImportRoundTripKeepsUnicodeEscapesDraftsAndAllPositions() throws {
        var value = PromptCollection(legacy:[])
        value.prompts = [
            .init(id:"full",title:"标题 / \"引号\"",content:"第一行\n第二行\\\" 🥚\t\u{0}末尾"),
            .init(id:"empty-title",title:"",content:"尚未命名的正文"),
            .init(id:"empty-body",title:"待补全",content:""),
            .init(id:"empty-both",title:"",content:""),
            .init(id:"whitespace-title",title:" \n",content:"内容"),
            .init(id:"unplaced",title:"搜索",content:"不在常用位置")
        ]
        value.assign("full",to:0); value.assign("empty-title",to:9); value.assign("empty-body",to:4); value.assign("empty-both",to:6)
        let exported = try value.exportJSON()
        let imported = try PromptImport.parse(exported)
        XCTAssertNil(imported.prompts[0].draft)
        XCTAssertEqual(imported.prompts[1].draft,true)
        XCTAssertEqual(imported.prompts[2].draft,true)
        XCTAssertEqual(imported.prompts[4].draft,true)
        XCTAssertEqual(imported.prompts[1].slot,10)
        XCTAssertNil(imported.prompts[5].slot)
        XCTAssertEqual(try PromptCollection(legacy:[]).merging(imported),value)
        XCTAssertEqual(try value.merging(imported),value)
    }
    func testEmptyLibraryExportIsValidAndImportDoesNotDeleteExistingPrompts() throws {
        let empty = PromptCollection(legacy:[])
        let imported = try PromptImport.parse(empty.exportJSON())
        XCTAssertTrue(imported.prompts.isEmpty)
        XCTAssertEqual(try empty.merging(imported),empty)
        let existing = PromptCollection(legacy:[.init(title:"保留",content:"正文")])
        XCTAssertEqual(try existing.merging(imported),existing)
    }
    func testNormalImportsStillRejectUnfinishedPromptsWithoutExplicitStableDraft() throws {
        for json in [
            "{\"version\":1,\"prompts\":[{\"title\":\"\",\"content\":\"正文\"}]}",
            "{\"version\":1,\"prompts\":[{\"id\":\"a\",\"title\":\"标题\",\"content\":\"\"}]}",
            "{\"version\":1,\"prompts\":[{\"title\":\"\",\"content\":\"\",\"draft\":true}]}",
            "{\"version\":1,\"prompts\":[{\"id\":\"a\",\"title\":\"\",\"content\":\"\",\"draft\":false}]}",
            "{\"version\":1,\"prompts\":[{\"id\":\"\",\"title\":\"\",\"content\":\"\",\"draft\":true}]}"
        ] { XCTAssertThrowsError(try document(json)) }
        XCTAssertEqual(try document("{\"version\":1,\"prompts\":[{\"id\":\"draft\",\"title\":\"\",\"content\":\"\",\"draft\":true}]}").prompts.count,1)
    }
    func testExportFallsBackToCompactJSONNearFourMegabyteLimit() throws {
        var value = PromptCollection(legacy:[])
        value.prompts = (0..<500).map { .init(id:"p\($0)",title:"\($0)",content:"") }
        let overhead = try JSONEncoder().encode(value).count
        let body = String(repeating:"a",count:(PromptCollection.byteLimit - overhead - 1000) / 500)
        for index in value.prompts.indices { value.prompts[index].content = body }
        try value.validate()
        let exported = try value.exportJSON()
        XCTAssertLessThanOrEqual(exported.count,PromptCollection.byteLimit)
        XCTAssertFalse(exported.contains(10),"Compact export should omit pretty-print newlines to remain within the import limit")
        XCTAssertEqual(try PromptCollection(legacy:[]).merging(PromptImport.parse(exported)),value)
    }
    func testDraftMetadataBeyondTransportLimitFailsWithoutDroppingRecords() throws {
        var value = PromptCollection(legacy:[])
        value.prompts = (0..<500).map { .init(id:"draft\($0)",title:"",content:"") }
        let overhead = try JSONEncoder().encode(value).count
        let body = String(repeating:"a",count:(PromptCollection.byteLimit - overhead - 1000) / 500)
        for index in value.prompts.indices { value.prompts[index].content = body }
        value.assign("draft499",to:9)
        try value.validate()
        let before = value
        XCTAssertThrowsError(try value.exportJSON()) { error in
            XCTAssertEqual(error.localizedDescription,"导出 JSON 超过 4 MB")
        }
        XCTAssertEqual(value,before)
        XCTAssertEqual(value.prompts.count,500)
        XCTAssertEqual(value.slots[9],"draft499")
    }
}
