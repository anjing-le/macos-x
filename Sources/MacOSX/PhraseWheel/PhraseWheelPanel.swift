import AppKit
import MacOSXCore

@MainActor final class PhraseWheelPanel: NSPanel, NSWindowDelegate {
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private let wheel: PromptWheelView
    private var outsideMonitor: Any?
    init(anchor: CGPoint, screen: CGRect, entries: [PromptEntry]) {
        let width = min(500, max(300, screen.width - 16)), height = min(440, max(300, screen.height - 16))
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
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.onCancel?() }
        }
    }
    func dismiss() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        delegate = nil; onChoose = nil; onCancel = nil; wheel.finish()
        acceptsMouseMovedEvents = false; orderOut(nil); close()
    }
    func windowDidResignKey(_ notification: Notification) { onCancel?() }
}

@MainActor private final class PromptWheelView: NSView, NSSearchFieldDelegate {
    private final class Card: MinimalButton {
        var onHover: (() -> Void)?
        override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onHover?() }
    }
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    let search = NSSearchField()
    private let entries: [PromptEntry]
    private var cards: [Card] = [], resultCards: [Card] = []
    private let results = NSScrollView()
    private let resultDocument = FlippedView()
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(labelWithString: "无匹配")
    private var matches: [Int] = []
    private var selected: Int?
    private var searching = false
    private var finished = false
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
    init(size: CGSize, entries: [PromptEntry]) {
        self.entries = entries
        super.init(frame: CGRect(origin: .zero, size: size)); setAccessibilityLabel("提示词库")
        search.delegate = self; search.placeholderString = "搜索标题"; search.focusRingType = .none
        search.font = .systemFont(ofSize: 12); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索提示词标题")
        addSubview(search)
        preview.font = .systemFont(ofSize: 12); preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 8; preview.lineBreakMode = .byTruncatingTail
        preview.setAccessibilityLabel("提示词内容预览"); addSubview(preview)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor; addSubview(empty)
        results.drawsBackground = false; results.hasVerticalScroller = true; results.autohidesScrollers = true
        results.documentView = resultDocument; addSubview(results)
        for (index, entry) in entries.enumerated() {
            let card = Card(title: entry.title.isEmpty ? "—" : entry.title, target: self, action: #selector(chooseCard(_:)), style: .quiet)
            card.tag = index; card.font = .systemFont(ofSize: 11, weight: .medium)
            card.lineBreakMode = .byTruncatingTail; card.isEnabled = !entry.content.isEmpty
            card.setAccessibilityLabel(entry.title.isEmpty ? "未设置的常用位置" : entry.title)
            card.onHover = { [weak self] in self?.highlight(index) }
            addSubview(card); cards.append(card)
        }
        refreshSearch()
    }
    required init?(coder: NSCoder) { nil }
    func finish() { finished = true; onChoose = nil; onCancel = nil; search.delegate = nil; cards.forEach { $0.onHover = nil }; resultCards.forEach { $0.onHover = nil } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 22, yRadius: 22).fill()
    }
    override func layout() {
        super.layout()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(174, min(bounds.width - 124, bounds.height - 44) / 2)
        for (index, card) in cards.enumerated() {
            let angle = .pi / 2 - CGFloat(index) * .pi * 2 / 10
            card.frame = CGRect(x: center.x + cos(angle) * radius - 56, y: center.y + sin(angle) * radius - 16, width: 112, height: 32)
        }
        search.frame = CGRect(x: center.x - 94, y: center.y + 62, width: 188, height: 30)
        if searching {
            results.frame = CGRect(x: 24, y: center.y - 104, width: 210, height: 156)
            preview.frame = CGRect(x: bounds.width / 2 + 16, y: center.y - 104, width: max(80, bounds.width / 2 - 40), height: 156)
        } else { preview.frame = CGRect(x: center.x - 92, y: center.y - 80, width: 184, height: 130) }
        empty.frame = CGRect(x: 34, y: center.y + 18, width: 180, height: 22)
        resultDocument.frame = CGRect(x: 0, y: 0, width: results.contentSize.width, height: max(results.contentSize.height, CGFloat(resultCards.count) * 34))
        for (index, card) in resultCards.enumerated() { card.frame = CGRect(x: 0, y: CGFloat(index) * 34, width: resultDocument.bounds.width, height: 32) }
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if search.stringValue.count > PromptLibrary.titleLimit { search.stringValue = String(search.stringValue.prefix(PromptLibrary.titleLimit)) }
        refreshSearch()
    }
    private func refreshSearch() {
        searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        matches = PromptLibrary.matches(entries, query: search.stringValue)
        cards.forEach { $0.isHidden = searching }
        results.isHidden = !searching; empty.isHidden = !searching || !matches.isEmpty
        resultCards.forEach { $0.removeFromSuperview() }; resultCards.removeAll()
        if searching {
            for index in matches {
                let card = Card(title: entries[index].title, target: self, action: #selector(chooseCard(_:)), style: .quiet)
                card.tag = index; card.font = .systemFont(ofSize: 12); card.lineBreakMode = .byTruncatingTail
                card.onHover = { [weak self] in self?.highlight(index) }; resultDocument.addSubview(card); resultCards.append(card)
            }
        }
        selected = searching ? matches.first : nil
        updatePreview(); needsLayout = true
    }
    private func highlight(_ index: Int) {
        guard !finished, entries.indices.contains(index), !entries[index].content.isEmpty else { return }
        selected = index; updatePreview()
    }
    private func updatePreview() {
        preview.stringValue = selected.map { String(entries[$0].content.prefix(400)) } ?? ""
        for card in cards + resultCards { card.state = card.tag == selected ? .on : .off }
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
            if searching { resultDocument.scrollToVisible(resultCards[position].frame) }
            return true
        }
        return false
    }
}
