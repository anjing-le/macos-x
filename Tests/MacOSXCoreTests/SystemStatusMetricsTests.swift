import XCTest
@testable import MacOSXCore

final class SystemStatusMetricsTests: XCTestCase {
    private func cpu(_ user: UInt32, _ idle: UInt32, system: UInt32 = 0, nice: UInt32 = 0) -> SystemCPUCounter {
        .init(user: user, system: system, idle: idle, nice: nice)
    }
    private func network(_ received: UInt64, _ sent: UInt64, name: String = "en0", index: UInt32 = 4) -> SystemNetworkCounter {
        .init(interfaceName: name, interfaceIndex: index, receivedBytes: received, sentBytes: sent)
    }
    private func sample(_ accumulator: inout SystemStatusAccumulator, time: Double, cpu: SystemCPUCounter? = nil, network: SystemNetworkCounter? = nil) -> SystemStatusSnapshot {
        accumulator.sample(timestamp: time, cpu: cpu, memory: nil, network: network)
    }

    func testFirstSampleEstablishesBaselineRatherThanShowingBootAverage() {
        var accumulator = SystemStatusAccumulator()
        let first = sample(&accumulator, time: 100, cpu: cpu(900_000, 100_000), network: network(9_000_000, 6_000_000))
        XCTAssertNil(first.cpuPercent)
        XCTAssertNil(first.network?.downloadBytesPerSecond)
        XCTAssertNil(first.network?.uploadBytesPerSecond)
        let second = sample(&accumulator, time: 102, cpu: cpu(900_020, 100_075, system: 4, nice: 1), network: network(9_008_000, 6_002_000))
        XCTAssertEqual(second.cpuPercent!, 25, accuracy: 0.000_001)
        XCTAssertEqual(second.network?.downloadBytesPerSecond, 4_000)
        XCTAssertEqual(second.network?.uploadBytesPerSecond, 1_000)
    }

    func testCPUCounterWrapAndGenuineIdle() {
        var accumulator = SystemStatusAccumulator()
        _ = sample(&accumulator, time: 1, cpu: cpu(.max - 3, .max - 5))
        let wrapped = sample(&accumulator, time: 2, cpu: cpu(8, 6))
        XCTAssertEqual(wrapped.cpuPercent!, 50, accuracy: 0.000_001)
        let idle = sample(&accumulator, time: 3, cpu: cpu(8, 106))
        XCTAssertEqual(idle.cpuPercent, 0)
        let unchanged = sample(&accumulator, time: 4, cpu: cpu(8, 106))
        XCTAssertNil(unchanged.cpuPercent)
    }

    func testFailuresAndResetReestablishIndependentBaselines() {
        var accumulator = SystemStatusAccumulator()
        _ = sample(&accumulator, time: 1, cpu: cpu(100, 100), network: network(100, 100))
        let failed = sample(&accumulator, time: 2)
        XCTAssertNil(failed.cpuPercent)
        XCTAssertNil(failed.network)
        let recovery = sample(&accumulator, time: 3, cpu: cpu(500, 500), network: network(500, 500))
        XCTAssertNil(recovery.cpuPercent)
        XCTAssertNil(recovery.network?.downloadBytesPerSecond)
        XCTAssertEqual(sample(&accumulator, time: 4, cpu: cpu(550, 550), network: network(600, 600)).cpuPercent, 50)
        accumulator.reset()
        let restarted = sample(&accumulator, time: 5, cpu: cpu(600, 600), network: network(700, 700))
        XCTAssertNil(restarted.cpuPercent)
        XCTAssertNil(restarted.network?.uploadBytesPerSecond)
    }

    func testRatesUseActualElapsedTimeAndZeroIsAValidMeasurement() {
        var accumulator = SystemStatusAccumulator()
        _ = sample(&accumulator, time: 10, network: network(0, 0))
        let irregular = sample(&accumulator, time: 13.25, network: network(3_250, 650))
        XCTAssertEqual(irregular.network?.downloadBytesPerSecond, 1_000)
        XCTAssertEqual(irregular.network?.uploadBytesPerSecond, 200)
        let idle = sample(&accumulator, time: 15.5, network: network(3_250, 650))
        XCTAssertEqual(idle.network?.downloadBytesPerSecond, 0)
        XCTAssertEqual(idle.network?.uploadBytesPerSecond, 0)
    }

    func testInterfaceSwitchRecreationAndCounterResetDiscardRates() {
        var accumulator = SystemStatusAccumulator()
        _ = sample(&accumulator, time: 1, network: network(10_000, 20_000))
        let changed = sample(&accumulator, time: 2, network: network(200, 400, name: "en1", index: 5))
        XCTAssertEqual(changed.network?.interfaceName, "en1")
        XCTAssertNil(changed.network?.downloadBytesPerSecond)
        let recreated = sample(&accumulator, time: 3, network: network(300, 500, name: "en1", index: 6))
        XCTAssertNil(recreated.network?.downloadBytesPerSecond)
        let reset = sample(&accumulator, time: 4, network: network(10, 700, name: "en1", index: 6))
        XCTAssertNil(reset.network?.downloadBytesPerSecond)
        XCTAssertNil(reset.network?.uploadBytesPerSecond)
        let recovered = sample(&accumulator, time: 6, network: network(210, 900, name: "en1", index: 6))
        XCTAssertEqual(recovered.network?.downloadBytesPerSecond, 100)
        XCTAssertEqual(recovered.network?.uploadBytesPerSecond, 100)
    }

    func testInvalidTimesAndInterfacesNeverProduceNonFiniteRates() {
        var accumulator = SystemStatusAccumulator()
        _ = sample(&accumulator, time: 2, cpu: cpu(100, 100), network: network(1_000, 1_000))
        let sameTime = sample(&accumulator, time: 2, cpu: cpu(200, 200), network: network(2_000, 2_000))
        XCTAssertNil(sameTime.cpuPercent)
        XCTAssertNil(sameTime.network?.downloadBytesPerSecond)
        let backward = sample(&accumulator, time: 1, cpu: cpu(300, 300), network: network(3_000, 3_000))
        XCTAssertNil(backward.cpuPercent)
        XCTAssertNil(backward.network?.downloadBytesPerSecond)
        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            let value = sample(&accumulator, time: invalid, cpu: cpu(100, 100), network: network(100, 100))
            XCTAssertTrue(value.timestamp.isFinite)
            XCTAssertNil(value.cpuPercent)
            XCTAssertNil(value.network?.downloadBytesPerSecond)
            XCTAssertFalse(value.issues.isEmpty)
        }
        XCTAssertNil(sample(&accumulator, time: 10, network: network(100, 100, name: "")).network)
        XCTAssertNil(sample(&accumulator, time: 11, network: network(100, 100, index: 0)).network)
        accumulator.reset()
        _ = sample(&accumulator, time: 0, network: network(0, 0))
        let overflowingRate = sample(&accumulator, time: Double.leastNonzeroMagnitude, network: network(.max, .max))
        XCTAssertNil(overflowingRate.network?.downloadBytesPerSecond)
        XCTAssertNil(overflowingRate.network?.uploadBytesPerSecond)
    }

    func testMemoryFormulaExcludesReclaimableCacheAndKeepsCompressionAndSwap() {
        let pages = SystemMemoryPages(totalBytes: 1_048_576, pageSize: 4_096, active: 100, inactive: 50,
                                      speculative: 10, wired: 20, compressed: 5, purgeable: 10, external: 30, swapBytes: 123_456)
        XCTAssertEqual(pages.status(), .init(usedBytes: 145 * 4_096, totalBytes: 1_048_576, compressedBytes: 5 * 4_096, swapBytes: 123_456))
        var reclaimable = pages
        reclaimable.purgeable = 1_000
        XCTAssertEqual(reclaimable.status()?.usedBytes, 0)
        var oversized = pages
        oversized.active = 1_000
        XCTAssertEqual(oversized.status()?.usedBytes, oversized.totalBytes)
    }

    func testMemoryRejectsImpossibleInputAndIntegerOverflow() {
        let valid = SystemMemoryPages(totalBytes: 1_024, pageSize: 4, active: 10, inactive: 0,
                                      speculative: 0, wired: 0, compressed: 1, purgeable: 0, external: 0, swapBytes: 0)
        var changed = valid
        changed.totalBytes = 0
        XCTAssertNil(changed.status())
        changed = valid; changed.pageSize = 0
        XCTAssertNil(changed.status())
        changed = valid; changed.active = .max; changed.inactive = 1
        XCTAssertNil(changed.status())
        changed = valid; changed.purgeable = .max; changed.external = 1
        XCTAssertNil(changed.status())
        changed = valid; changed.pageSize = .max
        XCTAssertNil(changed.status())
        changed = valid; changed.compressed = 1_000
        XCTAssertNil(changed.status())
    }
}
