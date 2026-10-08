import AppKit
import MacOSXCore

struct PromptPresentation: Equatable {
    enum Style: String { case ring, list }
    var style: Style = .ring
    var wheelCount = 10
    var listCount = 10
    var count: Int { min(10, max(0, style == .ring ? wheelCount : listCount)) }
}

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
            SketchPalette.fill(sector, color: active ? SketchPalette.purple.withAlphaComponent(0.20) : SketchPalette.paper)
            SketchPencil.stroke(sector, color: active ? SketchPalette.purple : SketchPalette.line.withAlphaComponent(0.6), width: active ? 0.85 : 0.55)
            let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: isEnabled ? (active ? SketchPalette.purple : SketchPalette.ink) : SketchPalette.muted])
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            let styled = NSMutableAttributedString(attributedString: text); styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
            let width = max(1,bounds.width-10)
            let height = min(30,ceil(styled.boundingRect(with:CGSize(width:width,height:30),options:[.usesLineFragmentOrigin]).height))
            let rect = CGRect(x:5,y:bounds.midY-height/2,width:width,height:height)
            styled.draw(with: rect, options: [.usesLineFragmentOrigin])
        }
    }
    var visibleCount = 10 { didSet { needsLayout = true; needsDisplay = true } }
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
            card.toolTip = entry.content.isEmpty ? nil : String(entry.content.prefix(400))
            card.title = title
            card.isEnabled = editing || !entry.content.isEmpty
            card.state = selected == i ? .on : .off
            card.setAccessibilityLabel(editing ? "位置 \(i+1)：\(title)" : title)
            card.needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard visibleCount > 0 else { return }
        let diameter = min(bounds.width, bounds.height) - 24
        let circle = NSBezierPath(ovalIn: CGRect(x: bounds.midX-diameter/2,y: bounds.midY-diameter/2,width: diameter,height: diameter))
        SketchPalette.paper.setFill(); circle.fill()
        SketchPencil.stroke(circle, color: SketchPalette.line.withAlphaComponent(0.35), width: 0.65)
    }
    override func layout() {
        super.layout()
        let count = min(10, max(0, visibleCount))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(30, min(bounds.width, bounds.height)/2 - 56)
        let width = min(76, radius * 0.54)
        for (index, card) in cards.enumerated() {
            card.isHidden = index >= count
            guard !card.isHidden else { continue }
            let angle = (90 - CGFloat(index) * 360 / CGFloat(count)) * .pi / 180
            card.frame = CGRect(x: center.x + cos(angle)*radius-width/2,
                                y: center.y + sin(angle)*radius-21, width: width, height: 42)
            card.sector = SketchPencil.outline(in: card.bounds.insetBy(dx:1,dy:1), radius: 8)
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
    init(anchor: CGPoint, screen: CGRect, collection: PromptCollection, presentation: PromptPresentation = .init()) {
        let maximum = CGSize(width:min(360,screen.width-16),height:min(360,screen.height-16))
        wheel = PromptWheelView(size: maximum, collection: collection, presentation: presentation)
        let size = wheel.preferredSize
        let width = size.width, height = size.height
        let x = min(max(screen.minX + 8, anchor.x - width / 2), screen.maxX - width - 8)
        let y = min(max(screen.minY + 8, anchor.y - height / 2), screen.maxY - height - 8)
        super.init(contentRect: CGRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        appearance = NSAppearance(named: .aqua)
        backgroundColor = .clear; isOpaque = false; hasShadow = true; isReleasedWhenClosed = false
        level = .popUpMenu; hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        title = "提示词库"; contentView = wheel; delegate = self
        wheel.onChoose = { [weak self] in self?.onChoose?($0) }
        wheel.onCancel = { [weak self] in self?.onCancel?() }
        wheel.onResize = { [weak self] size in
            guard let self else { return }
            let x = min(max(screen.minX+8, anchor.x-size.width/2),screen.maxX-size.width-8)
            let y = min(max(screen.minY+8, anchor.y-size.height/2),screen.maxY-size.height-8)
            self.setFrame(CGRect(x:x,y:y,width:size.width,height:size.height), display:true, animate:false)
            self.wheel.needsLayout = true; self.wheel.layoutSubtreeIfNeeded()
        }
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

/// Small title-only rows inside the wheel; selection uses the shared pencil palette.
@MainActor private final class PromptSearchResult: NSButton {
    var onHover: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?() }
    override func draw(_ dirtyRect: NSRect) {
        let active = state == .on
        if active {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            SketchPalette.fill(path, color: SketchPalette.purple.withAlphaComponent(0.12))
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
            .foregroundColor: active ? SketchPalette.purple : SketchPalette.ink,
            .paragraphStyle: paragraph
        ])
        text.draw(in: CGRect(x: 8, y: (bounds.height - 15)/2, width: bounds.width - 16, height: 15))
    }
}

@MainActor final class PromptWheelView: NSView, NSSearchFieldDelegate {
    var onResize: ((CGSize) -> Void)?
    var onEditSlot: ((Int) -> Void)?
    var onEditPrompt: ((Int) -> Void)?
    private let editing: Bool
    private let editingSelection: Int?
    private let maximum: CGSize
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    let search = SketchSearchField()
    private let collection: PromptCollection
    private let presentation: PromptPresentation
    private let surface = SketchSurface()
    private let ring: PromptRingView
    private var displayed: [Int] = []
    private let resultsPerPage = 10
    private var results: [PromptSearchResult] = []
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
    init(size: CGSize, collection: PromptCollection, presentation: PromptPresentation, editing: Bool = false, selectedPrompt: Int? = nil) {
        self.editing = editing; self.editingSelection = selectedPrompt
        self.collection = collection; self.presentation = presentation; self.maximum = size
        ring = PromptRingView(size: size)
        super.init(frame: CGRect(origin: .zero, size: size)); setAccessibilityLabel("提示词库")
        search.delegate = self; search.placeholderString = ""; search.focusRingType = .none
        search.font = .systemFont(ofSize: 12); search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("搜索提示词标题")
        surface.radius = 16; surface.edge = SketchPalette.line.withAlphaComponent(0.6)
        addSubview(surface); addSubview(search)
        preview.font = .systemFont(ofSize: 12); preview.textColor = .secondaryLabelColor
        preview.maximumNumberOfLines = 4; preview.lineBreakMode = .byTruncatingTail
        preview.setAccessibilityLabel("提示词内容预览"); addSubview(preview)
        empty.font = .systemFont(ofSize: 12); empty.textColor = .tertiaryLabelColor; addSubview(empty)
        ring.visibleCount = presentation.count
        addSubview(ring, positioned: .below, relativeTo: search)
        ring.onChoose = { [weak self] slot in
            guard let self, self.displayed.indices.contains(slot) else { return }
            if self.editing { self.onEditSlot?(slot) } else { self.choose(self.displayed[slot]) }
        }
        ring.onHover = { [weak self] slot in guard let self, !self.searching, self.displayed.indices.contains(slot), self.displayed[slot] >= 0 else { return }; self.highlight(self.displayed[slot]) }
        for row in 0..<resultsPerPage {
            let result = PromptSearchResult(title: "", target: self, action: #selector(pickedResult(_:)))
            result.isBordered = false; result.focusRingType = .none
            result.tag = row
            result.onHover = { [weak self] in
                guard let self, self.showsList, self.matches.indices.contains(self.page * self.resultsPerPage + row) else { return }
                self.highlight(self.matches[self.page * self.resultsPerPage + row])
            }
            addSubview(result); results.append(result)
        }
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        pageLabel.font = .systemFont(ofSize: 10); pageLabel.textColor = .tertiaryLabelColor; pageLabel.alignment = .center
        addSubview(previous); addSubview(next); addSubview(pageLabel)
        refreshSearch()
    }
    required init?(coder: NSCoder) { nil }
    func finish() { finished = true; onChoose = nil; onCancel = nil; search.delegate = nil; ring.onHover = nil; ring.onChoose = nil; onResize = nil; onEditSlot = nil; onEditPrompt = nil }
    private var showsList: Bool { searching || presentation.style == .list || presentation.count == 0 }
    var preferredSize: CGSize {
        if !showsList { return maximum }
        let rows = min(resultsPerPage, matches.count)
        let height = min(maximum.height,max(100,84+CGFloat(rows)*25+(matches.count>resultsPerPage ? 24 : 0)))
        return CGSize(width:min(320,maximum.width),height:ceil(height/2)*2)
    }
    override func layout() {
        super.layout(); ring.frame = bounds; surface.frame = bounds.insetBy(dx:8,dy:8)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let count = searching ? min(resultsPerPage, matches.count) : matches.count
        let rowHeight: CGFloat = 25
        let blockHeight = CGFloat(count)*rowHeight + (searching && matches.count > resultsPerPage ? 74 : 50)
        // Centre the whole list block, rather than squeezing it into the wheel's hole.
        let top = min(bounds.maxY-20, center.y + blockHeight/2)
        search.frame = showsList ? CGRect(x:28,y:top-30,width:bounds.width-56,height:30)
                                : CGRect(x:center.x-66,y:center.y-15,width:132,height:30)
        preview.frame = CGRect(x:center.x-62,y:center.y-68,width:124,height:44)
        empty.frame = CGRect(x:28,y:search.frame.minY-32,width:bounds.width-56,height:22)
        for (row, result) in results.enumerated() {
            result.frame = CGRect(x:28,y:search.frame.minY-10-CGFloat(row+1)*rowHeight,width:bounds.width-56,height:rowHeight)
        }
        let footer = max(16, search.frame.minY-10-CGFloat(count)*rowHeight-28)
        previous.frame = CGRect(x:center.x-56,y:footer,width:26,height:24)
        next.frame = CGRect(x:center.x+30,y:footer,width:26,height:24)
        pageLabel.frame = CGRect(x:center.x-28,y:footer+3,width:56,height:18)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        if search.stringValue.count > PromptLibrary.titleLimit { search.stringValue = String(search.stringValue.prefix(PromptLibrary.titleLimit)) }
        refreshSearch()
    }
    private func refreshSearch() {
        searching = !search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        matches = searching ? collection.search(search.stringValue) : collection.slots.prefix(presentation.count).compactMap { id in
            id.flatMap { key in collection.prompts.firstIndex(where: { $0.id == key && !$0.content.isEmpty }) }
        }
        page = 0; selected = editing && editingSelection.map({ matches.contains($0) }) == true ? editingSelection : (showsList ? matches.first : nil)
        refreshRing(); needsLayout = true
        onResize?(preferredSize)
    }
    @objc private func previousPage() { changePage(-1) }
    @objc private func nextPage() { changePage(1) }
    private func changePage(_ delta: Int) {
        let count = max(1, (matches.count + resultsPerPage - 1)/resultsPerPage)
        page = (page+delta+count)%count; selected = matches.indices.contains(page*resultsPerPage) ? matches[page*resultsPerPage] : nil
        refreshRing(); needsLayout = true
    }
    private func refreshRing() {
        // Preset slot identities stay stable; search uses the shared full list layout.
        displayed = collection.slots.map { id in id.flatMap { key in collection.prompts.firstIndex(where: { $0.id == key }) } ?? -1 }
        for (row, result) in results.enumerated() {
            let position = page * resultsPerPage + row
            result.isHidden = !showsList || !matches.indices.contains(position)
            guard !result.isHidden else { continue }
            let prompt = collection.prompts[matches[position]]
            result.title = prompt.title; result.toolTip = String(prompt.content.prefix(400))
            result.state = selected == matches[position] ? .on : .off
            result.setAccessibilityLabel(prompt.title)
            result.needsDisplay = true
        }
        let entries = displayed.map { i -> PromptEntry in
            guard collection.prompts.indices.contains(i) else { return .init(title:"",content:"") }
            return .init(title:collection.prompts[i].title,content:collection.prompts[i].content)
        }
        ring.isHidden = showsList; surface.isHidden = !showsList
        ring.update(entries, selected: searching ? nil : selected.flatMap { displayed.firstIndex(of:$0) }, editing: editing)
        empty.isHidden = !searching || !matches.isEmpty
        let pages = max(1,(matches.count + resultsPerPage - 1)/resultsPerPage)
        previous.isHidden = !searching || pages<2; next.isHidden = previous.isHidden; pageLabel.isHidden = previous.isHidden
        pageLabel.stringValue = "\(page+1)/\(pages)"
        preview.isHidden = showsList || selected == nil
        preview.stringValue = selected.map { String(collection.prompts[$0].content.prefix(400)) } ?? ""
    }
    @objc private func pickedResult(_ sender: NSButton) {
        let position = page * resultsPerPage + sender.tag
        guard showsList, matches.indices.contains(position) else { return }
        choose(matches[position])
    }
    private func highlight(_ index: Int) {
        guard !finished, selected != index, collection.prompts.indices.contains(index), !collection.prompts[index].content.isEmpty else { return }
        selected = index; refreshRing()
    }
    private func choose(_ index: Int) {
        guard !finished, collection.prompts.indices.contains(index), !collection.prompts[index].content.isEmpty else { return }
        if editing { onEditPrompt?(index); return }
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
            if showsList { page = position/resultsPerPage }; refreshRing(); needsLayout = true

            return true
        }
        return false
    }
}
