import AppKit
import Carbon
import ApplicationServices
import MacOSXCore

struct RadarApp: Sendable {
    let pid: pid_t
    let id: String
    let name: String
}

struct RadarCoverage: Sendable {
    enum Status: String, Sendable { case read, limited, unavailable }
    let app: RadarApp
    let status: Status
}

struct RadarSnapshot: Sendable {
    var uses: [RadarUse]
    var coverage: [RadarCoverage] = []
    var totalApps = 0
    var accessibility = false
    var systemAvailable = true
    var truncated = false
    var date = Date()
    var elapsed: TimeInterval = 0
    var probe: RadarProbe?
}

struct RadarProbe: Sendable {
    enum Result: Sendable { case known, occupied, notFound, unavailable }
    let chord: RadarChord
    let result: Result
    let status: OSStatus?
    init(chord: RadarChord, result: Result, status: OSStatus? = nil) {
        self.chord = chord; self.result = result; self.status = status
    }
    var message: String {
        switch result {
        case .known: return "已发现登记来源 · 仍需结合使用场景"
        case .occupied: return "检测到排他占用 · 系统未提供应用归属"
        case .notFound: return "未检测到排他占用 · 仍可能有共享登记或后台监听"
        case .unavailable: return "登记检测不可用 · 不能判断是否空闲"
        }
    }
}

/// Cancellation is checked between bounded AX calls. It never changes the
/// process-wide AX timeout used by other modules.
final class RadarScanToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// One serial queue, one explicit scan, no timer, application activation,
/// keyboard monitor, menu opening, or AX writes.
final class ShortcutRadarScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macos-x.shortcut-radar", qos: .utility)
    typealias Reader = @Sendable ([RadarApp], [UInt16: String], RadarSnapshot, RadarScanToken) -> RadarSnapshot
    private let reader: Reader
    init(reader: @escaping Reader = { ShortcutRadarScanner.read(apps: $0, labels: $1, seed: $2, token: $3) }) { self.reader = reader }
    func scan(apps: [RadarApp], labels: [UInt16: String], seed: RadarSnapshot,
              token: RadarScanToken, completion: @escaping @Sendable (RadarSnapshot) -> Void) {
        queue.async { [reader] in
            guard !token.isCancelled else { return }
            let result = reader(apps, labels, seed, token)
            if !token.isCancelled { completion(result) }
        }
    }

    static func read(apps: [RadarApp], labels: [UInt16: String], seed: RadarSnapshot, token: RadarScanToken) -> RadarSnapshot {
        precondition(!Thread.isMainThread)
        var result = seed
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 8
        for app in apps.prefix(32) {
            guard !token.isCancelled else { break }
            guard result.accessibility, ProcessInfo.processInfo.systemUptime < deadline,
                  result.uses.count < RadarIndex.maximumUses else { result.truncated = result.accessibility; break }
            let (entries, status) = readMenu(app: app, labels: labels, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.8),
                                              limit: RadarIndex.maximumUses - result.uses.count, token: token)
            result.uses.append(contentsOf: entries)
            result.coverage.append(.init(app: app, status: status))
            if status == .limited { result.truncated = true }
        }
        if result.accessibility && result.coverage.count < result.totalApps { result.truncated = true }
        result.elapsed = ProcessInfo.processInfo.systemUptime - start
        result.date = Date()
        return result
    }

    private static func readMenu(app: RadarApp, labels: [UInt16: String], deadline: TimeInterval,
                                 limit: Int, token: RadarScanToken) -> ([RadarUse], RadarCoverage.Status) {
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, 0.10)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return ([], .unavailable) }
        var queue: [(AXUIElement, [String], Int)] = [(unsafeBitCast(bar, to: AXUIElement.self), [], 0)]
        var cursor = 0, uses: [RadarUse] = [], limited = false
        let attributes = [kAXRoleAttribute, kAXTitleAttribute, kAXMenuItemCmdVirtualKeyAttribute,
            kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute] as CFArray
        // Retained AX nodes and result strings stay bounded even for huge/dynamic menus.
        while cursor < queue.count {
            if token.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline || cursor >= 800 || uses.count >= limit {
                limited = true; break
            }
            let (element, parent, depth) = queue[cursor]; cursor += 1
            AXUIElementSetMessagingTimeout(element, 0.10)
            var values: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
            guard error == .success, let array = values as? [Any], array.count == 6 else { limited = true; continue }
            let role = array[0] as? String ?? ""
            let title = String((array[1] as? String ?? "").prefix(160))
            let path = title.isEmpty ? parent : Array((parent + [title]).suffix(8))
            if role == kAXMenuItemRole, (array[5] as? NSNumber)?.boolValue == true {
                let code = (array[2] as? NSNumber)?.uint16Value
                let character = array[3] as? String ?? ""
                let key = code.flatMap { labels[$0] } ?? nativeMenuKey(character)
                if let mask = (array[4] as? NSNumber)?.uint32Value, let key, !key.isEmpty,
                   !character.isEmpty || (code != nil && code != 0) {
                    // AX: Shift=1, Option=2, Control=4, NoCommand=8. This is NOT NSEvent's mask.
                    let modifiers: UInt8 = (mask & 4 != 0 ? 1 : 0) | (mask & 2 != 0 ? 2 : 0)
                        | (mask & 1 != 0 ? 4 : 0) | (mask & 8 == 0 ? 8 : 0)
                    uses.append(.init(chord: .init(key: key, modifiers: modifiers), appID: app.id, appName: app.name,
                        action: title.isEmpty ? "未命名菜单命令" : title, path: path.joined(separator: " › "),
                        scope: .application, evidence: .menu))
                }
            }
            guard depth < 8, !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                if depth >= 8 { limited = true }; continue
            }
            var count = 0
            let countError = AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count)
            if countError == .noValue || countError == .attributeUnsupported { continue }
            guard countError == .success else { limited = true; continue }
            let allowed = min(count, 800 - queue.count)
            if allowed < count { limited = true }
            guard allowed > 0 else { continue }
            var children: CFArray?
            if AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, allowed, &children) == .success,
               let children = children as? [AXUIElement] {
                for child in children { queue.append((child, path, depth + 1)) }
            } else { limited = true }
        }
        return (uses, limited ? .limited : .read)
    }

    private static func nativeMenuKey(_ string: String) -> String? {
        guard string.count == 1, let scalar = string.unicodeScalars.first else { return nil }
        let symbols: [UInt32: String] = [0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→",
            0x09: "Tab", 0x0D: "↩", 0x20: "Space", 0x1B: "Esc", 0x7F: "⌫"]
        if let symbol = symbols[scalar.value] { return symbol }
        if (0xF704...0xF717).contains(scalar.value) { return "F\(scalar.value - 0xF704 + 1)" }
        guard !CharacterSet.controlCharacters.contains(scalar), scalar.properties.generalCategory != .privateUse else { return nil }
        return string.uppercased()
    }
}

@MainActor
enum RadarNativeSeed {
    /// Keep only a 64x64 RGBA bitmap, not every high-resolution representation
    /// of an application icon. At most 32 cached icons use 512 KiB of pixels.
    static func thumbnail(_ image: NSImage) -> NSImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context; context.imageInterpolation = .high
        image.draw(in: CGRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: 32, height: 32)); result.addRepresentation(bitmap)
        return result
    }
    static func probe(_ chord: RadarChord, labels: [UInt16: String], known: [RadarUse]) -> RadarProbe {
        if known.contains(where: { $0.chord == chord && $0.isConfirmed }) { return .init(chord: chord, result: .known) }
        guard let code = labels.filter({ RadarChord(key: $0.value, modifiers: chord.modifiers) == chord }).keys.min() else {
            return .init(chord: chord, result: .unavailable)
        }
        let modifiers: UInt32 = (chord.modifiers & 1 != 0 ? UInt32(controlKey) : 0)
            | (chord.modifiers & 2 != 0 ? UInt32(optionKey) : 0)
            | (chord.modifiers & 4 != 0 ? UInt32(shiftKey) : 0)
            | (chord.modifiers & 8 != 0 ? UInt32(cmdKey) : 0)
            | (chord.modifiers & 16 != 0 ? UInt32(kEventKeyModifierFnMask) : 0)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: 0x72616472, id: 1),
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return .init(chord: chord, result: status == noErr ? .notFound : status == eventHotKeyExistsErr ? .occupied : .unavailable, status: status)
    }
    /// TIS and non-thread-safe Carbon enumeration are called once on explicit
    /// refresh. Only the bounded cross-process menu traversal goes to the worker.
    static func keyLabels() -> [UInt16: String] {
        var result: [UInt16: String] = [36: "↩", 48: "Tab", 49: "Space", 51: "⌫", 53: "Esc", 76: "⌤",
            115: "Home", 116: "PageUp", 117: "⌦", 119: "End", 121: "PageDown", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let functions: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        for (index, code) in functions.enumerated() { result[code] = "F\(index + 1)" }
        // Number-pad keys have distinct physical bindings; do not merge them
        // with the main keyboard's digits and operators in a conflict count.
        let keypad: [UInt16: String] = [65:"Num .", 67:"Num *", 69:"Num +", 71:"Num Clear", 75:"Num /", 78:"Num -",
            81:"Num =", 82:"Num 0", 83:"Num 1", 84:"Num 2", 85:"Num 3", 86:"Num 4", 87:"Num 5",
            88:"Num 6", 89:"Num 7", 91:"Num 8", 92:"Num 9"]
        result.merge(keypad) { _, new in new }
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let fallback = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            ?? TISGetInputSourceProperty(fallback, kTISPropertyUnicodeKeyLayoutData) else { return result }
        let data = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard CFDataGetLength(data) > 0, let bytes = CFDataGetBytePtr(data) else { return result }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for code in UInt16(0)...UInt16(126) where result[code] == nil {
            var dead: UInt32 = 0, length = 0
            var buffer = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, buffer.count, &length, &buffer)
            if status == noErr, length > 0 {
                let key = String(utf16CodeUnits: buffer, count: min(length, buffer.count))
                if key.count == 1, key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse }) {
                    result[code] = key.uppercased()
                }
            }
        }
        return result
    }

    static func systemUses(labels: [UInt16: String]) -> ([RadarUse], Bool) {
        var catalog: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&catalog) == noErr, let array = catalog?.takeRetainedValue() as? [[String: Any]] else { return ([], false) }
        let uses = array.prefix(512).compactMap { entry -> RadarUse? in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? NSNumber,
                  let flags = entry[kHISymbolicHotKeyModifiers as String] as? NSNumber,
                  let key = labels[code.uint16Value] else { return nil }
            let mask = flags.uint32Value
            let modifiers: UInt8 = (mask & UInt32(controlKey) != 0 ? 1 : 0) | (mask & UInt32(optionKey) != 0 ? 2 : 0)
                | (mask & UInt32(shiftKey) != 0 ? 4 : 0) | (mask & UInt32(cmdKey) != 0 ? 8 : 0)
                | (mask & UInt32(kEventKeyModifierFnMask) != 0 ? 16 : 0)
            return .init(chord: .init(key: key, modifiers: modifiers), appID: "system", appName: "macOS",
                         action: "系统快捷键（用途未公开）", path: "系统设置 › 键盘 › 键盘快捷键", scope: .global, evidence: .system)
        }
        // Carbon gives no stable action identity or title; duplicate entries
        // cannot honestly be counted as distinct known functions.
        return (Array(Set(uses)), true)
    }
}
