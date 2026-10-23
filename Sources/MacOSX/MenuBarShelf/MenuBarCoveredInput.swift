import AppKit

/// A click outside an open drawer dismisses it, as with a native popup. Consume
/// both halves while the covered native bar returns to its original layout.
/// The apple is routed back to our existing status-item handler after settling.
@MainActor final class MenuBarCoveredInput {
    var onDismiss: ((Bool) -> Void)?
    var onApple: ((NSEvent) -> Void)?
    var onIdle: (() -> Void)?
    private var regions: [CGRect] = []
    private var apple = CGRect.zero
    private var held: [Int64: Bool] = [:]
    private var apples: [CGEvent] = []
    private var dismissing = false, uncovered = false
    private var delivering = false
    private var epoch: UInt64 = 0
    var isRouting: Bool { !regions.isEmpty || !held.isEmpty || dismissing || delivering }
    func arm(regions: [CGRect], apple: CGRect) -> Bool {
        guard !isRouting else { return false }
        epoch &+= 1; self.regions = regions; self.apple = apple; uncovered = false; return true
    }
    func consume(_ type: CGEventType, event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData) != MenuBarDrawerInput.eventMark else { return false }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        let down = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
        let up = [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(type)
        guard down || up || [CGEventType.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(type) else { return false }
        if down, regions.contains(where: { $0.contains(event.location) }) {
            let isApple = apple.contains(event.location); held[button] = isApple
            if !dismissing {
                dismissing = true
                let expected = epoch
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.epoch == expected else { return }; self.onDismiss?(isApple)
                }
            }
            return true
        }
        guard let isApple = held[button] else { return false }
        if up {
            held.removeValue(forKey: button)
            if isApple, let copy = event.copy(), apples.count < 8 { apples.append(copy) }
            deliverIfUncovered()
        }
        return true
    }
    func uncover() { regions.removeAll(); uncovered = true; deliverIfUncovered() }
    func updateRegions(_ regions: [CGRect]) { if !dismissing, !uncovered { self.regions = regions } }
    private func deliverIfUncovered() {
        guard uncovered, !delivering, !apples.isEmpty || held.isEmpty else { return }
        let events = apples; apples.removeAll()
        let callback = onApple
        let expected = epoch; delivering = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.epoch == expected else { return }
            for event in events where self.epoch == expected { if let native = NSEvent(cgEvent: event) { callback?(native) } }
            guard self.epoch == expected else { return }; self.delivering = false
            if !self.apples.isEmpty { self.deliverIfUncovered() }
            else if self.held.isEmpty { self.dismissing = false; self.onIdle?() }
        }
    }
    func cancel() { epoch &+= 1; regions.removeAll(); held.removeAll(); apples.removeAll(); dismissing = false; uncovered = false; delivering = false }
}
