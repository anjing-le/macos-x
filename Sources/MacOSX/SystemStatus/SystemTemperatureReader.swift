import Foundation
import IOKit
import MacOSXCore

/// Serial-worker only. Opens a read-only SMC session per refresh and always closes it.
/// No helper, subprocess, root access, key writes or extra timer.
final class SystemTemperatureReader {
    struct Reading {
        var cpu: Double?
        var gpu: Double?
        var sensors: [SystemTemperatureSensor] = []
    }
    private var nextRead: TimeInterval?
    private var previousTime: TimeInterval?
    private var cached = Reading(cpu: nil, gpu: nil)
    private let read: () -> Reading

    init(read: (() -> Reading)? = nil) {
        let native = TemperatureSMC()
        self.read = read ?? { native.read() }
    }

    func sample(at time: TimeInterval) -> SystemTemperatureStatus {
        if time.isFinite, time >= 0 {
            if nextRead == nil || time >= nextRead! || time < (previousTime ?? time) {
                let value = read()
                cached = value
                cached.cpu = SystemTemperatureStatus.valid(value.cpu)
                cached.gpu = SystemTemperatureStatus.valid(value.gpu)
                // Unsupported hardware/failed reads do not cause a rapid retry loop.
                nextRead = time + (cached.sensors.contains(where: { $0.celsius != nil }) || cached.cpu != nil || cached.gpu != nil ? 4 : 30)
            }
            previousTime = time
        } else { cached = Reading(cpu: nil, gpu: nil); nextRead = nil; previousTime = nil }
        let pressure: SystemTemperatureStatus.Pressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pressure = .nominal
        case .fair: pressure = .fair
        case .serious: pressure = .serious
        case .critical: pressure = .critical
        @unknown default: pressure = .unknown
        }
        return .init(cpuCelsius: cached.cpu, gpuCelsius: cached.gpu, pressure: pressure, sensors: cached.sensors)
    }
}

/// Isolated read-only protocol: only confirmed common-component keys are queried.
/// Protocol references and sensor mapping provenance: docs/computer-status.md.
final class TemperatureSMC {
    struct KeyInfo { let size: UInt32; let type: UInt32 }
    private var brand: String?
    private var cpuKeys: [String] = []
    private var gpuKeys: [String] = []
    private var candidates: [String] = []
    private var candidateSet = Set<String>()
    private var groups: [String: SystemTemperatureSensor.Group] = [:]
    private var infoCache: [String: KeyInfo] = [:]
    private var displayed = Set<String>()

    func read() -> SystemTemperatureReader.Reading {
        if brand == nil {
            brand = Self.cpuBrand()
            let known = Self.sensorKeys(brand: brand!)
            cpuKeys = known.cpu; gpuKeys = known.gpu
            for key in Self.monitoredKeys(brand: brand!) { remember(key) }
        }
        guard !candidates.isEmpty else { return unavailable() }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return unavailable() }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return unavailable() }
        defer { IOServiceClose(connection) }
        var values: [String: Double] = [:]
        for key in candidates {
            guard let bytes = bytes(key: key, connection: connection), let info = infoCache[key],
                  let value = Self.decode(type: info.type, bytes: bytes) else { continue }
            values[key] = value; displayed.insert(key)
        }
        func average(_ keys: [String]) -> Double? {
            let found = keys.compactMap { values[$0] }
            return found.isEmpty ? nil : found.reduce(0, +) / Double(found.count)
        }
        let sensors = displayed.sorted().compactMap { key in
            SystemTemperatureSensor(key: key, group: groups[key] ?? .other, celsius: values[key])
        }
        return .init(cpu: average(cpuKeys), gpu: average(gpuKeys), sensors: sensors)
    }

    private func unavailable() -> SystemTemperatureReader.Reading {
        .init(cpu: nil, gpu: nil, sensors: displayed.sorted().compactMap {
            .init(key: $0, group: groups[$0] ?? .other, celsius: nil)
        })
    }

    private func remember(_ key: String) {
        guard key.utf8.count == 4, key.utf8.allSatisfy({ (32...126).contains($0) }), key.first == "T", !candidateSet.contains(key) else { return }
        guard candidates.count < 128 else { return }
        candidateSet.insert(key); candidates.append(key)
        groups[key] = Self.group(key: key, brand: brand ?? "")
    }

    static func monitoredKeys(brand: String) -> [String] {
        let known = sensorKeys(brand: brand)
        var seen = Set<String>()
        return (known.cpu + known.gpu + additionalKeys(brand: brand)).filter {
            group(key: $0, brand: brand) != .other && seen.insert($0).inserted
        }
    }

    static func additionalKeys(brand: String) -> [String] {
        if brand.hasPrefix("Apple M") {
            return ["TB1T", "TB2T", "TH0x", "TaLP", "TaRF", "TW0P"]
                + ["Tm02", "Tm06", "Tm08", "Tm09", "Tm0p", "Tm1p", "Tm2p"]
        }
        if brand.contains("Intel") {
            return ["TB1T", "Tm0P", "Tp0P", "TN0D", "TN0H", "TN0P", "TW0P", "TL0P", "TTLD", "TTRD"]
                + (0...9).flatMap { ["TA\($0)P", "Th\($0)H", "TI\($0)P", "TH\($0)A", "TH\($0)B", "TH\($0)C"] }
                + ["TMA1", "TMA2", "TMA3", "TMA4", "TMB1", "TMB2", "TMB3", "TMB4"]
        }
        return []
    }

    static func group(key: String, brand: String) -> SystemTemperatureSensor.Group {
        let known = sensorKeys(brand: brand)
        if known.cpu.contains(key) { return .cpu }
        if known.gpu.contains(key) { return .gpu }
        let silicon = brand.hasPrefix("Apple M") && !known.cpu.isEmpty
        let intel = brand.contains("Intel")
        guard silicon || intel else { return .other }
        if key == "TB1T" || (silicon && key == "TB2T") { return .battery }
        if silicon {
            if key == "TH0x" { return .storage }
            if key == "TaLP" || key == "TaRF" { return .environment }
            if brand.hasPrefix("Apple M1"), ["Tm02", "Tm06", "Tm08", "Tm09"].contains(key) { return .memory }
            if brand.hasPrefix("Apple M4"), ["Tm0p", "Tm1p", "Tm2p"].contains(key) { return .memory }
        }
        if intel {
            guard additionalKeys(brand: brand).contains(key) else { return .other }
            if ["Tm0P", "Tp0P", "TN0D", "TN0H", "TN0P"].contains(key) { return .board }
            if key.hasPrefix("TMA") || key.hasPrefix("TMB") { return .memory }
            if key.hasPrefix("TH"), ["A", "B", "C"].contains(String(key.suffix(1))) { return .storage }
            if key.hasPrefix("TA") || key.hasPrefix("Th") { return .environment }
        }
        return .other
    }

    static func sensorKeys(brand: String) -> (cpu: [String], gpu: [String]) {
        if brand.hasPrefix("Apple M") {
            let generation = Int(brand.dropFirst("Apple M".count).prefix(while: { $0.isNumber }))
            switch generation {
            case 1: return (["Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"], ["Tg05", "Tg0D", "Tg0L", "Tg0T"])
            case 2: return (["Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"], ["Tg0f", "Tg0j"])
            case 3: return (["Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"], ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"])
            case 4: return (["Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"], ["Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"])
            case 5: return (["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"], ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"])
            default: return ([], [])
            }
        }
        // Do not interpret Apple Silicon power-board keys as Intel CPU sensors.
        if brand.contains("Intel") {
            return (["TC0D", "TCAD"], ["TG0D", "TGDD", "TCGC"])
        }
        return ([], [])
    }

    private static func cpuBrand() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0, size <= 512 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func bytes(key: String, connection: io_connect_t) -> [UInt8]? {
        guard key.utf8.count == 4 else { return nil }
        var request = [UInt8](repeating: 0, count: 80)
        Self.write(key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }, at: 0, to: &request)
        if infoCache[key] == nil {
            request[42] = 9 // key information
            guard let info = Self.call(request, connection: connection) else { return nil }
            let size = Self.uint32(info, at: 28), type = Self.uint32(info, at: 32)
            guard size > 0, size <= 32 else { return nil }
            // Only recognized temperature encodings are decoded.
            guard type == 0x73703738 || type == 0x666c7420 else { return nil }
            infoCache[key] = .init(size: size, type: type)
        }
        guard let info = infoCache[key] else { return nil }
        Self.write(info.size, at: 28, to: &request)
        request[42] = 5 // read bytes
        guard let response = Self.call(request, connection: connection) else { return nil }
        return Array(response[48..<48 + Int(info.size)])
    }

    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        let value: Double
        switch (type, bytes.count) {
        case (0x73703738, 2):
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case (0x666c7420, 4):
            value = Double(Float(bitPattern: uint32(bytes, at: 0)))
        default: return nil
        }
        return SystemTemperatureStatus.valid(value)
    }

    private static func call(_ request: [UInt8], connection: io_connect_t) -> [UInt8]? {
        var response = [UInt8](repeating: 0, count: 80)
        var count = response.count
        let result = request.withUnsafeBytes { input in
            response.withUnsafeMutableBytes { output in
                IOConnectCallStructMethod(connection, 2, input.baseAddress, input.count, output.baseAddress, &count)
            }
        }
        guard result == KERN_SUCCESS, count == 80, response[40] == 0 else { return nil }
        return response
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }
    private static func write(_ value: UInt32, at offset: Int, to bytes: inout [UInt8]) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }
}
