import AppKit

/// A drag belongs to one editor and one live source. The pasteboard carries only
/// an opaque token; outside apps/windows cannot supply prompt IDs or reorder it.
@MainActor final class PromptDragContext {
    static let pasteboardType = NSPasteboard.PasteboardType("cc.anjing.macos-x.prompt-position")
    enum Payload: Equatable { case preset(slot: Int, id: String); case library(id: String) }
    weak var owner: NSView?
    private weak var source: NSView?
    private var token: String?
    private var payload: Payload?
    var onEnd: (() -> Void)?

    func begin(source: NSView, payload: Payload) -> NSPasteboardItem {
        self.source = source; self.payload = payload; token = UUID().uuidString
        let item = NSPasteboardItem(); item.setString(token!, forType: Self.pasteboardType)
        return item
    }
    func acceptedPayload(from sender: NSDraggingInfo) -> Payload? {
        guard let owner, let window = owner.window, let source, source.window === window,
              sender.draggingSource as? NSView === source, sender.draggingDestinationWindow === window,
              let token, sender.draggingPasteboard.string(forType: Self.pasteboardType) == token else { return nil }
        return payload
    }
    func end() {
        let active = token != nil
        source = nil; token = nil; payload = nil
        if active { onEnd?() }
    }
}

/// In the editor a click still selects; moving at least five points starts a
/// native drag. Runtime buttons have no context and keep their normal behavior.
@MainActor class PromptDraggableButton: NSButton, NSDraggingSource {
    weak var dragContext: PromptDragContext?
    var dragPayload: PromptDragContext.Payload?
    var dropHighlighted = false { didSet { if oldValue != dropHighlighted { needsDisplay = true } } }
    private var down: CGPoint?
    private var dragging = false
    private var activeDragContext: PromptDragContext?
    var dragHitPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    func containsClick(_ point: CGPoint) -> Bool { bounds.contains(point) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, containsClick(convert(event.locationInWindow, from: nil)) else { return }
        if dragContext == nil { super.mouseDown(with: event); return }
        down = convert(event.locationInWindow, from: nil); dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled, !dragging, let down, let dragContext, let dragPayload else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x-down.x, point.y-down.y) >= 5 else { return }
        dragging = true
        activeDragContext = dragContext
        startPromptDrag(with: event, context: dragContext, payload: dragPayload, at: point)
    }
    func startPromptDrag(with event: NSEvent, context: PromptDragContext, payload: PromptDragContext.Payload, at point: CGPoint) {
        let item = NSDraggingItem(pasteboardWriter: context.begin(source: self, payload: payload))
        let picture = NSImage(size: NSSize(width: 144, height: 30), flipped: false) { rect in
            SketchPalette.fill(SketchPencil.outline(in: rect.insetBy(dx: 1, dy: 1), radius: 7), color: SketchPalette.paper)
            (self.title as NSString).draw(in: rect.insetBy(dx: 8, dy: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: SketchPalette.ink])
            return true
        }
        item.setDraggingFrame(CGRect(x: point.x-72, y: point.y-15, width: 144, height: 30), contents: picture)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil; dragging = false }
        guard dragContext != nil, down != nil, !dragging, isEnabled,
              containsClick(convert(event.locationInWindow, from: nil)), let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finishPromptDrag()
    }
    func finishPromptDrag() {
        down = nil; dragging = false; activeDragContext?.end(); activeDragContext = nil
    }
}
