import AppKit

/// Neutral surfaces; AppKit still owns tracking, actions, keyboard activation and accessibility.
@MainActor
class MinimalButton: NSButton {
    enum Style { case standard, primary, quiet, icon }
    var style: Style = .standard { didSet { updateTint() } }
    fileprivate var hovered = false
    private var hoverArea: NSTrackingArea?
    private var focusObserver: MinimalFocusObserver?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn)
        bezelStyle = .regularSquare
        isBordered = false
        focusRingType = .none
        font = SketchPalette.heading(15)
        imageScaling = .scaleProportionallyDown
        updateTint()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?, style: Style) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action; self.style = style
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
    }
    override var isEnabled: Bool { didSet { updateTint() } }
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: max(30, native.width + 16), height: max(30, native.height))
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        focusObserver = window == nil ? nil : MinimalFocusObserver(view: self) { [weak self] in self?.hovered = false }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isEnabled && cell?.isHighlighted == true
        let active = isEnabled && hovered && window?.isKeyWindow == true
        let selected = cell?.state == .on
        let fill: NSColor
        switch style {
        case .primary:
            fill = SketchPalette.yellow.withAlphaComponent(isEnabled ? (pressed ? 0.86 : active ? 0.74 : 0.62) : 0.08)
        case .standard:
            fill = SketchPalette.paper
        case .icon:
            fill = SketchPalette.ink.withAlphaComponent(pressed ? 0.08 : active ? 0.04 : 0)
        case .quiet:
            fill = SketchPalette.yellow.withAlphaComponent(pressed ? 0.2 : selected ? 0.14 : active ? 0.09 : 0)
        }
        MinimalSurface.draw(in: bounds, fill: fill,
            border: style == .quiet || style == .icon ? nil : SketchPalette.line.withAlphaComponent(isEnabled ? 1 : 0.4))
        super.draw(dirtyRect)
        MinimalSurface.drawFocus(for: self)
    }

    private func updateTint() {
        contentTintColor = !isEnabled ? .disabledControlTextColor : SketchPalette.ink
        needsDisplay = true
    }
}

/// A compact switch with the native NSButton switch state, action and checked accessibility value.
@MainActor
final class MinimalToggle: MinimalButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.switch)
        font = SketchPalette.heading(15)
    }
    required init?(coder: NSCoder) { nil }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        return NSSize(width: title.isEmpty ? 34 : 44 + ceil(width), height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        let on = state != .off
        let pressed = isEnabled && cell?.isHighlighted == true
        let track = NSRect(x: 1, y: (bounds.height - 18) / 2, width: 32, height: 18)
        let fill: NSColor = on && isEnabled ? SketchPalette.green.withAlphaComponent(0.66) : SketchPalette.line.withAlphaComponent(isEnabled ? 0.12 : 0.05)
        let path = NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9)
        fill.withAlphaComponent(pressed && on ? 0.78 : fill.alphaComponent).setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(isEnabled && hovered && window?.isKeyWindow == true ? 0.30 : 0.14).setStroke()
        SketchPencil.stroke(path, color: SketchPalette.line, width: 0.85)
        let knobColor: NSColor = !isEnabled ? .disabledControlTextColor : on ? SketchPalette.paper : SketchPalette.muted
        knobColor.setFill()
        if state == .mixed {
            NSBezierPath(roundedRect: NSRect(x: track.midX - 5, y: track.midY - 1, width: 10, height: 2), xRadius: 1, yRadius: 1).fill()
        } else {
            NSBezierPath(ovalIn: NSRect(x: track.minX + (on ? 17 : 3), y: track.minY + 3, width: 12, height: 12)).fill()
        }
        if !title.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor, .paragraphStyle: paragraph]
            let height = (title as NSString).size(withAttributes: attributes).height
            (title as NSString).draw(in: NSRect(x: 42, y: (bounds.height - height) / 2, width: max(0, bounds.width - 44), height: height),
                withAttributes: attributes)
        }
        MinimalSurface.drawFocus(for: self)
    }
}

/// Retain the item model for existing settings; presentation is a custom paper list.
@MainActor
final class MinimalPopUpButton: NSPopUpButton {
    private var dropdown: SketchDropdown?
    override func mouseDown(with event:NSEvent) { showChoices() }
    override func performClick(_ sender:Any?) { showChoices() }
    override func accessibilityPerformPress()->Bool {
        guard isEnabled,!isHiddenOrHasHiddenAncestor,window != nil else { return false }
        showChoices(); return true
    }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { isEnabled }
    override func keyDown(with event:NSEvent) {
        if [36,49,125,126].contains(event.keyCode) { showChoices() } else if event.keyCode == 53 { dropdown?.dismiss() } else if event.keyCode == 48 { window?.selectNextKeyView(self) } else if event.characters?.isEmpty == false { showChoices() }
    }
    private func showChoices() {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, window != nil else { return }
        if let dropdown { dropdown.dismiss(); return }
        let items=itemArray.enumerated().filter { !$0.element.isSeparatorItem }.map { SketchDropdown.Item(title:$0.element.title,index:$0.offset,enabled:$0.element.isEnabled) }
        guard !items.isEmpty else { return }
        let dropdown=SketchDropdown(items:items,selected:indexOfSelectedItem,width:max(220,min(400,bounds.width)))
        dropdown.onChoose = { [weak self] index in
            guard let self, self.isEnabled, self.itemArray.indices.contains(index) else { return }
            self.selectItem(at:index); self.needsDisplay=true
            if let action=self.action { NSApp.sendAction(action,to:self.target,from:self) }
        }
        dropdown.onDismiss = { [weak self] in self?.dropdown=nil; self?.needsDisplay=true }
        self.dropdown=dropdown; dropdown.present(relativeTo:self)
    }

    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var focusObserver: MinimalFocusObserver?

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = SketchPalette.heading(15)
        contentTintColor = SketchPalette.ink
    }
    convenience init() { self.init(frame: .zero, pullsDown: false) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
    }
    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? SketchPalette.ink : .disabledControlTextColor; needsDisplay = true }
    }
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: max(44, native.width + 12), height: max(30, native.height))
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dropdown?.dismiss() }
        hovered = false
        focusObserver = window == nil ? nil : MinimalFocusObserver(view: self) { [weak self] in self?.hovered = false }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        MinimalSurface.draw(in:bounds,fill:SketchPalette.paper,border:SketchPalette.line.withAlphaComponent(isEnabled ? 0.8 : 0.35))
        let paragraph=NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let text=NSAttributedString(string:titleOfSelectedItem ?? "选择",attributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:isEnabled ? SketchPalette.ink : NSColor.disabledControlTextColor,.paragraphStyle:paragraph])
        text.draw(in:CGRect(x:10,y:(bounds.height-18)/2,width:max(0,bounds.width-34),height:18))
        let arrow=NSBezierPath(); arrow.move(to:CGPoint(x:bounds.width-23,y:bounds.midY-2)); arrow.line(to:CGPoint(x:bounds.width-18,y:bounds.midY+2)); arrow.line(to:CGPoint(x:bounds.width-13,y:bounds.midY-2))
        SketchPencil.stroke(arrow,color:SketchPalette.muted,width:1.3)
        MinimalSurface.drawFocus(for:self)
    }
}

@MainActor
private enum MinimalSurface {
    static func draw(in bounds: NSRect, fill: NSColor, border: NSColor?) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 2, bounds.height > 2 else { return }
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 7)
        SketchPalette.fill(path, color: fill)
        if let border { SketchPencil.stroke(path, color: border, width: 1.3) }
    }
    static func drawFocus(for view: NSView) {
        let bounds = view.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 2, bounds.height > 2 else { return }
        guard view.window?.isKeyWindow == true, view.window?.firstResponder === view,
              (view as? NSControl)?.isEnabled != false else { return }
        SketchPalette.yellow.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        SketchPencil.stroke(path, color: SketchPalette.yellow, width: 1.5)
    }
}

@MainActor
private final class MinimalFocusObserver {
    private var tokens: [NSObjectProtocol] = []

    init(view: NSView, clearHover: @escaping () -> Void) {
        guard let window = view.window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak view] _ in
                MainActor.assumeIsolated { clearHover(); view?.needsDisplay = true }
            })
        }
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Only exists while a dropdown is open. No menu tracking loop or idle listeners.
@MainActor final class SketchDropdown: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct Item { let title:String; let index:Int; var enabled=true }
    var onChoose:((Int)->Void)?
    var onDismiss:(()->Void)?
    private let items:[Item]
    private var rows:[Item]
    private let selected:Int
    let table=NSTableView()
    let search=SketchSearchField()
    let surface=SketchDropdownSurface()
    private var panel:SketchDropdownPanel?
    private var localMonitor:Any?, globalMonitor:Any?
    private var activeObserver:NSObjectProtocol?
    private var closeObserver:NSObjectProtocol?
    private var finished=false
    init(items:[Item],selected:Int,width:CGFloat) {
        self.items=items; rows=items; self.selected=selected
        super.init()
        let searchable=items.count>12
        let header:CGFloat=searchable ? 42 : 0
        let height=CGFloat(min(8,max(1,items.count)))*34+16+header
        surface.frame=CGRect(x:0,y:0,width:width,height:height)
        let scroll=NSScrollView(frame:CGRect(x:8,y:8,width:width-16,height:height-header-16))
        scroll.hasVerticalScroller=true; scroll.autohidesScrollers=true; scroll.drawsBackground=false
        table.addTableColumn(NSTableColumn(identifier:.init("choice"))); table.headerView=nil
        table.rowHeight=32; table.intercellSpacing=CGSize(width:0,height:2); table.backgroundColor = .clear
        table.dataSource=self; table.delegate=self; table.target=self; table.action=#selector(clicked)
        table.selectionHighlightStyle = .regular
        table.setAccessibilityLabel("选项列表")
        table.frame=CGRect(x:0,y:0,width:width-16,height:CGFloat(items.count)*34)
        table.autoresizingMask=[.width]
        table.tableColumns[0].width=width-20; scroll.documentView=table; surface.addSubview(scroll)
        if searchable {
            search.frame=CGRect(x:10,y:height-36,width:width-20,height:28)
            search.placeholderString="搜索选项"; search.delegate=self; search.sendsSearchStringImmediately=true
            surface.addSubview(search)
        }
        table.reloadData(); selectInitial()
    }
    func numberOfRows(in tableView:NSTableView)->Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let id=NSUserInterfaceItemIdentifier("choice-cell")
        let cell=(tableView.makeView(withIdentifier:id,owner:nil) as? NSTableCellView) ?? NSTableCellView()
        cell.identifier=id
        if cell.textField == nil {
            let field=NSTextField(labelWithString:""); field.font = .systemFont(ofSize:14); field.lineBreakMode = .byTruncatingTail
            field.autoresizingMask=[.width]; cell.addSubview(field); cell.textField=field
        }
        let item=rows[row]
        cell.textField?.frame=CGRect(x:10,y:7,width:tableView.bounds.width-20,height:20)
        cell.textField?.stringValue=(item.index == selected ? "✓  " : "    ")+item.title
        cell.textField?.textColor=item.enabled ? SketchPalette.ink : .disabledControlTextColor
        return cell
    }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {
        let view=SketchDropdownRow()
        view.onHover = { [weak self] in
            guard let self,self.rows.indices.contains(row),self.rows[row].enabled else { return }
            self.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        }
        return view
    }
    private func selectInitial() {
        let row=rows.firstIndex { $0.index == selected && $0.enabled } ?? rows.firstIndex { $0.enabled }
        if let row { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false); table.scrollRowToVisible(row) }
        else { table.deselectAll(nil) }
    }
    func controlTextDidChange(_ notification:Notification) {
        guard (search.currentEditor() as? NSTextView)?.hasMarkedText() != true else { return }
        let query=String(search.stringValue.prefix(128))
        rows=items.filter { query.isEmpty || $0.title.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) != nil }
        table.reloadData(); selectInitial()
    }
    func moveSelection(_ direction:Int) {
        guard !rows.isEmpty else { return }
        var candidate=table.selectedRow
        for _ in rows.indices {
            candidate=(candidate+direction+rows.count)%rows.count
            if rows[candidate].enabled { table.selectRowIndexes(IndexSet(integer:candidate),byExtendingSelection:false); table.scrollRowToVisible(candidate); return }
        }
    }
    func commitSelection() {
        let row=table.selectedRow
        guard rows.indices.contains(row),rows[row].enabled else { return }
        let index=rows[row].index, callback=onChoose
        dismiss(); callback?(index)
    }
    @objc private func clicked() { commitSelection() }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(-1)
        case #selector(NSResponder.insertNewline(_:)): commitSelection()
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }
    func present(relativeTo anchor:NSView) {
        guard let window=anchor.window else { return }
        let frame=window.convertToScreen(anchor.convert(anchor.bounds,to:nil))
        let visible=window.screen?.visibleFrame ?? frame
        let x=min(max(frame.minX,visible.minX+8),visible.maxX-surface.bounds.width-8)
        let below=frame.minY-surface.bounds.height-5
        let y=max(visible.minY+8,below < visible.minY ? frame.maxY+5 : below)
        let panel=SketchDropdownPanel(contentRect:CGRect(x:x,y:min(y,visible.maxY-surface.bounds.height-8),width:surface.bounds.width,height:surface.bounds.height),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque=false; panel.backgroundColor = .clear; panel.hasShadow=true; panel.isReleasedWhenClosed=false
        panel.level = .floating; panel.delegate=self; panel.contentView=surface; panel.onKey = { [weak self] code in
            switch code { case 125: self?.moveSelection(1); case 126: self?.moveSelection(-1); case 36: self?.commitSelection(); case 53: self?.dismiss(); default: break }
        }
        self.panel=panel
        closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(search.superview == nil ? surface : search)
        localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] event in
            if let self,event.window !== self.panel { self.dismiss() }; return event
        }
        globalMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown]) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        activeObserver=NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
    }
    func windowDidResignKey(_ notification:Notification) { dismiss() }
    func dismiss() {
        guard !finished else { return }; finished=true
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor=nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor=nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }; activeObserver=nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }; closeObserver=nil
        panel?.delegate=nil; panel?.onKey=nil; panel?.orderOut(nil); panel?.close(); panel=nil
        table.delegate=nil; table.dataSource=nil; search.delegate=nil
        onChoose=nil; let callback=onDismiss; onDismiss=nil; callback?()
    }
}
@MainActor final class SketchDropdownSurface:NSView {
    override var acceptsFirstResponder:Bool { true }
    override func keyDown(with event:NSEvent) { window?.keyDown(with:event) }
    override func draw(_ dirtyRect:NSRect) { MinimalSurface.draw(in:bounds,fill:SketchPalette.paper,border:SketchPalette.line) }
}
@MainActor private final class SketchDropdownPanel:NSPanel {
    var onKey:((UInt16)->Void)?
    override var canBecomeKey:Bool { true }
    override func keyDown(with event:NSEvent) { onKey?(event.keyCode) }
}

@MainActor private final class SketchDropdownRow:NSTableRowView {
    var onHover:(()->Void)?
    private var tracking:NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self)
        addTrackingArea(area); tracking=area
    }
    override func mouseEntered(with event:NSEvent) { onHover?() }
    override func drawSelection(in dirtyRect:NSRect) {
        let shape=SketchPencil.outline(in:bounds.insetBy(dx:1,dy:1),radius:5)
        SketchPalette.fill(shape,color:SketchPalette.yellow.withAlphaComponent(0.18))
        SketchPencil.stroke(shape,color:SketchPalette.yellow,width:0.9)
    }
}
