import XCTest
@testable import MacOSXCore

final class SwitcherLayoutTests: XCTestCase {
    func testAllModeKeepsEveryWindowAndBoundsVisibleThumbnails() {
        for size in [CGSize(width: 320, height: 240), CGSize(width: 1440, height: 900), CGSize(width: 6016, height: 3384)] {
            for count in [1, 9, 11, 256, Int.max] {
                let layout = SwitcherLayout(windowCount: count, available: size, presentation: .all)
                let document = layout.pageSize(visibleCount: count)
                XCTAssertEqual(layout.capacity, min(256, count))
                XCTAssertEqual(layout.pageStart(selectedIndex: 255), 0)
                XCTAssertLessThanOrEqual(layout.size.width, size.width)
                XCTAssertLessThanOrEqual(layout.size.height, size.height)
                let last = layout.card(at: layout.capacity - 1)
                XCTAssertLessThanOrEqual(last.maxY, document.height - 22)
                let height = layout.size.height - 38
                for row in 0..<(layout.capacity + layout.columns - 1) / layout.columns {
                    let y = min(max(0, document.height - 38 - height), CGFloat(row) * (layout.cardSize.height + layout.gap))
                    let indices = layout.visibleIndices(in: CGRect(x: 0, y: y, width: layout.size.width, height: height), count: count)
                    XCTAssertLessThanOrEqual(indices.count, 16)
                }
            }
        }
    }
    func testVerticalNavigationPreservesColumnWithIncompleteLastRow() {
        var selection = SwitcherSelection(windowIDs: Array(1...11), initialOffset: 1)
        selection.moveVertically(direction: -1, columns: 4)
        XCTAssertEqual(selection.selectedIndex, 9)
        selection.moveVertically(direction: 1, columns: 4)
        XCTAssertEqual(selection.selectedIndex, 1)
        selection.select(windowID: 8)
        selection.moveVertically(direction: 1, columns: 4)
        XCTAssertEqual(selection.selectedIndex, 3)
        selection.moveVertically(direction: -1, columns: 4)
        XCTAssertEqual(selection.selectedIndex, 7)
        var single = SwitcherSelection(windowIDs: [1, 2], initialOffset: 1)
        single.moveVertically(direction: 1, columns: 4)
        XCTAssertEqual(single.selectedIndex, 1)
    }
    func testLastPageFitsItsRemainingCards() {
        let layout = SwitcherLayout(windowCount: 11, available: CGSize(width: 1440, height: 900))
        let size = layout.pageSize(visibleCount: 3)
        XCTAssertLessThan(size.width, layout.size.width)
        XCTAssertLessThan(size.height, layout.size.height)
        for index in 0..<3 {
            XCTAssertLessThanOrEqual(layout.card(at: index).maxX, size.width)
            XCTAssertLessThanOrEqual(layout.card(at: index).maxY, size.height - 22)
        }
    }
    func testCardsFitSmallAndLargeScreensWithBoundedPages() {
        for size in [CGSize(width: 320, height: 240), CGSize(width: 640, height: 480),
                     CGSize(width: 960, height: 640), CGSize(width: 1440, height: 900),
                     CGSize(width: 6016, height: 3384)] {
            for count in [1, 2, 7, 8, 9, 256, Int.max] {
                let layout = SwitcherLayout(windowCount: count, available: size)
                XCTAssertTrue((1...8).contains(layout.capacity))
                XCTAssertLessThanOrEqual(layout.size.width, size.width)
                XCTAssertLessThanOrEqual(layout.size.height, size.height)
                for index in 0..<min(count, layout.capacity) {
                    let cell = layout.card(at: index)
                    XCTAssertGreaterThanOrEqual(cell.minX, 0)
                    XCTAssertGreaterThanOrEqual(cell.minY, 0)
                    XCTAssertLessThanOrEqual(cell.maxX, layout.size.width)
                    XCTAssertLessThanOrEqual(cell.maxY, layout.size.height - 22)
                }
            }
        }
    }
    func testKeyboardSelectionPagesWithoutHidingTheSelectedCard() {
        let layout = SwitcherLayout(windowCount: 30, available: CGSize(width: 1440, height: 900))
        XCTAssertEqual(layout.columns, 4)
        XCTAssertEqual(layout.capacity, 8)
        for index in 0..<30 {
            let page = layout.pageStart(selectedIndex: index)
            XCTAssertLessThanOrEqual(page, index)
            XCTAssertLessThan(index, page + layout.capacity)
        }
        XCTAssertEqual(layout.pageStart(selectedIndex: 8), 8)
        XCTAssertEqual(layout.pageStart(selectedIndex: 29), 24)
    }
    func testInvalidOrExtremeSizesCannotOverflowLayoutArithmetic() {
        for size in [CGSize(width: CGFloat.infinity, height: CGFloat.nan), CGSize(width: -1, height: -1),
                     CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)] {
            let layout = SwitcherLayout(windowCount: 0, available: size)
            XCTAssertGreaterThan(layout.capacity, 0)
            XCTAssertTrue(layout.size.width.isFinite && layout.size.height.isFinite)
            XCTAssertLessThan(layout.size.width, 4096)
            XCTAssertLessThan(layout.size.height, 2160)
        }
    }
}
