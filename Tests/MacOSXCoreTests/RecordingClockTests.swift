import XCTest
@testable import MacOSXCore

final class RecordingClockTests: XCTestCase {
    func testOnlyConfirmedStreamStartCountsAndStopExcludesSaving() {
        var clock = RecordingClock()
        XCTAssertEqual(clock.elapsed(at: 100), 0)
        clock.begin(at: 100)
        XCTAssertEqual(clock.elapsed(at: 160.5), 60.5)
        clock.stop(at: 160.5)
        XCTAssertEqual(clock.elapsed(at: 200), 60.5)
        clock.stop(at: 200)
        XCTAssertEqual(clock.elapsed(at: 300), 60.5)
        clock.begin(at: 300)
        XCTAssertEqual(clock.elapsed(at: 301), 1)
    }
    func testMinuteHourBoundariesAndInvalidInput() {
        XCTAssertEqual(RecordingClock.display(59.9), "00:59")
        XCTAssertEqual(RecordingClock.display(60), "01:00")
        XCTAssertEqual(RecordingClock.display(3601), "1:00:01")
        XCTAssertEqual(RecordingClock.display(.infinity), "00:00")
        XCTAssertEqual(RecordingClock.display(-10), "00:00")
    }
}
