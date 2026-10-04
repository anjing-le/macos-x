import XCTest
@testable import MacOSXCore

final class PhraseWheelGeometryTests: XCTestCase {
    private typealias G = PhraseWheelGeometry

    func testCentralCircleHasTenDistinctDirectionsAndDeadZone() throws {
        let anchor = G.Point(x: 640, y: 400)
        let layout = try XCTUnwrap(G.layout(anchor: anchor, screens: [G.Rect(x: 0, y: 0, width: 1280, height: 800)]))
        XCTAssertFalse(layout.isFan)
        XCTAssertEqual(layout.anchor, anchor)
        XCTAssertNil(layout.selection(at: anchor))
        XCTAssertNil(layout.selection(at: G.Point(x: 640, y: 422)))
        for (index, slot) in layout.slots.enumerated() {
            XCTAssertEqual(layout.selection(at: slot.center), index)
        }
        XCTAssertGreaterThan(layout.slots[0].center.y, anchor.y)
    }

    func testEdgesAndCornersKeepAllLabelsVisibleAndNonoverlapping() throws {
        let screen = G.Rect(x: 0, y: 0, width: 640, height: 480)
        for x in [0.0, 1, 20, 100, 320, 540, 620, 639, 640] {
            for y in [0.0, 1, 20, 100, 240, 380, 460, 479, 480] {
                let anchor = G.Point(x: x, y: y)
                let layout = try XCTUnwrap(G.layout(anchor: anchor, screens: [screen]), "anchor: \(anchor)")
                XCTAssertEqual(layout.anchor, anchor)
                XCTAssertEqual(layout.slots.count, 10)
                XCTAssertTrue(screen.contains(layout.panelFrame))
                for (index, slot) in layout.slots.enumerated() {
                    XCTAssertTrue(screen.contains(slot.frame))
                    XCTAssertTrue(layout.panelFrame.contains(slot.frame))
                    XCTAssertEqual(layout.selection(at: slot.center), index)
                    for other in layout.slots.dropFirst(index + 1) {
                        XCTAssertTrue(abs(slot.center.x - other.center.x) >= 66 || abs(slot.center.y - other.center.y) >= 36)
                    }
                }
            }
        }
    }

    func testNegativeScreenCoordinatesAndCommitCrossing() throws {
        let left = G.Rect(x: -1440, y: -200, width: 1440, height: 900)
        let right = G.Rect(x: 0, y: 0, width: 1920, height: 1080)
        let anchor = G.Point(x: -1440, y: -200)
        let layout = try XCTUnwrap(G.layout(anchor: anchor, screens: [right, left]))
        XCTAssertEqual(layout.screen, left)
        XCTAssertEqual(layout.anchor, anchor)
        XCTAssertTrue(layout.isFan)
        XCTAssertNil(layout.selection(at: G.Point(x: -1500, y: -260)))
        let slot = layout.slots[4]
        XCTAssertFalse(layout.crossedCommitRadius(previousDistance: 0, at: anchor, slot: 4))
        XCTAssertTrue(layout.crossedCommitRadius(previousDistance: slot.commitRadius - 1, at: slot.center, slot: 4))
        XCTAssertFalse(layout.crossedCommitRadius(previousDistance: slot.commitRadius + 1, at: slot.center, slot: 4))
        XCTAssertFalse(layout.crossedCommitRadius(previousDistance: .nan, at: slot.center, slot: 4))
    }

    func testInvalidScreenOrAnchorDoesNotProduceAnUnboundedPanel() {
        XCTAssertNil(G.layout(anchor: G.Point(x: .infinity, y: 0), screens: []))
        XCTAssertNil(G.layout(anchor: G.Point(x: 0, y: 0), screens: []))
        XCTAssertNil(G.layout(anchor: G.Point(x: 1000, y: 1000), screens: [G.Rect(x: 0, y: 0, width: 640, height: 480)]))
    }
}
