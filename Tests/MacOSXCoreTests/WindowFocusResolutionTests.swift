import XCTest
@testable import MacOSXCore

final class WindowFocusResolutionTests: XCTestCase {
    func testPartialReadKeepsConfirmedFocusAndAlternatesBack() {
        var recency = WindowRecency()
        recency.recordFocus(10); recency.recordFocus(20)
        let focus = WindowFocusResolution.resolve(observed: nil, confirmed: 20,
            foregroundPID: 2, owners: [10: 1, 20: 2], visibleIDs: [10, 20])
        let selection = SwitcherSelection(windowIDs: recency.ordered(availableIDs: [10, 20]),
                                          focusedWindowID: focus, reverse: false)
        XCTAssertEqual(focus, 20)
        XCTAssertEqual(selection.selectedWindowID, 10)
    }

    func testFallbackCannotClaimOtherAppClosedOrOffScreenWindow() {
        XCTAssertNil(WindowFocusResolution.resolve(observed: nil, confirmed: 20,
            foregroundPID: 1, owners: [20: 2], visibleIDs: [20]))
        XCTAssertNil(WindowFocusResolution.resolve(observed: nil, confirmed: 20,
            foregroundPID: 2, owners: [:], visibleIDs: [20]))
        XCTAssertNil(WindowFocusResolution.resolve(observed: nil, confirmed: 20,
            foregroundPID: 2, owners: [20: 2], visibleIDs: []))
        XCTAssertEqual(WindowFocusResolution.resolve(observed: 21, confirmed: 20,
            foregroundPID: 2, owners: [20: 2, 21: 2], visibleIDs: [20, 21]), 21)
    }
}
