import AppKit

/// Keep the gesture the user performed, rather than substituting AXPress or
/// opening the application. A double click contains both down/up pairs.
struct MenuBarPointerSample {
    let type: CGEventType
    let button: CGMouseButton
    let count: Int64
    let flags: CGEventFlags
    let timestamp: TimeInterval
    init(_ event: NSEvent) {
        type = event.cgEvent?.type ?? .leftMouseUp
        button = CGMouseButton(rawValue: UInt32(max(0, event.buttonNumber))) ?? .left
        count = Int64(event.clickCount)
        flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        timestamp = event.timestamp
    }
    init(type: CGEventType, button: CGMouseButton = .left, count: Int64 = 1,
         flags: CGEventFlags = [], timestamp: TimeInterval) {
        self.type = type; self.button = button; self.count = count; self.flags = flags; self.timestamp = timestamp
    }
    static var singleClick: [Self] {
        [.init(type: .leftMouseDown, timestamp: 0), .init(type: .leftMouseUp, timestamp: 0.04)]
    }
    static func valid(_ samples: [Self]) -> Bool {
        guard !samples.isEmpty, samples.count <= 8, samples.count.isMultiple(of: 2),
              let first = samples.first, let last = samples.last,
              first.timestamp.isFinite, first.timestamp >= 0, last.timestamp - first.timestamp <= 3 else { return false }
        var previous = first.timestamp
        for pair in stride(from: 0, to: samples.count, by: 2) {
            let down = samples[pair], up = samples[pair + 1]
            let expected: CGEventType = down.type == .leftMouseDown ? .leftMouseUp
                : down.type == .rightMouseDown ? .rightMouseUp : .otherMouseUp
            guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(down.type), up.type == expected,
                  down.button == up.button, down.count == up.count, down.count > 0,
                  down.timestamp.isFinite, up.timestamp.isFinite,
                  down.timestamp >= previous, up.timestamp >= down.timestamp else { return false }
            previous = up.timestamp
        }
        return true
    }
}

