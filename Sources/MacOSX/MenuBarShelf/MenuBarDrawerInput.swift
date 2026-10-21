import AppKit

/// Only cached hit testing runs on this tap. No AX, window inventory, I/O or
/// async waiting is allowed here. Unknown/system/own items remain native.
@MainActor final class MenuBarDrawerInput {
    static let eventMark: Int64 = 0x4d5844524157
    var entries: [MenuBarEntry] = []
    var canBegin: () -> Bool = { true }
    var onCancel: (() -> Void)?
    var onPrepare: (() -> Void)?
    var onBegin: ((MenuBarEntry, CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onEnd: ((CGPoint) -> Void)?
    var enabled = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var dragging = false
    private var prepared = false
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        let mask: CGEventMask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<MenuBarDrawerInput>.fromOpaque(context).takeUnretainedValue()
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        owner.dragging = false; owner.onCancel?()
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
        let q = event.location, top = NSScreen.screens.first?.frame.maxY ?? 0
        let point = CGPoint(x: q.x, y: top - q.y)
        if type == .flagsChanged {
            if !event.flags.contains(.maskCommand) { prepared = false }
            else if !prepared, NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }) {
                prepared = true; onPrepare?()
            }
        }
        if type == .leftMouseDown, canBegin(), event.flags.contains(.maskCommand),
           let entry = entries.first(where: { $0.frame.contains(q) }) {
            dragging = true; onBegin?(entry, point); return true
        }
        if dragging, type == .leftMouseDragged { onDrag?(point); return true }
        if dragging, type == .leftMouseUp { dragging = false; onEnd?(point); return true }
        return false
    }
    func stop() {
        enabled = false; dragging = false; prepared = false; entries.removeAll()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }; source = nil
        if let tap { CFMachPortInvalidate(tap) }; tap = nil
    }
    /// Replays only a drag the user just performed. Marked events bypass our
    /// own tap; no synthetic clicks or clipboard/paste injection are involved.
    static func move(from start: CGPoint, to end: CGPoint, completion: @escaping () -> Void) {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand; event?.setIntegerValueField(.eventSourceUserData, value: eventMark)
            event?.post(tap: .cgSessionEventTap)
        }
        post(.leftMouseDown, start)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            post(.leftMouseDragged, end)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { post(.leftMouseUp, end); completion() }
        }
    }
}
