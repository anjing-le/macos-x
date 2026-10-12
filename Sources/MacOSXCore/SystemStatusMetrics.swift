import Foundation

public struct SystemStatusSnapshot: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var cpuPercent: Double?
    public var memory: SystemMemoryStatus?
    public var network: SystemNetworkStatus?
    public var issues: [String]

    public init(timestamp: TimeInterval, cpuPercent: Double?, memory: SystemMemoryStatus?, network: SystemNetworkStatus?, issues: [String] = []) {
        self.timestamp = timestamp
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.network = network
        self.issues = issues
    }
}

public struct SystemMemoryStatus: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var compressedBytes: UInt64
    public var swapBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64, compressedBytes: UInt64, swapBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.compressedBytes = compressedBytes
        self.swapBytes = swapBytes
    }
}

public struct SystemNetworkStatus: Equatable, Sendable {
    public var interfaceName: String
    public var downloadBytesPerSecond: Double?
    public var uploadBytesPerSecond: Double?

    public init(interfaceName: String, downloadBytesPerSecond: Double?, uploadBytesPerSecond: Double?) {
        self.interfaceName = interfaceName
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }
}

/// HOST_CPU_LOAD_INFO counters are unsigned 32-bit ticks, including rollover.
public struct SystemCPUCounter: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Exactly one physical interface; an index change also invalidates the baseline.
public struct SystemNetworkCounter: Equatable, Sendable {
    public var interfaceName: String
    public var interfaceIndex: UInt32
    public var receivedBytes: UInt64
    public var sentBytes: UInt64

    public init(interfaceName: String, interfaceIndex: UInt32, receivedBytes: UInt64, sentBytes: UInt64) {
        self.interfaceName = interfaceName
        self.interfaceIndex = interfaceIndex
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

public struct SystemMemoryPages: Equatable, Sendable {
    public var totalBytes: UInt64
    public var pageSize: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var swapBytes: UInt64

    public init(totalBytes: UInt64, pageSize: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64, wired: UInt64, compressed: UInt64, purgeable: UInt64, external: UInt64, swapBytes: UInt64) {
        self.totalBytes = totalBytes
        self.pageSize = pageSize
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
        self.swapBytes = swapBytes
    }

    /// Reclaimable cache is excluded, rather than counting all non-free RAM as used.
    public func status() -> SystemMemoryStatus? {
        guard totalBytes > 0, pageSize > 0,
              let resident = Self.sum([active, inactive, speculative, wired, compressed]),
              let reclaimable = Self.sum([purgeable, external]) else { return nil }
        let usedPages = resident > reclaimable ? resident - reclaimable : 0
        let used = usedPages.multipliedReportingOverflow(by: pageSize)
        let compressedBytes = compressed.multipliedReportingOverflow(by: pageSize)
        guard !used.overflow, !compressedBytes.overflow, compressedBytes.partialValue <= totalBytes else { return nil }
        // Keep the displayed quantity within physical capacity without unsigned underflow.
        return .init(usedBytes: min(used.partialValue, totalBytes), totalBytes: totalBytes,
                     compressedBytes: compressedBytes.partialValue, swapBytes: swapBytes)
    }

    private static func sum(_ values: [UInt64]) -> UInt64? {
        var result: UInt64 = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }
}

/// Pure bounded state: one previous CPU sample and one previous network sample.
public struct SystemStatusAccumulator: Sendable {
    private var previousCPU: (TimeInterval, SystemCPUCounter)?
    private var previousNetwork: (TimeInterval, SystemNetworkCounter)?

    public init() {}
    public mutating func reset() { previousCPU = nil; previousNetwork = nil }

    public mutating func sample(timestamp: TimeInterval, cpu: SystemCPUCounter?, memory: SystemMemoryStatus?, network: SystemNetworkCounter?, issues: [String] = []) -> SystemStatusSnapshot {
        guard timestamp.isFinite, timestamp >= 0 else {
            reset()
            return .init(timestamp: 0, cpuPercent: nil, memory: memory,
                         network: network.map { .init(interfaceName: $0.interfaceName, downloadBytesPerSecond: nil, uploadBytesPerSecond: nil) },
                         issues: issues + ["采样时间无效"])
        }
        let cpuPercent = readCPU(cpu, timestamp: timestamp)
        let networkStatus = readNetwork(network, timestamp: timestamp)
        return .init(timestamp: timestamp, cpuPercent: cpuPercent, memory: memory, network: networkStatus, issues: issues)
    }

    private mutating func readCPU(_ current: SystemCPUCounter?, timestamp: TimeInterval) -> Double? {
        guard let current else { previousCPU = nil; return nil }
        let previous = previousCPU
        previousCPU = (timestamp, current)
        guard let (oldTime, old) = previous, timestamp > oldTime else { return nil }
        let user = UInt64(current.user &- old.user)
        let system = UInt64(current.system &- old.system)
        let nice = UInt64(current.nice &- old.nice)
        let idle = UInt64(current.idle &- old.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }

    private mutating func readNetwork(_ current: SystemNetworkCounter?, timestamp: TimeInterval) -> SystemNetworkStatus? {
        guard let current, !current.interfaceName.isEmpty, current.interfaceIndex > 0 else {
            previousNetwork = nil
            return nil
        }
        var result = SystemNetworkStatus(interfaceName: current.interfaceName, downloadBytesPerSecond: nil, uploadBytesPerSecond: nil)
        let previous = previousNetwork
        previousNetwork = (timestamp, current)
        guard let (oldTime, old) = previous,
              old.interfaceName == current.interfaceName, old.interfaceIndex == current.interfaceIndex,
              current.receivedBytes >= old.receivedBytes, current.sentBytes >= old.sentBytes else { return result }
        let elapsed = timestamp - oldTime
        guard elapsed.isFinite, elapsed > 0 else { return result }
        let download = Double(current.receivedBytes - old.receivedBytes) / elapsed
        let upload = Double(current.sentBytes - old.sentBytes) / elapsed
        guard download.isFinite, upload.isFinite else { return result }
        result.downloadBytesPerSecond = download
        result.uploadBytesPerSecond = upload
        return result
    }
}
