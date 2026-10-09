import AppKit

/// An editing surface. Membership and ordering are its only operations.
@MainActor final class ModuleCatalogView: NSView {
    static let dragType = NSPasteboard.PasteboardType("cc.anjing.macos-x.catalog-order")
    private(set) var added: [Tool]
    var onToggle: ((Tool) -> Void)?
    var onReorder: (([Tool]) -> Void)?
    private var cards: [ModuleCatalogCard] = []
    private let selectedLabel = NSTextField(labelWithString: "已添加 · 拖动调整首页顺序")
    private let availableLabel = NSTextField(labelWithString: "可添加")
    private let note = NSTextField(labelWithString: "移除保留设置和内容 · 功能设置从首页进入")
    private var measuredHeight: CGFloat = 450
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: measuredHeight) }
    init(added: [Tool]) {
        self.added = added; super.init(frame: CGRect(x: 0, y: 0, width: 840, height: 450))
        for label in [selectedLabel, availableLabel, note] { addSubview(label); label.setAccessibilityElement(false) }
        selectedLabel.font = SketchPalette.heading(18); availableLabel.font = SketchPalette.heading(18)
        note.font = .systemFont(ofSize: 12); note.textColor = SketchPalette.muted
        registerForDraggedTypes([Self.dragType]); configure(added: added)
    }
    required init?(coder: NSCoder) { nil }
    func configure(added: [Tool]) {
        let focus = (window?.firstResponder as? ModuleCatalogCard)?.tool
            ?? ((window?.firstResponder as? NSView)?.superview as? ModuleCatalogCard)?.tool
        self.added = added
        cards.forEach { $0.removeFromSuperview() }
        cards = (added + Tool.allCases.filter { !added.contains($0) }).map { tool in
            let card = ModuleCatalogCard(tool: tool, added: added.contains(tool))
            card.onToggle = { [weak self] in self?.onToggle?(tool) }
            card.onMove = { [weak self] step in self?.move(tool, by: step) }
            if let index = added.firstIndex(of: tool) { card.configurePosition(index: index, count: added.count) }
            addSubview(card); return card
        }
        selectedLabel.stringValue = added.isEmpty ? "已添加 · 暂无，选择下方功能开始" : "已添加 · 拖动调整首页顺序"
        availableLabel.stringValue = added.count == Tool.allCases.count ? "全部功能已添加" : "可添加"
        needsLayout = true; layoutSubtreeIfNeeded()
        window?.contentView?.needsLayout = true; window?.recalculateKeyViewLoop()
        if let focus, let replacement = cards.first(where: { $0.tool == focus }) { window?.makeFirstResponder(replacement) }
    }
    func move(_ tool: Tool, by step: Int) {
        guard let source = added.firstIndex(of: tool), added.indices.contains(source + step) else { return }
        place(tool, at: source + step)
    }
    func place(_ tool: Tool, at target: Int) {
        guard let source = added.firstIndex(of: tool), added.indices.contains(target), source != target else { return }
        var order = added; order.remove(at: source); order.insert(tool, at: target); onReorder?(order)
    }
    override func layout() {
        super.layout()
        let width = max(220, bounds.width), gap: CGFloat = 16, cardHeight: CGFloat = 168
        let columns = max(1, Int((width + gap) / 196)), cardWidth = min(200, (width - CGFloat(columns - 1) * gap) / CGFloat(columns))
        selectedLabel.frame = CGRect(x: 0, y: 0, width: width, height: 26)
        func arrange(_ items: [ModuleCatalogCard], at top: CGFloat) -> CGFloat {
            for (index, card) in items.enumerated() {
                card.frame = CGRect(x: CGFloat(index % columns) * (cardWidth + gap), y: top + CGFloat(index / columns) * (cardHeight + gap), width: cardWidth, height: cardHeight)
            }
            let rows = (items.count + columns - 1) / columns
            return top + CGFloat(rows) * (cardHeight + gap)
        }
        let next = arrange(cards.filter(\.isAdded), at: 36)
        availableLabel.frame = CGRect(x: 0, y: next + 8, width: width, height: 26)
        let end = arrange(cards.filter { !$0.isAdded }, at: next + 44)
        note.frame = CGRect(x: 0, y: end + 4, width: width, height: 24)
        let height = end + 36
        if measuredHeight != height { measuredHeight = height; invalidateIntrinsicContentSize(); superview?.needsLayout = true }
    }
    private func dropTarget(_ sender: NSDraggingInfo) -> (ModuleCatalogCard, Int)? {
        guard let source = sender.draggingSource as? ModuleCatalogCard, source.superview === self,
              source.isAdded, sender.draggingPasteboard.string(forType: Self.dragType) == source.tool.rawValue else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard let index = added.indices.first(where: { cards[$0].frame.contains(point) }), cards[index] !== source else { return nil }
        return (source, index)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(sender)
        for (index, card) in cards.enumerated() { card.dropHighlighted = index == target?.1 }
        return target == nil ? [] : .move
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { cards.forEach { $0.dropHighlighted = false } }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { dropTarget(sender) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (source, index) = dropTarget(sender) else { return false }
        cards.forEach { $0.dropHighlighted = false }; place(source.tool, at: index); return true
    }
}

@MainActor final class ModuleCatalogCard: NSControl, NSDraggingSource {
    let tool: Tool, isAdded: Bool
    private let art: NSImage?
    let membership = MinimalButton(title: "", target: nil, action: nil, style: .quiet)
    private let previous = MinimalButton(title: "‹", target: nil, action: nil, style: .quiet)
    private let next = MinimalButton(title: "›", target: nil, action: nil, style: .quiet)
    var onToggle: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var dropHighlighted = false { didSet { needsDisplay = true } }
    private var down: CGPoint?
    private var dragging = false
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(tool: Tool, added: Bool) {
        self.tool = tool; isAdded = added; art = SketchCardArt.image(tool.symbol) ?? SketchIcons.image(tool.symbol, size: 96)
        super.init(frame: CGRect(x: 0, y: 0, width: 180, height: 168))
        focusRingType = .none
        membership.title = added ? "− 移除" : "＋ 添加"; membership.target = self; membership.action = #selector(toggle)
        membership.setAccessibilityLabel("\(added ? "移除" : "添加")\(tool.title)")
        previous.target = self; previous.action = #selector(movePrevious); previous.setAccessibilityLabel("前移\(tool.title)")
        next.target = self; next.action = #selector(moveNext); next.setAccessibilityLabel("后移\(tool.title)")
        addSubview(membership)
        if added { addSubview(previous); addSubview(next) }
        setAccessibilityRole(.group); setAccessibilityLabel("\(tool.title)，\(added ? "已添加" : "未添加")")
        toolTip = added ? "拖动调整首页位置，也可用左右按钮或方向键" : "点击添加按钮加入首页"
    }
    required init?(coder: NSCoder) { nil }
    func configurePosition(index: Int, count: Int) { previous.isEnabled = index > 0; next.isEnabled = index + 1 < count }
    @objc private func toggle() { onToggle?() }
    @objc private func movePrevious() { onMove?(-1) }
    @objc private func moveNext() { onMove?(1) }
    override func layout() {
        super.layout()
        membership.frame = CGRect(x: bounds.midX - 36, y: 8, width: 72, height: 28)
        previous.frame = CGRect(x: 8, y: 8, width: 26, height: 28)
        next.frame = CGRect(x: bounds.width - 34, y: 8, width: 26, height: 28)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 1, dy: 1), radius: 12)
        SketchPalette.fill(path, color: SketchPalette.paper)
        let highlighted = dropHighlighted || window?.firstResponder === self
        SketchPencil.stroke(path, color: highlighted ? SketchPalette.yellow : SketchPalette.line, width: highlighted ? 2 : 1)
        art?.draw(in: CGRect(x: bounds.midX - 46, y: 56, width: 92, height: 92), from: .zero, operation: .sourceOver, fraction: 1)
        let style = NSMutableParagraphStyle(); style.alignment = .center
        (tool.title as NSString).draw(in: CGRect(x: 4, y: 38, width: bounds.width - 8, height: 24), withAttributes: [.font: SketchPalette.heading(16), .foregroundColor: SketchPalette.ink, .paragraphStyle: style])
    }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); down = convert(event.locationInWindow, from: nil); dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard isAdded, !dragging, let down else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - down.x, point.y - down.y) >= 4 else { return }
        dragging = true
        let value = NSPasteboardItem(); value.setString(tool.rawValue, forType: ModuleCatalogView.dragType)
        let item = NSDraggingItem(pasteboardWriter: value)
        let picture = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) { cacheDisplay(in: bounds, to: bitmap); picture.addRepresentation(bitmap) }
        item.setDraggingFrame(bounds, contents: picture)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { down = nil; dragging = false }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { down = nil; dragging = false }
    override func keyDown(with event: NSEvent) {
        if isAdded, !event.isARepeat, event.keyCode == 123 || event.keyCode == 124 { onMove?(event.keyCode == 123 ? -1 : 1) }
        else { super.keyDown(with: event) }
    }
}
