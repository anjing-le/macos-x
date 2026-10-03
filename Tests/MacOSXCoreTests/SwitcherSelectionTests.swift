import XCTest
@testable import MacOSXCore

final class SwitcherSelectionTests: XCTestCase {
    func testRefreshPreservesChosenWindowWhenOrderChanges() {
        var selection = SwitcherSelection(windowIDs: [10, 20, 30], initialOffset: 1)
        selection.replaceWindows([40, 30, 10, 20])
        XCTAssertEqual(selection.selectedWindowID, 20)
        selection.move(by: 1)
        XCTAssertEqual(selection.selectedWindowID, 40)
    }

    func testClosingChosenLastWindowKeepsSelectionInBounds() {
        var selection = SwitcherSelection(windowIDs: [10, 20, 30], initialOffset: -1)
        selection.replaceWindows([10, 20])
        XCTAssertEqual(selection.selectedWindowID, 20)
        selection.replaceWindows([])
        XCTAssertNil(selection.selectedWindowID)
        selection.move(by: Int.min)
        selection.replaceWindows([42])
        XCTAssertEqual(selection.selectedWindowID, 42)
    }

    func testReverseCycleAndDuplicateSnapshots() {
        var selection = SwitcherSelection(windowIDs: [10, 10, 20, 30])
        selection.move(by: -1)
        XCTAssertEqual(selection.selectedWindowID, 30)
        selection.move(by: Int.max)
        XCTAssertNotNil(selection.selectedWindowID)
        XCTAssertEqual(selection.windowIDs, [10, 20, 30])
    }
}
