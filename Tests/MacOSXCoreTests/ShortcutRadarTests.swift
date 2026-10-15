import XCTest
@testable import MacOSXCore

final class ShortcutRadarTests: XCTestCase {
    private func use(_ key: String = "R", _ modifiers: UInt8 = 5, app: String = "A", action: String = "录屏",
                     scope: RadarUse.Scope = .application, evidence: RadarUse.Evidence = .menu) -> RadarUse {
        .init(chord: .init(key: key, modifiers: modifiers), appID: app, appName: app,
              action: action, path: "工具 › " + action, scope: scope, evidence: evidence)
    }
    func testSymbolAndTypedChordSearchAreEquivalent() {
        let expected = RadarChord(key: "R", modifiers: 5)
        for query in ["⌃⇧R", "ctrl+shift+r", "Control + Shift + R", " Shift + Control + R "] {
            XCTAssertEqual(RadarChord.parse(query), expected, query)
        }
        XCTAssertEqual(RadarChord.parse("option+command+left"), .init(key: "←", modifiers: 10))
        XCTAssertEqual(RadarChord.parse("F3"), .init(key: "F3", modifiers: 0))
        XCTAssertEqual(RadarChord.parse("cmd+return"), .init(key: "↩", modifiers: 8))
        XCTAssertEqual(RadarChord.parse("fn+a"), .init(key: "A", modifiers: 16))
        XCTAssertEqual(RadarChord.parse("⌃fnF3"), .init(key: "F3", modifiers: 17))
        XCTAssertNotEqual(RadarChord(key: "A", modifiers: 16), .init(key: "A", modifiers: 0))
        for query in ["录屏", "commandline", "alternate", "Control +", "F21", "Control Shift many keys"] {
            XCTAssertNil(RadarChord.parse(query), query)
        }
    }
    func testContextualReuseIsNotAutomaticallyAConflict() {
        let copy = [use("C", 8, app: "A", action: "复制"), use("C", 8, app: "B", action: "复制")]
        let group = RadarIndex.groups(copy).first!
        XCTAssertEqual(group.uses.count, 2)
        XCTAssertFalse(group.isPotentialConflict)
        XCTAssertFalse(group.hasGlobal)
        XCTAssertTrue(group.explanation.contains("不直接视为冲突"))
        let configured = use("C", 8, app: "macos-x", scope: .global, evidence: .configuration)
        XCTAssertTrue(RadarIndex.groups(copy + [configured]).first!.isPotentialConflict)
        XCTAssertFalse(configured.isConfirmed)
    }
    func testCountsDedupeAndSortDescendingBeforeSeverity() {
        let local = (1...3).map { use("C", 8, app: "App\($0)", action: "复制") }
        let global = use(app: "system", scope: .global, evidence: .system)
        let uses = local + [global, use(), use(), local[0]]
        let groups = RadarIndex.groups(uses)
        XCTAssertEqual(groups.map(\.uses.count), [3, 2])
        XCTAssertFalse(groups[0].isPotentialConflict)
        XCTAssertTrue(groups[1].isPotentialConflict)
        XCTAssertTrue(global.isConfirmed)
    }
    func testExactChordDoesNotMatchNeighboringModifierCombinations() {
        let uses = [use(), use("R", 13), use("T", 5)]
        XCTAssertEqual(RadarIndex.groups(uses, query: "Ctrl+Shift+R").map(\.chord), [.init(key: "R", modifiers: 5)])
    }
    func testUseSearchRetainsOtherSourcesOfMatchingChord() {
        let entries = [use(app: "飞书"), use(app: "钉钉"), use("T", 5, app: "Other", action: "其他")]
        XCTAssertEqual(RadarIndex.groups(entries, query: "飞书 录屏").first?.uses.count, 2)
        XCTAssertEqual(RadarIndex.groups(entries, query: "录屏").count, 1)
        XCTAssertTrue(RadarIndex.groups(entries, query: "未发现的用途").isEmpty)
    }
    func testFilterPreservesScopesAndEmptyResults() {
        let entries = [use(), use(app: "system", scope: .global, evidence: .system)]
        XCTAssertEqual(RadarIndex.groups(entries, filter: .global).first?.uses.map(\.appID), ["system"])
        XCTAssertEqual(RadarIndex.groups(entries, filter: .application).first?.uses.map(\.appID), ["A"])
        XCTAssertTrue(RadarIndex.groups([], query: "F3").isEmpty)
    }
    func testRawInputAndSourceStringsAreBounded() {
        let use = RadarUse(chord: .init(key: "F3", modifiers: 0), appID: String(repeating: "a", count: 400),
            appName: String(repeating: "b", count: 400), action: String(repeating: "c", count: 400),
            path: String(repeating: "d", count: 500), scope: .global, evidence: .registration)
        XCTAssertEqual(use.appID.count, 256); XCTAssertEqual(use.appName.count, 100)
        XCTAssertEqual(use.action.count, 160); XCTAssertEqual(use.path.count, 320)
        let entries = (0...5_000).map { i in self.use("F3", 0, app: "app\(i)") }
        XCTAssertEqual(RadarIndex.groups(entries).first?.uses.count, RadarIndex.maximumUses)
    }
}
