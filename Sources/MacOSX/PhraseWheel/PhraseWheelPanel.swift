import AppKit
import MacOSXCore

@MainActor final class PromptRingView: NSView {
    private final class Card: NSButton {
        override var isFlipped: Bool { false }
        var onHover: (() -> Void)?
        var sector = NSBezierPath()
        var labelCenter = CGPoint.zero
        private var tracking: NSTrackingArea?
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, sector.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
        override func mouseMoved(with event: NSEvent) {
            if isEnabled, sector.contains(convert(event.locationInWindow, from: nil)) { onHover?() }
        }
        override func draw(_ dirtyRect: NSRect) {
            let active = state == .on
            (active ? NSColor.labelColor.withAlphaComponent(0.08) : NSColor.windowBackgroundColor).setFill()
            sector.fill()
            NSColor.labelColor.withAlphaComponent(active ? 0.13 : 0.04).setStroke(); sector.lineWidth = 0.5; sector.stroke()
            let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor])
            let rect = CGRect(x: labelCenter.x - 35, y: labelCenter.y - 10, width: 70, height: 26)
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            let styled = NSMutableAttributedString(attributedString: text); styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
            styled.draw(with: rect, options: [.usesLineFragmentOrigin])
        }
    }
    var onChoose: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    private var cards: [Card] = []
    init(size: CGSize) {
        super.init(frame: CGRect(origin: .zero, size: size))
        for i in 0..<10 {
            let card = Card(title: "—", target: self, action: #selector(picked(_:)))
            card.tag = i; card.onHover = { [weak self] in self?.onHover?(i) }; addSubview(card); cards.append(card)
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func picked(_ sender: NSButton) { onChoose?(sender.tag) }
    func update(_ entries: [PromptEntry], selected: Int?, editing: Bool = false) {
        for (i, card) in cards.enumerated() {
            let entry = entries.indices.contains(i) ? entries[i] : PromptEntry(title: "", content: "")
            let title = entry.title.isEmpty ? "+" : entry.title
            card.title = editing ? "\(i+1) · \(title)" : title
            card.isEnabled = editing || !entry.content.isEmpty
            card.state = selected == i ? .on : .off
            card.setAccessibilityLabel(editing ? "位置 \(i+1)：\(title)" : title)
            card.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height) - 16
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: CGRect(x: bounds.midX-diameter/2,y: bounds.midY-diameter/2,width: diameter,height: diameter)).fill()
    }
    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let outer = min(bounds.width, bounds.height) / 2 - 12
        let inner = outer * 0.52
        for (index, card) in cards.enumerated() {
            let angle = 90 - CGFloat(index) * 36
            let start = angle - 17.4, end = angle + 17.4
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: outer, startAngle: start, endAngle: end)
            path.appendArc(withCenter: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
            path.close()
            let box = path.bounds.insetBy(dx: -2, dy: -2)
            card.frame = box
            let transform = AffineTransform(translationByX: -box.minX, byY: -box.minY); path.transform(using: transform)
            card.sector = path
            let radians = angle * .pi / 180
            card.labelCenter = CGPoint(x: center.x + cos(radians) * (outer + inner) / 2 - box.minX, y: center.y + sin(radians) * (outer + inner) / 2 - box.minY)
            card.needsDisplay = true
        }
    }
}


@MainActor final class PhraseWheelPanel: NSPanel, NSWindowDelegate {
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private let wheel: PromptWheelView
    private var outsideMonitor: Any?
    private var localOutsideMonitor: Any?
    init(anchor: CGPoint, screen: CGRect, collection: PromptCollection) {
        let width = min(360, screen.width - 16), height = min(360, screen.height - 16)
        let x = min(max(screen.minX + 8, anchor.x - width / 2), screen.maxX - width - 8)
        let y = min(max(screen.minY + 8, anchor.y - height / 2), screen.maxY - height - 8)
        wheel = PromptWheelView(size: CGSize(width: width, height: height), collection: collection)
        super.init(contentRect: CGRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear; isOpaque = false; hasShadow = true; isReleasedWhenClosed = false
        level = .popUpMenu; hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        title = "提示词库"; contentView = wheel; delegate = self
        wheel.onChoose = { [weak self] in self?.onChoose?($0) }
        wheel.onCancel = { [weak self] in self?.onCancel?() }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 13 { onCancel?(); return true }
        return super.performKeyEquivalent(with: event)
    }
    func present() {
        acceptsMouseMovedEvents = true
        makeKeyAndOrderFront(nil); makeFirstResponder(wheel.search)
        localOutsideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self { self.onCancel?() }
            return event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel?() }
        }
    }
    func dismiss() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localOutsideMonitor { NSEvent.removeMonitor(localOutsideMonitor) }; localOutsideMonitor = nil
        delegate = nil; onChoose = nil; onCancel = nil; wheel.finish()
        acceptsMouseMovedEvents = false; orderOut(nil); close()
    }

}

@MainActor private final class PromptWheelView: NSView, NSSearchFieldDelegate {
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    let search = NSSearchField()
    private let collection: PromptCollection
    private let ring: PromptRingView
    private var displayed: [Int] = []
    private var page = 0
    private let previous = MinimalButton(title: "‹", target: nil, action: nil, style: .quiet)
    private let next = MinimalButton(title: "›", target: nil, action: nil, style: .quiet)
    private let pageLabel = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(labelWithString: "无匹配")
    private var matches: [Int] = []
    private var selected: Int?
    private var searching = false
    private var finished = false
    init(size: CGSize, collection: PromptCollection) {
        self.collection = collection
        ring = PromptRingView(size: size)
        super.init(frame: CGRect(origin: .zero, size: size)); setAccessibilityLabel("提示词库")
        search.delegate = self; search.placeholderString = "搜索标题"; search.focusRingType = .none
        search.font = .systemFont(ofSize: 12); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索提示词标题")
        addSubview(search)
        preview.font = .systemFont(ofSize: 12); preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 4; preview.lineBreakMode = .byTruncatingTail
        preview.setAccessibilityLabel("提示词内容预览"); addSubview(preview)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor; addSubview(empty)
        addSubview(ring, positioned: .below, relativeTo: search)
        ring.onChoose = { [weak self] slot in guard let self, self.displayed.indices.contains(slot) else { return }; self.choose(self.displayed[slot]) }
        ring.onHover = { [weak self] slot in guard let self, self.displayed.indices.contains(slot), self.displayed[slot] >= 0 else { return }; self.highlight(self.displayed[slot]) }
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        pageLabel.font = .systemFont(ofSize: 10); pageLabel.textColor = .tertiaryLabelColor; pageLabel.alignment = .center
        addSubview(previous); addSubview(next); addSubview(pageLabel)
        refreshSearch()
    }
    required init?(coder: NSCoder) { nil }
    func finish() { finished = true; onChoose = nil; onCancel = nil; search.delegate = nil; ring.onHover = nil; ring.onChoose = nil }
    override func layout() {
        super.layout(); ring.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        search.frame = CGRect(x: center.x-68,y: center.y+25,width:136,height:26)
        preview.frame = CGRect(x:center.x-62,y:center.y-40,width:124,height:54)
        empty.frame = CGRect(x:center.x-60,y:center.y,width:120,height:22)
        previous.frame = CGRect(x:center.x-56,y:center.y-70,width:26,height:24)
        next.frame = CGRect(x:center.x+30,y:center.y-70,width:26,height:24)
        pageLabel.frame = CGRect(x:center.x-28,y:center.y-67,width:56,height:18)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if search.stringValue.count > PromptLibrary.titleLimit { search.stringValue = String(search.stringValue.prefix(PromptLibrary.titleLimit)) }
        refreshSearch()
    }
    private func refreshSearch() {
        searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        matches = searching ? collection.search(search.stringValue) : collection.slots.compactMap { id in
            id.flatMap { key in collection.prompts.firstIndex(where: { $0.id == key && !$0.content.isEmpty }) }
        }
        page = 0; selected = searching ? matches.first : nil
        refreshRing(); needsLayout = true
    }
    @objc private func previousPage() { changePage(-1) }
    @objc private func nextPage() { changePage(1) }
    private func changePage(_ delta: Int) {
        let count = max(1, (matches.count+9)/10)
        page = (page+delta+count)%count; selected = matches.indices.contains(page*10) ? matches[page*10] : nil
        refreshRing()
    }
    private func refreshRing() {
        if searching { displayed = Array(matches.dropFirst(page*10).prefix(10)) }
        else { displayed = collection.slots.map { id in id.flatMap { key in collection.prompts.firstIndex(where: { $0.id == key }) } ?? -1 } }
        let entries = displayed.map { i -> PromptEntry in
            guard collection.prompts.indices.contains(i) else { return .init(title:"",content:"") }
            return .init(title:collection.prompts[i].title,content:collection.prompts[i].content)
        }
        ring.update(entries, selected: selected.flatMap { displayed.firstIndex(of:$0) })
        empty.isHidden = !searching || !matches.isEmpty
        let pages = max(1,(matches.count+9)/10)
        previous.isHidden = !searching || pages<2; next.isHidden = previous.isHidden; pageLabel.isHidden = previous.isHidden
        pageLabel.stringValue = "\(page+1)/\(pages)"
        preview.stringValue = selected.map { String(collection.prompts[$0].content.prefix(400)) } ?? ""
    }
    private func highlight(_ index: Int) {
        guard !finished, selected != index, collection.prompts.indices.contains(index), !collection.prompts[index].content.isEmpty else { return }
        selected = index; refreshRing()
    }
    private func choose(_ index: Int) {
        guard !finished, collection.prompts.indices.contains(index), !collection.prompts[index].content.isEmpty else { return }
        finished = true; onChoose?(index)
    }
    override func mouseDown(with event: NSEvent) {
        // Blank space inside the wheel remains safe; only explicit cards copy.
        window?.makeFirstResponder(search)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) { onCancel?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { if let selected { choose(selected) }; return true }
        if selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.moveUp(_:)) {
            guard !matches.isEmpty else { return true }
            let direction = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let current = selected.flatMap { matches.firstIndex(of: $0) }
            let position = current.map { ($0 + direction + matches.count) % matches.count } ?? (direction > 0 ? 0 : matches.count - 1)
            selected = matches[position]
            if searching { page = position/10 }; refreshRing()

            return true
        }
        return false
    }
}
