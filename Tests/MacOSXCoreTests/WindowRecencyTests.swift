import XCTest
@testable import MacOSXCore

final class WindowRecencyTests: XCTestCase {
    func testConfirmedFocusMakesRepeatedQuickSwitchTogglePreviousAndCurrent() {
        var recency = WindowRecency()
        recency.recordFocus(10)
        recency.recordFocus(20)
        var selection = SwitcherSelection(windowIDs: recency.ordered(availableIDs: [10, 20, 30]), initialOffset: 1)
        XCTAssertEqual(selection.selectedWindowID, 10)
        // Only successful, confirmed focus changes MRU.
        recency.recordFocus(10)
        selection = SwitcherSelection(windowIDs: recency.ordered(availableIDs: [10, 20, 30]), initialOffset: 1)
        XCTAssertEqual(selection.selectedWindowID, 20)
        recency.recordFocus(20)
        XCTAssertEqual(recency.ordered(availableIDs: [10, 20, 30]), [20, 10, 30])
    }

    func testCancelledSelectionDoesNotChangeRecency() {
        var recency = WindowRecency()
        recency.recordFocus(3); recency.recordFocus(2); recency.recordFocus(1)
        var selection = SwitcherSelection(windowIDs: recency.ordered(availableIDs: [1, 2, 3]))
        selection.move(by: 2)
        XCTAssertEqual(selection.selectedWindowID, 3)
        XCTAssertEqual(recency.windowIDs, [1, 2, 3])
    }

    func testDestroyedWindowAndReusedIdentityDoNotInheritOldRecency() {
        var recency = WindowRecency()
        recency.recordFocus(30); recency.recordFocus(20); recency.recordFocus(10)
        recency.retain(liveIDs: [10, 30])
        XCTAssertEqual(recency.ordered(availableIDs: [10, 30, 20]), [10, 30, 20])
    }

    func testRecencyIsBoundedAndUnknownOrderStable() {
        var recency = WindowRecency(capacity: 2)
        for id: UInt32 in [1, 2, 3, 3, 0] { recency.recordFocus(id) }
        XCTAssertEqual(recency.windowIDs, [3, 2])
        XCTAssertEqual(recency.ordered(availableIDs: [0, 5, 3, 5, 4, 2]), [3, 2, 5, 4])
    }
}
