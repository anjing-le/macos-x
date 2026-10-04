/// Actual, confirmed window focus only. Choosing or cancelling never changes this order.
public struct WindowRecency: Equatable {
    public private(set) var windowIDs: [UInt32] = []
    public let capacity: Int

    public init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    public mutating func recordFocus(_ id: UInt32) {
        guard id != 0 else { return }
        windowIDs.removeAll { $0 == id }
        windowIDs.insert(id, at: 0)
        if windowIDs.count > capacity { windowIDs.removeLast(windowIDs.count - capacity) }
    }

    public mutating func retain(liveIDs: [UInt32]) {
        let live = Set(liveIDs)
        windowIDs.removeAll { !live.contains($0) }
    }

    /// Keep known recency; new windows retain the caller's stable baseline order.
    public func ordered(availableIDs: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        let available = availableIDs.filter { $0 != 0 && seen.insert($0).inserted }
        let known = windowIDs.filter { seen.contains($0) }
        let knownIDs = Set(known)
        return known + available.filter { !knownIDs.contains($0) }
    }
}
