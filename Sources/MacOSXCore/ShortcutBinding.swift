import Foundation

/// A portable representation shared by persistence, conflict checks and input.
public struct ShortcutBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case chord, doubleModifier }
    public var kind: Kind
    public var keyCode: UInt16
    /// Control=1, Option=2, Shift=4, Command=8. Device-specific flags are excluded.
    public var modifiers: UInt8
    public var keyLabel: String

    public init(kind: Kind = .chord, keyCode: UInt16, modifiers: UInt8, keyLabel: String) {
        self.kind = kind; self.keyCode = keyCode; self.modifiers = modifiers & 15
        self.keyLabel = String(keyLabel.prefix(24))
    }

    public var isValid: Bool {
        guard keyCode <= 126, modifiers <= 15 else { return false }
        if kind == .doubleModifier { return [58, 59, 61, 62].contains(keyCode) }
        return (isFunctionKey || modifiers & 9 != 0)
            && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    public var isFunctionKey: Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
         105, 107, 113, 106, 64, 79, 80, 90].contains(keyCode)
    }

    public var displayName: String {
        if kind == .doubleModifier {
            let names: [UInt16: String] = [58: "左 Option", 61: "右 Option", 59: "左 Control", 62: "右 Control"]
            return "双击 " + (names[keyCode] ?? "修饰键")
        }
        return (modifiers & 1 != 0 ? "⌃" : "") + (modifiers & 2 != 0 ? "⌥" : "")
            + (modifiers & 4 != 0 ? "⇧" : "") + (modifiers & 8 != 0 ? "⌘" : "") + keyLabel
    }

    /// Ignore only the Command held by an active window-switch session.
    public func matches(keyCode: UInt16, modifiers: UInt8, ignoringHeldCommand: Bool = false) -> Bool {
        guard kind == .chord, self.keyCode == keyCode else { return false }
        let mask: UInt8 = ignoringHeldCommand ? 7 : 15
        return modifiers & mask == self.modifiers & mask
    }

    public func conflicts(with other: ShortcutBinding) -> Bool {
        kind == other.kind && keyCode == other.keyCode && (kind == .doubleModifier || modifiers == other.modifiers)
    }
}

/// Two complete short taps; holding, typing, mixed modifiers or clock regression
/// cancel the sequence. The recognizer does not swallow modifier events.
public struct ModifierDoubleTap: Sendable {
    private var downAt: Double?
    private var previousRelease: Double?
    public let interval: Double
    public let maximumHold: Double
    public init(interval: Double = 0.34, maximumHold: Double = 0.25) {
        self.interval = interval; self.maximumHold = maximumHold
    }
    public mutating func reset() { downAt = nil; previousRelease = nil }
    /// Device flags belong to the queued event; global key state may already
    /// describe a later release. Masks are macOS NX_DEVICE modifier constants.
    public mutating func update(keyCode: UInt16, eventFlags: UInt64, timestamp: Double) -> Bool {
        let mask: UInt64
        switch keyCode {
        case 58: mask = 0x20
        case 61: mask = 0x40
        case 59: mask = 0x1
        case 62: mask = 0x2000
        default: reset(); return false
        }
        return update(isDown: eventFlags & mask != 0, timestamp: timestamp)
    }

    public mutating func update(isDown: Bool, timestamp: Double) -> Bool {
        guard timestamp.isFinite else { reset(); return false }
        if isDown {
            guard downAt == nil else { reset(); return false }
            if let previousRelease, timestamp < previousRelease { reset() }
            downAt = timestamp
            return false
        }
        guard let down = downAt, timestamp >= down, timestamp - down <= maximumHold else {
            reset(); return false
        }
        downAt = nil
        if let previous = previousRelease, timestamp >= previous, timestamp - previous <= interval {
            previousRelease = nil
            return true
        }
        previousRelease = timestamp
        return false
    }
}
