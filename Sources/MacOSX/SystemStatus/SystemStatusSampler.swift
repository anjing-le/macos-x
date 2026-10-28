import AppKit
import Darwin
import SystemConfiguration
import MacOSXCore

struct SystemStatusRawReading: Sendable {
    var timestamp: TimeInterval
    var cpu: SystemCPUCounter?
    var memory: SystemMemoryStatus?
    var network: SystemNetworkCounter?
    var issues: [String]
    var disk: SystemDiskStatus? = nil
}

/// One timer on one serial queue. No metrics are sampled while the module is stopped.
@MainActor final class SystemStatusSampler {
    var onUpdate: ((SystemStatusSnapshot) -> Void)?
    private(set) var isRunning = false
    private var isSleeping = false
    private var epoch: UInt64 = 0
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.system-status", qos: .utility)
    private let interval: TimeInterval
    private let readOverride: (@Sendable () -> SystemStatusRawReading)?
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var timer: DispatchSourceTimer?
    private var worker: SystemStatusWorker?

    init(interval: TimeInterval = 2, read: (@Sendable () -> SystemStatusRawReading)? = nil,
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.interval = interval.isFinite && interval > 0 ? min(interval, 3600) : 2
        self.readOverride = read
        self.notificationCenter = notificationCenter
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isSleeping = false
        observers = [
            notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleep() }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
        ]
        beginSampling()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isSleeping = false
        pauseSampling()
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
    }

    private func sleep() {
        guard isRunning, !isSleeping else { return }
        isSleeping = true
        pauseSampling()
    }

    private func wake() {
        guard isRunning, isSleeping else { return }
        isSleeping = false
        beginSampling()
    }

    private func beginSampling() {
        epoch &+= 1
        let ticket = epoch
        let worker = SystemStatusWorker(read: readOverride)
        self.worker = worker
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval,
                       leeway: .nanoseconds(Int(min(interval / 10, 0.2) * 1_000_000_000)))
        timer.setEventHandler { [weak self, worker] in
            guard worker.collectForDelivery() else { return }
            // At most one delivery is queued; further readings replace its pending snapshot.
            DispatchQueue.main.async { [weak self, worker] in
                guard let self, self.isRunning, !self.isSleeping, self.epoch == ticket,
                      let value = worker.consumeLatest() else { return }
                self.onUpdate?(value)
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func pauseSampling() {
        epoch &+= 1
        worker?.cancel()
        worker = nil
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    deinit {
        worker?.cancel()
        timer?.setEventHandler {}
        timer?.cancel()
        observers.forEach(notificationCenter.removeObserver)
    }
}

/// Mutable readings belong to the serial sampling queue; the lock only protects delivery/cancellation.
private final class SystemStatusWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var deliveryScheduled = false
    private var pending: SystemStatusSnapshot?
    private var accumulator = SystemStatusAccumulator()
    private var physicalMemory: UInt64?
    private var pageSize: UInt64?
    private var primaryRouteNames: [String] = []
    private var physicalInterface: String?
    private let readOverride: (@Sendable () -> SystemStatusRawReading)?

    init(read: (@Sendable () -> SystemStatusRawReading)?) { readOverride = read }
    private var diskCache = SystemStatusDiskCache()

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        pending = nil
    }

    func consumeLatest() -> SystemStatusSnapshot? {
        lock.lock(); defer { lock.unlock() }
        deliveryScheduled = false
        defer { pending = nil }
        return cancelled ? nil : pending
    }

    func collectForDelivery() -> Bool {
        lock.lock(); let shouldRead = !cancelled; lock.unlock()
        guard shouldRead else { return false }
        let value = read()
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        pending = value
        guard !deliveryScheduled else { return false }
        deliveryScheduled = true
        return true
    }

    private func read() -> SystemStatusSnapshot {
        let reading = readOverride?() ?? nativeReading()
        return accumulator.sample(timestamp: reading.timestamp, cpu: reading.cpu, memory: reading.memory,
                                  network: reading.network, issues: reading.issues, disk: reading.disk)
    }

    private func nativeReading() -> SystemStatusRawReading {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let cpu = readCPU(host)
        let memory = readMemory(host)
        let network = readNetwork()
        let disk = diskCache.sample(at: timestamp)
        var issues: [String] = []
        if cpu == nil { issues.append("CPU 数据暂不可用") }
        if memory == nil { issues.append("内存数据暂不可用") }
        if network == nil { issues.append("网络主接口暂不可用") }
        if disk == nil { issues.append("硬盘容量暂不可用") }
        return .init(timestamp: timestamp, cpu: cpu, memory: memory, network: network, issues: issues, disk: disk)
    }

    private func readCPU(_ host: mach_port_t) -> SystemCPUCounter? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return .init(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readMemory(_ host: mach_port_t) -> SystemMemoryStatus? {
        if physicalMemory == nil {
            var bytes: UInt64 = 0
            var size = MemoryLayout<UInt64>.size
            guard sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0, bytes > 0 else { return nil }
            physicalMemory = bytes
        }
        if pageSize == nil {
            var bytes: vm_size_t = 0
            guard host_page_size(host, &bytes) == KERN_SUCCESS, bytes > 0 else { return nil }
            pageSize = UInt64(bytes)
        }
        guard let physicalMemory, let pageSize else { return nil }
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 else { return nil }
        return SystemMemoryPages(totalBytes: physicalMemory, pageSize: pageSize,
                                 active: UInt64(info.active_count), inactive: UInt64(info.inactive_count),
                                 speculative: UInt64(info.speculative_count), wired: UInt64(info.wire_count),
                                 compressed: UInt64(info.compressor_page_count), purgeable: UInt64(info.purgeable_count),
                                 external: UInt64(info.external_page_count), swapBytes: swap.xsu_used).status()
    }

    private func readNetwork() -> SystemNetworkCounter? {
        guard let name = primaryPhysicalInterface() else { return nil }
        guard let value = readNetworkCounters(name) else {
            physicalInterface = nil
            return nil
        }
        return value
    }

    private func primaryPhysicalInterface() -> String? {
        // PrimaryInterface describes the OS-selected route. Only physical Ethernet/Wi-Fi is accepted.
        let names = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"].compactMap { path in
            (SCDynamicStoreCopyValue(nil, path as CFString) as? [String: Any])?["PrimaryInterface"] as? String
        }
        if names == primaryRouteNames, let physicalInterface { return physicalInterface }
        primaryRouteNames = names
        physicalInterface = nil
        guard !names.isEmpty else { return nil }
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        let physicalNames = Set(interfaces.prefix(128).compactMap { interface -> String? in
            let type = SCNetworkInterfaceGetInterfaceType(interface)
            guard CFEqual(type, kSCNetworkInterfaceTypeEthernet) || CFEqual(type, kSCNetworkInterfaceTypeIEEE80211) else { return nil }
            return SCNetworkInterfaceGetBSDName(interface) as String?
        })
        physicalInterface = names.first(where: { physicalNames.contains($0) })
        return physicalInterface
    }

    private func readNetworkCounters(_ name: String) -> SystemNetworkCounter? {
        let index = if_nametoindex(name)
        guard index > 0, index <= UInt32(Int32.max) else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, Int32(index)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0, size <= 1_048_576 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let capacity = size
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0, size <= capacity else { return nil }
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= size {
            var header = if_msghdr()
            buffer.withUnsafeBytes { bytes in
                _ = memcpy(&header, bytes.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr>.size)
            }
            let length = Int(header.ifm_msglen)
            guard length >= MemoryLayout<if_msghdr>.size, offset + length <= size else { return nil }
            if Int32(header.ifm_type) == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size {
                var extended = if_msghdr2()
                buffer.withUnsafeBytes { bytes in
                    _ = memcpy(&extended, bytes.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                }
                if UInt32(extended.ifm_index) == index {
                    let flags = UInt32(bitPattern: extended.ifm_flags)
                    guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_RUNNING) != 0,
                          flags & UInt32(IFF_LOOPBACK) == 0 else { return nil }
                    return .init(interfaceName: name, interfaceIndex: index,
                                 receivedBytes: extended.ifm_data.ifi_ibytes, sentBytes: extended.ifm_data.ifi_obytes)
                }
            }
            offset += length
        }
        return nil
    }

}

/// Owned by the serial worker; no extra timer, directory traversal or retained stale errors.
struct SystemStatusDiskCache {
    private var lastRead: TimeInterval?
    private var cached: SystemDiskStatus?

    mutating func sample(at time: TimeInterval, read: () -> SystemDiskStatus? = Self.readStartupVolume) -> SystemDiskStatus? {
        guard time.isFinite, time >= 0 else { return nil }
        if let lastRead, time >= lastRead, time - lastRead < 30 { return cached }
        lastRead = time
        cached = read()
        return cached
    }

    static func readStartupVolume() -> SystemDiskStatus? {
        // The writable Data volume avoids reporting the sealed system snapshot's capacity.
        let url = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0,
              let available = values.volumeAvailableCapacity, available >= 0 else { return nil }
        return .init(totalBytes: UInt64(total), availableBytes: UInt64(available))
    }
}
