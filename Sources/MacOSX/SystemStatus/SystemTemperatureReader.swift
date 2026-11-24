import Foundation
import IOKit
import MacOSXCore

/// Serial-worker only. Opens a read-only SMC session per refresh and always closes it.
/// No helper, subprocess, root access, key writes, full key enumeration or extra timer.
final class SystemTemperatureReader {
    typealias Reading = (cpu: Double?, gpu: Double?)
    private var nextRead: TimeInterval?
    private var previousTime: TimeInterval?
    private var cached: Reading = (nil, nil)
    private let read: () -> Reading

    init(read: (() -> Reading)? = nil) { self.read = read ?? { TemperatureSMC.read() } }

    func sample(at time: TimeInterval) -> SystemTemperatureStatus {
        if time.isFinite, time >= 0 {
            if nextRead == nil || time >= nextRead! || time < (previousTime ?? time) {
                let value = read()
                cached = (SystemTemperatureStatus.valid(value.cpu), SystemTemperatureStatus.valid(value.gpu))
                // Unsupported hardware/failed reads do not cause a rapid retry loop.
                nextRead = time + (cached.cpu == nil && cached.gpu == nil ? 30 : 4)
            }
            previousTime = time
        } else { cached = (nil, nil); nextRead = nil; previousTime = nil }
        let pressure: SystemTemperatureStatus.Pressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: pressure = .nominal
        case .fair: pressure = .fair
        case .serious: pressure = .serious
        case .critical: pressure = .critical
        @unknown default: pressure = .unknown
        }
        return .init(cpuCelsius: cached.cpu, gpuCelsius: cached.gpu, pressure: pressure)
    }
}

/// Isolated undocumented sensor protocol. Unknown generations/types return no temperature.
/// Protocol references and sensor mapping provenance: docs/computer-status.md.
enum TemperatureSMC {
    static func read() -> SystemTemperatureReader.Reading {
        let keys = sensorKeys(brand: cpuBrand())
        guard !keys.cpu.isEmpty || !keys.gpu.isEmpty else { return (nil, nil) }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return (nil, nil) }
        defer { IOServiceClose(connection) }
        // Small explicit key set, with a cooperative total budget between driver calls.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        func average(_ keys: [String]) -> Double? {
            var values: [Double] = []
            for key in keys.prefix(32) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                if let value = temperature(key: key, connection: connection) { values.append(value) }
            }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        return (average(keys.cpu), average(keys.gpu))
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

    private static func temperature(key: String, connection: io_connect_t) -> Double? {
        guard key.utf8.count == 4 else { return nil }
        let keyCode = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        // The SMC ABI uses an 80-byte record on both architectures. Explicit byte
        // offsets avoid depending on Swift struct padding/alignment.
        var request = [UInt8](repeating: 0, count: 80)
        write(keyCode, at: 0, to: &request)
        request[42] = 9 // key information, never write (6)
        guard let info = call(request, connection: connection) else { return nil }
        let size = uint32(info, at: 28)
        guard size == 2 || size == 4 else { return nil }
        let type = uint32(info, at: 32)
        guard type == 0x73703738 || type == 0x666c7420 else { return nil } // sp78 / flt
        write(size, at: 28, to: &request)
        request[42] = 5 // read bytes
        guard let response = call(request, connection: connection) else { return nil }
        return decode(type: type, bytes: Array(response[48..<48 + Int(size)]))
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
