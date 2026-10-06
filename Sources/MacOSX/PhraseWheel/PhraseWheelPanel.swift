import AppKit
import MacOSXCore

@MainActor final class PhraseWheelPanel: NSPanel, NSWindowDelegate {
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private let wheel: PromptWheelView
    private var outsideMonitor: Any?
    private var localOutsideMonitor: Any?
    init(anchor: CGPoint, screen: CGRect, entries: [PromptEntry]) {
        let width = min(360, screen.width - 16), height = min(360, screen.height - 16)
        let x = min(max(screen.minX + 8, anchor.x - width / 2), screen.maxX - width - 8)
        let y = min(max(screen.minY + 8, anchor.y - height / 2), screen.maxY - height - 8)
        wheel = PromptWheelView(size: CGSize(width: width, height: height), entries: entries)
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
    var onCancel: (() -> Void)?
    let search = NSSearchField()
    private let entries: [PromptEntry]
    private var cards: [Card] = []
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(labelWithString: "无匹配")
    private var matches: [Int] = []
    private var selected: Int?
    private var searching = false
    private var finished = false
    init(size: CGSize, entries: [PromptEntry]) {
        self.entries = entries
        super.init(frame: CGRect(origin: .zero, size: size)); setAccessibilityLabel("提示词库")
        search.delegate = self; search.placeholderString = "搜索标题"; search.focusRingType = .none
        search.font = .systemFont(ofSize: 12); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索提示词标题")
        addSubview(search)
        preview.font = .systemFont(ofSize: 12); preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 4; preview.lineBreakMode = .byTruncatingTail
        preview.setAccessibilityLabel("提示词内容预览"); addSubview(preview)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor; addSubview(empty)
        for (index, entry) in entries.enumerated() {
            let card = Card(title: entry.title.isEmpty ? "—" : entry.title, target: self, action: #selector(chooseCard(_:)))
            card.tag = index; card.font = .systemFont(ofSize: 11, weight: .medium)
            card.lineBreakMode = .byTruncatingTail; card.isEnabled = !entry.content.isEmpty
            card.setAccessibilityLabel(entry.title.isEmpty ? "未设置的常用位置" : entry.title)
            card.onHover = { [weak self] in self?.highlight(index) }
            addSubview(card); cards.append(card)
        }
        refreshSearch()
    }
    required init?(coder: NSCoder) { nil }
    func finish() { finished = true; onChoose = nil; onCancel = nil; search.delegate = nil; cards.forEach { $0.onHover = nil } }
    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height) - 16
        let circle = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter, height: diameter)
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(ovalIn: circle).fill()
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
        search.frame = CGRect(x: center.x - 68, y: center.y + 25, width: 136, height: 26)
        preview.frame = CGRect(x: center.x - 62, y: center.y - 50, width: 124, height: 64)
        empty.frame = CGRect(x: center.x - 60, y: center.y, width: 120, height: 22)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if search.stringValue.count > PromptLibrary.titleLimit { search.stringValue = String(search.stringValue.prefix(PromptLibrary.titleLimit)) }
        refreshSearch()
    }
    private func refreshSearch() {
        searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        matches = PromptLibrary.matches(entries, query: search.stringValue)
        for (index, card) in cards.enumerated() {
            card.isEnabled = matches.contains(index)
            card.alphaValue = searching && !matches.contains(index) ? 0.3 : 1
            card.needsDisplay = true
        }
        empty.isHidden = !searching || !matches.isEmpty
        selected = searching ? matches.first : nil
        updatePreview(); needsLayout = true
    }
    private func highlight(_ index: Int) {
        guard !finished, entries.indices.contains(index), !entries[index].content.isEmpty else { return }
        selected = index; updatePreview()
    }
    private func updatePreview() {
        preview.stringValue = selected.map { String(entries[$0].content.prefix(400)) } ?? ""
        for card in cards { card.state = card.tag == selected ? .on : .off; card.needsDisplay = true }
    }
    @objc private func chooseCard(_ sender: NSButton) { choose(sender.tag) }
    private func choose(_ index: Int) {
        guard !finished, entries.indices.contains(index), !entries[index].content.isEmpty else { return }
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
            updatePreview()

            return true
        }
        return false
    }
}
