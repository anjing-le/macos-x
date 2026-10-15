import AppKit
import MacOSXCore

/// ImageGen's approved composition, rendered with real accessible native
/// controls. No example apps, counts, status badges or text are baked into art.
@MainActor
final class ShortcutRadarDashboard: NSView, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onScan: ((RadarChord?) -> Void)?
    var onCaptureChanged: ((Bool) -> Void)?
    var onRequestPermission: (() -> Void)?
    var onLeave: (() -> Void)?
    private let search = NSTextField()
    private let magnifier = NSImageView()
    private let clear = MinimalButton(title: "×", target: nil, action: nil, style: .icon)
    private let capture = MinimalButton(title: "⌨", target: nil, action: nil, style: .icon)
    private let scan = MinimalButton(title: "检测一次", target: nil, action: nil, style: .standard)
    private let permission = MinimalButton(title: "允许辅助功能", target: nil, action: nil, style: .quiet)
    private let coverage = NSTextField(labelWithString: "点击检测，读取已知组合键")
    private let heading = NSTextField(labelWithString: "组合键复用")
    private let detailHeading = NSTextField(labelWithString: "应用与用途")
    private let keys = RadarKeycapView()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "点击“检测一次”，或搜索组合键与用途")
    private let footer = NSTextField(labelWithString: "本机按需读取 · 不记录按键历史")
    private let hint = NSTextField(labelWithString: "↑↓ 选择 · Enter 查看")
    private var filters: [MinimalButton] = []
    private let ranking = RadarTableView()
    private let uses = RadarTableView()
    private let rankingScroll = NSScrollView()
    private let usesScroll = NSScrollView()
    private var groups: [RadarGroup] = []
    private var entries: [RadarUse] = []
    private var preparedGroups: [RadarGroup] = []
    private var probe: RadarProbe?
    private var icons: [String: NSImage] = [:]
    private var selected: RadarGroup?
    private var filter: RadarIndex.Filter = .all
    private var busy = false
    private var enabled = false
    private var measuredHeight: CGFloat = 470
    private var capturing = false
    private var captureLabels: [UInt16: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private var moduleControls: NSView?
    private var searchBox = CGRect.zero
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: measuredHeight) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        search.placeholderString = "按组合键，或搜索用途"
        search.font = .systemFont(ofSize: 15); search.delegate = self
        search.isBezeled = false; search.isBordered = false; search.drawsBackground = false
        search.focusRingType = .none; search.textColor = SketchPalette.ink
        search.isEditable = true; search.isSelectable = true
        search.cell?.usesSingleLineMode = true; search.cell?.wraps = false; search.cell?.isScrollable = true
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        magnifier.contentTintColor = SketchPalette.muted; magnifier.setAccessibilityElement(false)
        clear.target = self; clear.action = #selector(clearSearch); clear.setAccessibilityLabel("清空搜索")
        search.setAccessibilityLabel("搜索组合键、应用或用途")
        capture.target = self; capture.action = #selector(beginCapture)
        configureCaptureIcon()
        capture.setAccessibilityLabel("按下组合键搜索")
        capture.toolTip = "点击后按组合键；Esc 取消。第三方全局快捷键仍可能响应。"
        scan.target = self; scan.action = #selector(refreshScan)
        permission.target = self; permission.action = #selector(allowPermission)
        scan.font = SketchPalette.heading(16)
        for (index, title) in ["全部", "全局", "应用内"].enumerated() {
            let button = MinimalButton(title: title, target: self, action: #selector(changeFilter(_:)), style: .quiet)
            button.tag = index; button.font = SketchPalette.heading(14)
            button.setAccessibilityLabel("筛选\(title)")
            filters.append(button); addSubview(button)
        }
        for field in [heading, detailHeading] { field.font = SketchPalette.heading(18); field.textColor = SketchPalette.ink }
        for field in [coverage, footer, hint] {
            field.font = .systemFont(ofSize: 12); field.textColor = SketchPalette.muted
            field.lineBreakMode = .byTruncatingTail
        }
        coverage.toolTip = "只读取运行中应用公开的菜单；有界检测可能得到部分结果，不遍历磁盘配置。"
        hint.alignment = .right
        heading.toolTip = "按已知用途数量降序排列；用途多不等于实际冲突多。"
        summary.font = .systemFont(ofSize: 12, weight: .medium); summary.maximumNumberOfLines = 2
        empty.font = .systemFont(ofSize: 14); empty.textColor = SketchPalette.muted
        empty.maximumNumberOfLines = 3; empty.alignment = .center
        for view in [search, magnifier, clear, capture, scan, permission, coverage, heading, detailHeading, keys,
                     summary, empty, footer, hint, rankingScroll, usesScroll] { addSubview(view) }
        configureTable(ranking, scroll: rankingScroll, rowHeight: 46, label: "组合键复用排行")
        configureTable(uses, scroll: usesScroll, rowHeight: 50, label: "组合键的应用与用途")
        filters[0].state = .on
        update(snapshot: nil, icons: [:], enabled: false, busy: false)
    }
    required init?(coder: NSCoder) { nil }

    /// Reuse the real module switch in the toolbar instead of consuming a separate row.
    func installModuleControls(_ controls: NSView) {
        moduleControls?.removeFromSuperview()
        moduleControls = controls; addSubview(controls); needsLayout = true
    }

    private func configureTable(_ table: NSTableView, scroll: NSScrollView, rowHeight: CGFloat, label: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.resizingMask = .autoresizingMask; table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear
        table.rowHeight = rowHeight; table.intercellSpacing = CGSize(width: 0, height: 3)
        table.style = .plain; table.focusRingType = .none; table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false; table.allowsMultipleSelection = false
        table.delegate = self; table.dataSource = self
        table.setAccessibilityLabel(label)
        scroll.documentView = table; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
    }

    func update(snapshot: RadarSnapshot?, icons: [String: NSImage], enabled: Bool, busy: Bool) {
        self.enabled = enabled; self.busy = busy; self.icons = icons
        let next = snapshot?.uses ?? []
        if entries != next { entries = next; preparedGroups = RadarIndex.groups(entries) }
        probe = snapshot?.probe
        search.isEnabled = enabled; capture.isEnabled = enabled && !busy; scan.isEnabled = enabled
        clear.isEnabled = enabled
        scan.title = busy ? "取消检测" : "检测一次"
        filters.forEach { $0.isEnabled = enabled }
        permission.isHidden = !enabled || snapshot == nil || snapshot?.accessibility == true
        if !enabled {
            endCapture(); coverage.stringValue = "已关闭 · 开启后可按需检测"
            footer.stringValue = "开启后按需检测 · 不记录按键历史"
        }
        else if busy { coverage.stringValue = "正在检测 · 可随时取消" }
        else if let snapshot {
            let completed = snapshot.coverage.filter { $0.status == .read }.count
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            coverage.stringValue = "\(snapshot.accessibility ? "公开菜单已读 \(completed)/\(snapshot.totalApps) 个应用" : "部分结果 · 未读取应用菜单") · \(formatter.string(from: snapshot.date))"
            var details = snapshot.coverage.map { "\($0.app.name)：\($0.status == .read ? "已读取公开菜单" : $0.status == .limited ? "部分读取" : "菜单不可用")" }
            if !snapshot.systemAvailable { details.append("系统快捷键登记读取失败") }
            if snapshot.truncated { details.append("已到检测时间、节点或数量上限；未读取项不表示没有快捷键") }
            coverage.toolTip = details.joined(separator: "\n")
            footer.stringValue = !snapshot.systemAvailable ? "系统登记读取失败 · 仅展示已读取来源"
                : snapshot.truncated ? "部分结果 · 将鼠标移到覆盖范围查看详情" : "本机按需读取 · 不记录按键历史"
        } else {
            coverage.stringValue = "运行中的应用 · 按需检测"
            footer.stringValue = "本机按需读取 · 不记录按键历史"
        }
        reload()
    }

    func controlTextDidChange(_ obj: Notification) { reload() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { moveSelection(1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { moveSelection(-1); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if selected != nil { window?.makeFirstResponder(uses) }; return true
        }
        return false
    }
    private func reload() {
        let old = selected?.chord
        clear.isHidden = search.stringValue.isEmpty
        groups = RadarIndex.search(preparedGroups, query: search.stringValue, filter: filter)
        if groups.isEmpty, filter != .application, let chord = RadarChord.parse(search.stringValue), probe?.chord == chord {
            groups = [.init(chord: chord, uses: [])]
        }
        selected = nil
        ranking.reloadData()
        if !groups.isEmpty {
            let row = old.flatMap { chord in groups.firstIndex { $0.chord == chord } } ?? 0
            ranking.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            showSelection(row)
        } else { showSelection(-1) }
        empty.stringValue = !enabled ? "模块已关闭" : busy && entries.isEmpty ? "正在读取已知组合键…"
            : search.stringValue.isEmpty ? "点击“检测一次”，读取本机已知组合键" : "未发现匹配用途\n不代表这个组合键未被占用"
        empty.isHidden = !groups.isEmpty
        needsLayout = true; needsDisplay = true
    }
    private func showSelection(_ row: Int) {
        selected = groups.indices.contains(row) ? groups[row] : nil
        keys.chord = selected?.chord
        keys.toolTip = selected?.chord.longName
        summary.stringValue = selected?.explanation ?? "选择左侧组合键，查看应用与用途"
        summary.textColor = selected?.isPotentialConflict == true ? SketchPalette.coral : SketchPalette.muted
        if let selected, let probe, selected.chord == probe.chord {
            summary.stringValue = probe.message
            if probe.result == .occupied { summary.textColor = SketchPalette.coral }
        }
        summary.toolTip = summary.stringValue
        uses.reloadData()
        usesScroll.contentView.scroll(to: .zero)
        needsDisplay = true
    }
    private func moveSelection(_ delta: Int) {
        guard !groups.isEmpty else { return }
        let row = max(0, min(groups.count - 1, ranking.selectedRow + delta))
        ranking.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        ranking.scrollRowToVisible(row); showSelection(row)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === ranking ? groups.count : selected?.uses.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === ranking { showSelection(ranking.selectedRow) }
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RadarTableRow(ranking: tableView === ranking)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier(tableView === ranking ? "rank" : "use")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? RadarTableCell ?? RadarTableCell(frame: .zero)
        cell.identifier = identifier
        if tableView === ranking, groups.indices.contains(row) {
            let group = groups[row]
            cell.group = group; cell.use = nil; cell.icon = nil
            cell.maximumCount = groups.first?.uses.count ?? 1
            cell.setAccessibilityLabel(group.uses.isEmpty ? "\(group.chord.longName)，归属未知。\(probe?.message ?? group.explanation)"
                : "\(group.chord.longName)，\(group.uses.count) 处使用。\(group.explanation)")
        } else if let selected, selected.uses.indices.contains(row) {
            let entry = selected.uses[row]
            cell.group = nil; cell.use = entry; cell.icon = icons[entry.appID]
            cell.toolTip = entry.appName + "\n" + entry.path + "\n" + entry.sourceLabel
            cell.setAccessibilityLabel("\(entry.appName)，\(entry.action)。\(entry.sourceLabel)。\(entry.path)")
        }
        cell.needsDisplay = true
        return cell
    }

    @objc private func refreshScan() { endCapture(); onScan?(RadarChord.parse(search.stringValue)) }
    @objc private func clearSearch() { search.stringValue = ""; reload(); window?.makeFirstResponder(search) }
    @objc private func allowPermission() { endCapture(); onRequestPermission?() }
    @objc private func changeFilter(_ sender: NSButton) {
        guard let next = RadarIndex.Filter(rawValue: sender.tag), next != filter else { return }
        filter = next
        for (i, button) in filters.enumerated() { button.state = i == next.rawValue ? .on : .off }
        reload()
    }
    @objc private func beginCapture() {
        guard enabled, !busy, window != nil else { return }
        if capturing { endCapture(); return }
        capturing = true; captureLabels = RadarNativeSeed.keyLabels()
        capture.image = nil; capture.imagePosition = .noImage; capture.title = "Esc"
        coverage.stringValue = "按下组合键搜索 · Esc 取消"
        onCaptureChanged?(true); window?.makeFirstResponder(self)
    }
    func endCapture() {
        guard capturing else { return }
        capturing = false; captureLabels.removeAll(); configureCaptureIcon()
        coverage.stringValue = "运行中的应用 · 按需检测"
        onCaptureChanged?(false)
    }
    private func configureCaptureIcon() {
        capture.title = ""; capture.imagePosition = .imageOnly
        capture.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "按组合键搜索")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
    }
    override func keyDown(with event: NSEvent) {
        guard capturing else {
            if event.keyCode == 125 { moveSelection(1); return }
            if event.keyCode == 126 { moveSelection(-1); return }
            super.keyDown(with: event); return
        }
        if event.keyCode == 53 { endCapture(); return }
        let flags = event.modifierFlags
        let modifiers: UInt8 = (flags.contains(.control) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.shift) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
            | (flags.contains(.function) ? 16 : 0)
        guard let key = captureLabels[event.keyCode] else { return }
        let functionKey = key.first == "F" && Int(key.dropFirst()).map { (1...20).contains($0) } == true
        guard modifiers != 0 || functionKey else { NSSound.beep(); return }
        let chord = RadarChord(key: key, modifiers: modifiers)
        endCapture(); search.stringValue = chord.displayName; reload()
        window?.makeFirstResponder(search)
    }
    override func resignFirstResponder() -> Bool { endCapture(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        guard let window else { endCapture(); onLeave?(); return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notice in
                MainActor.assumeIsolated {
                    self?.endCapture()
                    if notice.name == NSWindow.willCloseNotification { self?.onLeave?() }
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    override func layout() {
        super.layout()
        let w = max(220, bounds.width), compact = w < 650
        let controlsWidth: CGFloat = moduleControls == nil ? 0 : 80
        moduleControls?.frame = CGRect(x: 0, y: 3, width: 68, height: 30)
        let searchX: CGFloat = w < 360 ? 0 : controlsWidth
        let searchY: CGFloat = w < 360 && moduleControls != nil ? 40 : 0
        searchBox = CGRect(x: searchX, y: searchY, width: w - searchX - 106, height: 36)
        magnifier.frame = CGRect(x: searchX + 9, y: searchY + 9, width: 18, height: 18)
        search.frame = CGRect(x: searchX + 33, y: searchY + 8, width: max(1, searchBox.width - 103), height: 21)
        clear.frame = CGRect(x: searchBox.maxX - 66, y: searchY + 4, width: 26, height: 28)
        capture.frame = CGRect(x: searchBox.maxX - 38, y: searchY + 2, width: 34, height: 32)
        scan.frame = CGRect(x: w - 96, y: searchY, width: 96, height: 36)
        let statusY = searchY + 42
        coverage.frame = CGRect(x: 2, y: statusY, width: w - (permission.isHidden ? 2 : 132), height: 18)
        permission.frame = CGRect(x: w - 126, y: statusY - 4, width: 126, height: 26)
        let top = statusY + 32
        let left: CGFloat = compact ? w : max(300, floor(w * 0.42))
        heading.frame = CGRect(x: 0, y: top, width: max(1, left - 194), height: 24)
        // Compact columns keep the three scope choices together on a second line.
        let stackedFilters = compact && w < 360
        let filterY = top + (stackedFilters ? 30 : 0)
        let filterWidth: CGFloat = stackedFilters ? (left - 12) / 3 : 58
        for (i, button) in filters.enumerated() {
            button.frame = CGRect(x: stackedFilters ? CGFloat(i) * (filterWidth + 6) : left - 186 + CGFloat(i) * 64,
                                  y: filterY, width: filterWidth, height: 26)
        }
        heading.frame.size.width = stackedFilters ? left : max(1, left - 194)
        let listY = filterY + 36
        rankingScroll.frame = CGRect(x: 0, y: listY, width: left, height: compact ? 245 : 378)
        empty.frame = rankingScroll.frame.insetBy(dx: 14, dy: 48)
        let x: CGFloat = compact ? 0 : left + 24
        let detailY = compact ? rankingScroll.frame.maxY + 18 : top
        let right = w - x
        detailHeading.frame = CGRect(x: x, y: detailY + 3, width: 108, height: 24)
        keys.frame = CGRect(x: x + 112, y: detailY - 1, width: max(1, right - 114), height: 30)
        summary.frame = CGRect(x: x + 2, y: detailY + 36, width: right - 4, height: 30)
        usesScroll.frame = CGRect(x: x, y: detailY + 70, width: right,
                                 height: compact ? 265 : rankingScroll.frame.maxY - detailY - 70)
        let bottom = max(rankingScroll.frame.maxY, usesScroll.frame.maxY) + 10
        footer.frame = CGRect(x: 0, y: bottom, width: compact ? w : w - 174, height: 18)
        footer.toolTip = "后台自行监听的热键可能不可见；未发现不代表未占用。\n" + footer.stringValue
        hint.isHidden = compact
        hint.frame = CGRect(x: w - 174, y: bottom, width: 174, height: 18)
        for (table, scroll) in [(ranking, rankingScroll), (uses, usesScroll)] {
            table.tableColumns.first?.width = max(1, scroll.contentSize.width)
            table.sizeLastColumnToFit()
        }
        let height = bottom + 24
        if height != measuredHeight { measuredHeight = height; invalidateIntrinsicContentSize(); superview?.needsLayout = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        let outline = SketchPencil.outline(in: searchBox.insetBy(dx: 1.5, dy: 1.5), radius: 9)
        SketchPalette.paper.setFill(); outline.fill()
        SketchPencil.stroke(outline, color: search.currentEditor() == nil ? SketchPalette.line : SketchPalette.yellow, width: 1)
        guard bounds.width >= 650 else { return }
        let x = rankingScroll.frame.maxX + 12
        let path = NSBezierPath(); path.move(to: CGPoint(x: x, y: heading.frame.minY)); path.line(to: CGPoint(x: x, y: rankingScroll.frame.maxY))
        SketchPencil.stroke(path, color: SketchPalette.line.withAlphaComponent(0.3), width: 0.8)
    }
}

@MainActor
private final class RadarTableView: NSTableView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard bounds.contains(point), row >= 0 else { return }
        window?.makeFirstResponder(self)
        // Read-only, single-selection rows are selected on the first mouseDown,
        // including their padding and an inactive window's first click.
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

@MainActor
private final class RadarKeycapView: NSView {
    var chord: RadarChord? { didSet { needsDisplay = true; setAccessibilityLabel(chord?.longName ?? "尚未选择组合键") } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityRole(.staticText) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let chord { RadarDrawing.keycaps(chord, in: bounds, fontSize: 18) }
    }
}

@MainActor
private enum RadarDrawing {
    static func text(_ text: String, in rect: CGRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color, .paragraphStyle: paragraph])
    }
    static func keycaps(_ chord: RadarChord, in rect: CGRect, fontSize: CGFloat) {
        guard rect.width > 0 else { return }
        let caps = chord.keycaps, gap: CGFloat = 7
        let desired = caps.map { max(fontSize * 1.65, CGFloat($0.count) * fontSize * 0.68 + 18) }
        let total = desired.reduce(0, +) + gap * CGFloat(max(0, caps.count - 1))
        let scale = min(1, rect.width / total)
        var x = rect.minX
        for (index, cap) in caps.enumerated() {
            let width = desired[index] * scale
            let area = CGRect(x: x, y: rect.minY + 1, width: width, height: rect.height - 3)
            let outline = SketchPencil.outline(in: area.insetBy(dx: 1, dy: 1), radius: 5)
            SketchPalette.paper.setFill(); outline.fill()
            SketchPencil.stroke(outline, color: SketchPalette.line.withAlphaComponent(0.8), width: 1.4)
            let font = NSFont.systemFont(ofSize: max(10, fontSize * scale), weight: .medium)
            let size = (cap as NSString).size(withAttributes: [.font: font])
            (cap as NSString).draw(at: CGPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2),
                                  withAttributes: [.font: font, .foregroundColor: SketchPalette.ink])
            x += width + gap * scale
        }
    }
}

@MainActor
private final class RadarTableRow: NSTableRowView {
    let ranking: Bool
    init(ranking: Bool) { self.ranking = ranking; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func drawBackground(in dirtyRect: NSRect) {
        guard ranking else { return }
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 2, dy: 1), radius: 9)
        SketchPencil.stroke(path, color: SketchPalette.line.withAlphaComponent(0.35), width: 1)
    }
    override func drawSelection(in dirtyRect: NSRect) {
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 2, dy: 1), radius: 9)
        SketchPalette.fill(path, color: SketchPalette.blue.withAlphaComponent(0.13))
        SketchPencil.stroke(path, color: SketchPalette.blue, width: 1.6)
    }
}

@MainActor
private final class RadarTableCell: NSTableCellView {
    var group: RadarGroup?
    var use: RadarUse?
    var icon: NSImage?
    var maximumCount = 1
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        if let group {
            let countWidth: CGFloat = 82, keyWidth = max(50, bounds.width - countWidth - 22)
            RadarDrawing.keycaps(group.chord, in: CGRect(x: 10, y: 7, width: keyWidth, height: 30), fontSize: 16)
            let x = bounds.width - countWidth
            RadarDrawing.text(group.uses.isEmpty ? "归属未知" : "\(group.uses.count) 项用途", in: CGRect(x: x, y: 7, width: countWidth - 6, height: 20), size: 13, color: SketchPalette.ink, weight: .medium)
            let bar = CGRect(x: x, y: 31, width: countWidth - 12, height: 5)
            SketchPalette.line.withAlphaComponent(0.09).setFill(); NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
            var amount = bar; amount.size.width *= CGFloat(group.uses.count) / CGFloat(max(1, maximumCount))
            if amount.width > 0 {
                SketchPalette.fill(NSBezierPath(roundedRect: amount, xRadius: 4, yRadius: 4),
                    color: (group.isPotentialConflict ? SketchPalette.coral : group.hasGlobal ? SketchPalette.purple : SketchPalette.green).withAlphaComponent(0.65))
            }
        } else if let use {
            if let icon { icon.draw(in: CGRect(x: 7, y: 11, width: 26, height: 26), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }
            else {
                let path = SketchPencil.outline(in: CGRect(x: 7, y: 11, width: 26, height: 26), radius: 7)
                SketchPalette.fill(path, color: (use.scope == .global ? SketchPalette.purple : SketchPalette.blue).withAlphaComponent(0.22))
                RadarDrawing.text(use.appName == "macOS" ? "⌘" : String(use.appName.prefix(1)), in: CGRect(x: 12, y: 12, width: 22, height: 23), size: 19, color: SketchPalette.ink)
            }
            RadarDrawing.text(use.appName, in: CGRect(x: 43, y: 5, width: max(30, bounds.width - 126), height: 19), size: 14, color: SketchPalette.ink, weight: .medium)
            RadarDrawing.text(use.action, in: CGRect(x: 43, y: 26, width: max(1, bounds.width - 50), height: 18), size: 12, color: SketchPalette.ink)
            let badge = CGRect(x: max(0, bounds.width - 78), y: 4, width: 72, height: 20)
            let shape = NSBezierPath(roundedRect: badge, xRadius: 10, yRadius: 10)
            SketchPalette.fill(shape, color: (use.isConfirmed ? SketchPalette.purple : SketchPalette.blue).withAlphaComponent(0.12))
            RadarDrawing.text(use.scope == .application ? "应用内" : use.isConfirmed ? "已登记" : "待核对",
                in: badge.insetBy(dx: 12, dy: 3), size: 11, color: SketchPalette.ink)
            let line = NSBezierPath(); line.move(to: CGPoint(x: 3, y: bounds.maxY - 1)); line.line(to: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 1))
            SketchPencil.stroke(line, color: SketchPalette.line.withAlphaComponent(0.25), width: 0.7)
        }
    }
}
