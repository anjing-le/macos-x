import Foundation

public enum PhraseWheelGeometry {
    public static let slotCount = 10

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public struct Rect: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
        public func contains(_ point: Point) -> Bool {
            point.x >= x && point.x <= maxX && point.y >= y && point.y <= maxY
        }
        public func contains(_ rect: Rect) -> Bool {
            rect.x >= x && rect.maxX <= maxX && rect.y >= y && rect.maxY <= maxY
        }
    }

    public struct Slot: Sendable {
        public let center: Point
        public let frame: Rect
        public let angle: Double
        public let commitRadius: Double
    }

    public struct Layout: Sendable {
        public let anchor: Point
        public let screen: Rect
        public let panelFrame: Rect
        public let slots: [Slot]
        public let isFan: Bool
        public let deadZone: Double
        private let fanCenter: Double
        private let fanSpan: Double

        fileprivate init(anchor: Point, screen: Rect, slots: [Slot], isFan: Bool,
                         fanCenter: Double, fanSpan: Double) {
            self.anchor = anchor; self.screen = screen; self.slots = slots; self.isFan = isFan
            self.fanCenter = fanCenter; self.fanSpan = fanSpan; deadZone = 22
            let lowX = max(screen.x, min(anchor.x, slots.map { $0.frame.x }.min()!) - 8)
            let lowY = max(screen.y, min(anchor.y, slots.map { $0.frame.y }.min()!) - 8)
            let highX = min(screen.maxX, max(anchor.x, slots.map { $0.frame.maxX }.max()!) + 8)
            let highY = min(screen.maxY, max(anchor.y, slots.map { $0.frame.maxY }.max()!) + 8)
            panelFrame = Rect(x: lowX, y: lowY, width: highX - lowX, height: highY - lowY)
        }

        public func distance(to point: Point) -> Double { hypot(point.x - anchor.x, point.y - anchor.y) }

        public func selection(at point: Point) -> Int? {
            guard point.x.isFinite, point.y.isFinite, distance(to: point) > deadZone else { return nil }
            let angle = atan2(point.y - anchor.y, point.x - anchor.x)
            if isFan {
                let allowance = fanSpan / Double(PhraseWheelGeometry.slotCount - 1) / 2
                guard abs(PhraseWheelGeometry.angleDifference(angle, fanCenter)) <= fanSpan / 2 + allowance else { return nil }
            }
            return slots.indices.min {
                abs(PhraseWheelGeometry.angleDifference(angle, slots[$0].angle)) <
                abs(PhraseWheelGeometry.angleDifference(angle, slots[$1].angle))
            }
        }

        public func crossedCommitRadius(previousDistance: Double, at point: Point, slot: Int) -> Bool {
            guard slots.indices.contains(slot), previousDistance.isFinite else { return false }
            let current = distance(to: point)
            let threshold = slots[slot].commitRadius
            return current.isFinite && previousDistance >= 0 && previousDistance < threshold && current >= threshold
        }
    }

    /// The anchor stays at the cursor. Only card layout adapts near an edge.
    public static func layout(anchor: Point, screens: [Rect]) -> Layout? {
        guard anchor.x.isFinite, anchor.y.isFinite else { return nil }
        let valid = screens.filter {
            $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
        }
        guard let screen = valid.first(where: { $0.contains(anchor) }) else { return nil }
        let clearance = 166.0
        var left = anchor.x - screen.x < clearance
        var right = screen.maxX - anchor.x < clearance
        var bottom = anchor.y - screen.y < clearance
        var top = screen.maxY - anchor.y < clearance
        if left && right { left = anchor.x - screen.x <= screen.maxX - anchor.x; right = !left }
        if bottom && top { bottom = anchor.y - screen.y <= screen.maxY - anchor.y; top = !bottom }
        let isFan = left || right || bottom || top
        var center = 0.0
        var span = Double.pi
        switch (left, right, bottom, top) {
        case (true, _, _, true): center = -.pi / 4; span = .pi / 2
        case (true, _, true, _): center = .pi / 4; span = .pi / 2
        case (_, true, _, true): center = -.pi * 3 / 4; span = .pi / 2
        case (_, true, true, _): center = .pi * 3 / 4; span = .pi / 2
        case (true, _, _, _): center = 0
        case (_, true, _, _): center = .pi
        case (_, _, true, _): center = .pi / 2
        case (_, _, _, true): center = -.pi / 2
        default: break
        }
        // Keep endpoint labels clear of the screen boundary; stagger radii to avoid collisions.
        let usableSpan = span - .pi / 6
        var slots: [Slot] = []
        for index in 0..<slotCount {
            let angle = isFan
                ? center + usableSpan / 2 - usableSpan * Double(index) / Double(slotCount - 1)
                : .pi / 2 - Double(index) * .pi * 2 / Double(slotCount)
            let candidates = isFan ? stride(from: 128.0, through: 420.0, by: 12.0).map { $0 } : [128.0]
            var placed: Slot?
            for radius in candidates {
                let point = Point(x: anchor.x + cos(angle) * radius, y: anchor.y + sin(angle) * radius)
                let frame = Rect(x: point.x - 30, y: point.y - 15, width: 60, height: 30)
                let safeScreen = Rect(x: screen.x + 6, y: screen.y + 6, width: screen.width - 12, height: screen.height - 12)
                guard safeScreen.contains(frame), !slots.contains(where: {
                    abs($0.center.x - point.x) < 66 && abs($0.center.y - point.y) < 36
                }) else { continue }
                placed = Slot(center: point, frame: frame, angle: angle, commitRadius: radius * 0.88)
                break
            }
            guard let placed else { return nil }
            slots.append(placed)
        }
        return Layout(anchor: anchor, screen: screen, slots: slots, isFan: isFan, fanCenter: center, fanSpan: usableSpan)
    }

    private static func angleDifference(_ lhs: Double, _ rhs: Double) -> Double {
        atan2(sin(lhs - rhs), cos(lhs - rhs))
    }
}
