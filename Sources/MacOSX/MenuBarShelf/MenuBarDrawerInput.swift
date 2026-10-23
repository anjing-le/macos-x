import AppKit

/// Only cached hit testing runs on this tap. No AX, window inventory, I/O or
/// async waiting is allowed here. Unknown/system/own items remain native.
@MainActor final class MenuBarDrawerInput {
    static let eventMark: Int64 = 0x4d5844524157
    var entries: [MenuBarEntry] = []
    var canBegin: () -> Bool = { true }
    var onCancel: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onCoveredInput: ((CGEventType, CGEvent) -> Bool)?
    var onBegin: ((MenuBarEntry, CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var enabled = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var dragging = false
    private var prepared = false
    private var preparation: DispatchWorkItem?
    private var deliveryEpoch: UInt64 = 0
    private var dragDelivery: DispatchWorkItem?
    private var latestDrag: CGPoint?
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .flagsChanged]
        let mask: CGEventMask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<MenuBarDrawerInput>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.cancelPendingGesture()
                        owner.deferDelivery { $0.onCancel?() }
                        if let tap = owner.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                        return Unmanaged.passUnretained(event)
                    }
                    return owner.consume(type, event: event) ? nil : Unmanaged.passUnretained(event)
                }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }
    func consume(_ type: CGEventType, event: CGEvent) -> Bool {
        guard enabled, event.getIntegerValueField(.eventSourceUserData) != Self.eventMark else { return false }
        let customDrag = type == .leftMouseDown && canBegin() && event.flags.contains(.maskCommand)
            && entries.contains { $0.frame.contains(event.location) }
        if !dragging, !customDrag, onCoveredInput?(type, event) == true { return true }
        guard dragging || type == .flagsChanged || (type == .leftMouseDown && event.flags.contains(.maskCommand)) else { return false }
        let q = event.location, top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: q.x, y: top - q.y)
        if type == .flagsChanged {
            if !event.flags.contains(.maskCommand) { prepared = false }
            else if !prepared, NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }) {
                prepared = true
                // The tap only records intent. Metadata/icon preparation happens
                // after this input callback has returned to WindowServer.
                if preparation == nil {
                    let expected = deliveryEpoch
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, self.enabled, self.deliveryEpoch == expected else { return }
                        self.preparation = nil; self.onPrepare?()
                    }
                    preparation = work; DispatchQueue.main.async(execute: work)
                }
            }
        }
        if type == .leftMouseDown, canBegin(), event.flags.contains(.maskCommand),
           let entry = entries.first(where: { $0.frame.contains(q) }) {
            dragging = true
            deferDelivery { $0.onBegin?(entry, point) }; return true
        }
        if dragging, type == .leftMouseDragged {
            latestDrag = point
            if dragDelivery == nil {
                let expected = deliveryEpoch
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.enabled, self.deliveryEpoch == expected else { return }
                    self.dragDelivery = nil
                    if let point = self.latestDrag { self.latestDrag = nil; self.onDrag?(point) }
                }
                dragDelivery = work; DispatchQueue.main.async(execute: work)
            }
            return true
        }
        if dragging, type == .leftMouseUp {
            dragging = false
            let last = latestDrag; latestDrag = nil; dragDelivery?.cancel(); dragDelivery = nil
            deferDelivery { owner in
                if let last { owner.onDrag?(last) }
                owner.onEnd?(point)
            }
            return true
        }
        return false
    }
    private func deferDelivery(_ action: @escaping (MenuBarDrawerInput) -> Void) {
        let expected = deliveryEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled, self.deliveryEpoch == expected else { return }; action(self)
        }
    }
    func cancelPendingGesture() {
        dragging = false; prepared = false
        deliveryEpoch &+= 1
        preparation?.cancel(); preparation = nil
        dragDelivery?.cancel(); dragDelivery = nil; latestDrag = nil
    }
    func stop() {
        enabled = false; entries.removeAll(); cancelPendingGesture()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        if let tap { CFMachPortInvalidate(tap) }; tap = nil
    }
    /// Replays only a drag the user just performed. Marked events bypass our
    /// own tap; no synthetic clicks or clipboard/paste injection are involved.
    static func move(from start: CGPoint, to end: CGPoint, isCurrent: @escaping () -> Bool = { true },
                     send: ((CGEventType, CGPoint) -> Void)? = nil, completion: @escaping () -> Void) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            if let send { send(type, point); return }
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand; event?.setIntegerValueField(.eventSourceUserData, value: eventMark)
            event?.post(tap: .cgSessionEventTap)
        }
        guard isCurrent() else { completion(); return }
        post(.leftMouseDown, start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            guard isCurrent() else { post(.leftMouseUp, start); completion(); return }
            post(.leftMouseDragged, end)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { post(.leftMouseUp, end); completion() }
        }
    }
}
