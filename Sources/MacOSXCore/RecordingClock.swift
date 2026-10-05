import Foundation

/// Monotonic elapsed time; finalization time is excluded once stopped.
public struct RecordingClock: Sendable {
    private var start: Double?
    private var stopped: Double?
    public init() {}
    public mutating func begin(at time: Double) { start = time; stopped = nil }
    public mutating func stop(at time: Double) { if stopped == nil { stopped = time } }
    public func elapsed(at time: Double) -> Double {
        guard let start, start.isFinite, time.isFinite else { return 0 }
        return max(0, (stopped ?? time) - start)
    }
    public static func display(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(min(3_599_999, max(0, seconds))) : 0
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
