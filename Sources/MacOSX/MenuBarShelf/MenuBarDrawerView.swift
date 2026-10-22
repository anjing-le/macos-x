import AppKit

struct MenuDrawerItem {
    let bundle: String
    let name: String
    let icon: NSImage?
    var available = true
}

/// The identical native view is used in the popover and in the dashboard.
/// App icons identify real AX-backed entries; they do not simulate a menu.
@MainActor final class MenuBarDrawerView: NSView {
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true } } }
    var items: [MenuDrawerItem] = [] { didSet { needsDisplay = true; updateAccessibility() } }
    var selected: String? { didSet { needsDisplay = true; updateHint() } }
    var accepting = false { didSet { needsDisplay = true } }
    var onDragImage: ((MenuDrawerItem, CGPoint) -> Void)?
    var onDragFinished: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpen: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onRestore: ((String, CGPoint) -> Void)?
    var onPresence: ((Bool) -> Void)?
    var onInteraction: (() -> Void)?
    var message = "⌘ 拖入图标，收纳在这里" { didSet { updateHint() } }
    private var down: (String, CGPoint, Bool)?
    private var dragging = false
    var isDragging: Bool { dragging }
    private var dragOriginal: [MenuDrawerItem]?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var singleRow = false
    private static func width(_ item: MenuDrawerItem) -> CGFloat { max(24, min(332, (item.icon?.size.width ?? 24) + 4)) }
    static func rowWidth(_ items: [MenuDrawerItem]) -> CGFloat { 16 + items.reduce(0) { $0 + width($1) } }
    private static func frames(_ items: [MenuDrawerItem], width: CGFloat, singleRow: Bool) -> [CGRect] {
        var x: CGFloat = 8, y: CGFloat = 6
        let rowHeight = max(28, items.map { ($0.icon?.size.height ?? 24) + 4 }.max() ?? 28)
        return items.map { item in
            let w = min(Self.width(item), max(24, width - 16))
            if !singleRow, x > 8, x + w > width - 8 { x = 8; y += rowHeight + 2 }
            let result = CGRect(x: x, y: y, width: w, height: rowHeight); x += w; return result
        }
    }
    func cellFrame(_ index: Int) -> CGRect { Self.frames(items, width: bounds.width, singleRow: singleRow)[index] }
    func iconFrame(_ index: Int) -> CGRect {
        let frame = cellFrame(index), size = items[index].icon?.size ?? CGSize(width: 24, height: 24)
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }
    func index(at point: CGPoint) -> Int? { items.indices.first { cellFrame($0).contains(point) } }
    func insertion(at point: CGPoint) -> Int {
        index(at: point) ?? items.indices.min { a, b in
            let x = cellFrame(a), y = cellFrame(b)
            return hypot(x.midX - point.x, x.midY - point.y) < hypot(y.midX - point.x, y.midY - point.y)
        } ?? 0
    }
    static func height(items: [MenuDrawerItem], width: CGFloat) -> CGFloat {
        (frames(items, width: width, singleRow: false).last?.maxY ?? 34) + 6
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { updateHint(); onPresence?(true) }
    override func mouseExited(with event: NSEvent) { onPresence?(false) }
    override func mouseMoved(with event: NSEvent) {
        selected = index(at: convert(event.locationInWindow, from: nil)).map { items[$0].bundle }
        updateHint()
        onInteraction?()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self); onInteraction?()
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point) else { down = nil; return }
        dragOriginal = items
        selected = items[index].bundle; down = (items[index].bundle, point, event.modifierFlags.contains(.command)); dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        guard let down, down.2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard dragging || hypot(point.x - down.1.x, point.y - down.1.y) > 4 else { return }
        dragging = true; onInteraction?()
        if onMove != nil, bounds.contains(point), let from = items.firstIndex(where: { $0.bundle == down.0 }) {
            let to = insertion(at: point)
            if from != to { let item = items.remove(at: from); items.insert(item, at: to) }
        }
        if let item = items.first(where: { $0.bundle == down.0 }), let window { onDragImage?(item, window.convertPoint(toScreen: event.locationInWindow)) }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard isEnabled else { cancelDrag(); return }
        guard let down else { return }; self.down = nil; onInteraction?()
        defer { dragOriginal = nil; onDragFinished?(); needsDisplay = true }
        let point = convert(event.locationInWindow, from: nil)
        if dragging {
            dragging = false
            if bounds.insetBy(dx: -6, dy: -6).contains(point), let index = items.firstIndex(where: { $0.bundle == down.0 }) { onMove?(down.0, index) }
            else if let window { onRestore?(down.0, window.convertPoint(toScreen: event.locationInWindow)) }
        } else if index(at: point).map({ items[$0].bundle }) == down.0 { onOpen?(down.0) }
    }
    func cancelDrag() {
        if let original = dragOriginal { items = original }
        down = nil; dragging = false; dragOriginal = nil; onDragFinished?(); needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelDrag(); onClose?() }
        else if !isEnabled { return }
        else if event.keyCode == 36, let selected { onOpen?(selected) }
        else if event.keyCode == 123 || event.keyCode == 124 {
            guard !items.isEmpty else { return }
            let current = selected.flatMap { id in items.firstIndex { $0.bundle == id } } ?? 0
            selected = items[max(0, min(items.count - 1, current + (event.keyCode == 123 ? -1 : 1)))].bundle
        } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let outline = SketchPencil.outline(in: bounds.insetBy(dx: 2, dy: 2), radius: 12)
        SketchPalette.fill(outline, color: SketchPalette.paper)
        SketchPencil.stroke(outline, color: accepting ? SketchPalette.blue : SketchPalette.line, width: accepting ? 2.4 : 1.5)
        for (index, item) in items.enumerated() {
            let frame = cellFrame(index), isSelected = selected == item.bundle
            // Native pixels keep their original size and colours. The entire
            // slot is clickable; selection is a small underline, not a card.
            if isSelected {
                let path = NSBezierPath(); path.move(to: CGPoint(x: frame.minX + 8, y: frame.maxY - 1))
                path.line(to: CGPoint(x: frame.maxX - 8, y: frame.maxY - 1))
                SketchPencil.stroke(path, color: SketchPalette.blue, width: 2)
            }
            if !(dragging && down?.0 == item.bundle) {
                item.icon?.draw(in: iconFrame(index), from: .zero, operation: .sourceOver, fraction: isEnabled && item.available ? 1 : 0.35, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            }
            if item.icon == nil {
                let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
                (item.name as NSString).draw(in: CGRect(x: frame.minX + 3, y: frame.midY - 6, width: frame.width - 6, height: 13), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: SketchPalette.muted, .paragraphStyle: style])
            }
        }

        if items.isEmpty {
            let plus = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)
            plus?.draw(in: CGRect(x: bounds.midX - 15, y: bounds.midY - 13, width: 30, height: 26), from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: nil)
        }

    }
    private func updateHint() {
        let name = selected.flatMap { id in items.first { $0.bundle == id }?.name }
        let hint = [name, message.isEmpty ? nil : message].compactMap { $0 }.joined(separator: "\n")
        if toolTip != hint { toolTip = hint }
        setAccessibilityHelp(message)
    }
    private func updateAccessibility() {
        updateHint()
        setAccessibilityElement(false)
        setAccessibilityChildren(items.map { item -> NSAccessibilityElement in
            let element = MenuDrawerAccessibilityItem()
            element.setAccessibilityRole(.button); element.setAccessibilityLabel(item.name)
            element.setAccessibilityParent(self)
            element.owner = self; element.bundle = item.bundle
            return element
        })
    }
}

@MainActor private final class MenuDrawerAccessibilityItem: NSAccessibilityElement {
    weak var owner: MenuBarDrawerView?
    var bundle = ""
    override func isAccessibilityEnabled() -> Bool {
        owner?.isEnabled == true && owner?.onOpen != nil
            && owner?.items.contains(where: { $0.bundle == bundle && $0.available }) == true
    }
    override func accessibilityFrame() -> NSRect {
        guard let owner, let window = owner.window,
              let index = owner.items.firstIndex(where: { $0.bundle == bundle }) else { return .zero }
        let frame = owner.convert(owner.cellFrame(index), to: nil)
        return window.convertToScreen(frame)
    }
    override func accessibilityPerformPress() -> Bool {
        guard isAccessibilityEnabled(), let owner else { return false }
        owner.onOpen?(bundle); return true
    }
}
