import XCTest
@testable import MacOSXCore
final class RecordingQualityTests: XCTestCase {
    func testDefaultPersistenceAndInvalidPreference() {
        let suite="cc.anjing.macos-x.quality-test."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        defaults.set(true,forKey:"recording.audio.system")
        XCTAssertEqual(RecordingQuality.load(from:defaults),.ultra)
        defaults.set("unknown",forKey:RecordingQuality.preferenceKey)
        XCTAssertEqual(RecordingQuality.load(from:defaults),.ultra)
        for value in RecordingQuality.allCases {
            value.save(to:defaults)
            XCTAssertEqual(RecordingQuality.load(from:UserDefaults(suiteName:suite)!),value)
            XCTAssertTrue(defaults.bool(forKey:"recording.audio.system"))
        }
        XCTAssertEqual(RecordingQuality.allCases.map(\.maximumDimension),[1920,2560,3840])
        XCTAssertEqual(RecordingQuality.ultra.maximumPixels,3840*2160)
    }
}
