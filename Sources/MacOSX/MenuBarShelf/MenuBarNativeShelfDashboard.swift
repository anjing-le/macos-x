import AppKit

/// Configuration contains application choices, never interactive pictures of
/// other apps' status items. Real controls stay in the system menu bar.
@MainActor final class MenuBarNativeShelfDashboard: NSView {
    var onCollect: ((String, Bool) -> Void)?
    var onRead: (() -> Void)?
    var onShow: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onAccess: (() -> Void)?
    private let heading = NSTextField(wrappingLabelWithString: "收起来，需要时原样展开")
    private let explanation = NSTextField(wrappingLabelWithString: "悬停顶部苹果展开原生菜单栏，直接操作原图标。")
    private let note = NSTextField(wrappingLabelWithString: "实时状态与单击、双击、右键由原应用处理。菜单使用中保持展开；无法确认关闭时，可按 Esc 后移开鼠标。")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let read = MinimalButton(title: "读取应用", target: nil, action: nil)
    private let show = MinimalButton(title: "全部显示", target: nil, action: nil)
    private let collapse = MinimalButton(title: "收起", target: nil, action: nil)
    private let access = MinimalButton(title: "授权辅助功能", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let list = NativeMenuBarChoiceList()
    private var enabled = false
    private var reading = false
    private var items: [NativeMenuBarChoice] = []
    private var narrow = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: narrow ? 560 : 450) }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 840, height: 450))
        heading.font = SketchPalette.heading(23); heading.textColor = SketchPalette.ink
        for label in [explanation, note, status] { label.font = .systemFont(ofSize: 13); label.textColor = SketchPalette.muted }
        read.target = self; read.action = #selector(readItems)
        show.target = self; show.action = #selector(showItems)
        collapse.target = self; collapse.action = #selector(collapseItems)
        access.target = self; access.action = #selector(requestAccess)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = list
        [heading, explanation, read, show, collapse, access, scroll, status, note].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func readItems() { onRead?() }
    @objc private func showItems() { onShow?() }
    @objc private func collapseItems() { onCollapse?() }
    @objc private func requestAccess() { onAccess?() }
    func update(active: Bool, hidden: Bool, busy: Bool, reading: Bool, issue: String?, choices: [NativeMenuBarChoice], permitted: Bool) {
        enabled = active; self.reading = reading
        read.isEnabled = active && !reading; show.isEnabled = active
        collapse.isEnabled = active && !busy && choices.contains(where: \.collected)
        access.isHidden = permitted; access.isEnabled = active
        if choices.map({ "\($0.bundle)|\($0.collected)|\($0.running)|\($0.name)" }) != items.map({ "\($0.bundle)|\($0.collected)|\($0.running)|\($0.name)" }) {
            items = choices; list.setItems(choices, active: active && !reading) { [weak self] in self?.onCollect?($0, $1) }
        } else { list.setEnabled(active && !reading) }
        status.stringValue = issue ?? (!active ? "开启后可从顶部苹果展开。" : reading ? "正在读取菜单栏应用…" : busy ? "正在收纳…" : hidden ? "已收起 · 悬停苹果原样展开" : "原生图标已展开")
        needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) { SketchPalette.paper.setFill(); dirtyRect.fill() }
    override func layout() {
        super.layout()
        let width = max(220, bounds.width), compact = width < 500
        if narrow != compact { narrow = compact; invalidateIntrinsicContentSize() }
        heading.frame = CGRect(x: 0, y: 4, width: width, height: compact ? 62 : 32)
        explanation.frame = CGRect(x: 0, y: compact ? 70 : 44, width: width, height: compact ? 42 : 24)
        let top: CGFloat = compact ? 122 : 82
        read.frame = CGRect(x: 0, y: top, width: 96, height: 30)
        show.frame = CGRect(x: compact ? 106 : 108, y: top, width: 96, height: 30)
        collapse.frame = CGRect(x: compact ? 0 : 216, y: compact ? top + 40 : top, width: 72, height: 30)
        access.frame = CGRect(x: compact ? 82 : 300, y: compact ? top + 40 : top, width: 120, height: 30)
        let start = compact ? top + 82 : top + 42
        let bottom = max(start + 100, bounds.height - (compact ? 130 : 88))
        scroll.frame = CGRect(x: 0, y: start, width: width, height: bottom - start)
        list.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, list.contentHeight))
        status.frame = CGRect(x: 0, y: bottom + 10, width: width, height: 28)
        note.frame = CGRect(x: 0, y: bottom + 42, width: width, height: compact ? 86 : 44)
    }
}

@MainActor private final class NativeMenuBarChoiceList: NSView {
    private var rows: [NativeMenuBarChoiceRow] = []
    private let empty = NSTextField(wrappingLabelWithString: "点“读取应用”选择收纳名单；这里管理名单，实际操作仍在顶部原生图标上。")
    override var isFlipped: Bool { true }
    var contentHeight: CGFloat { max(80, CGFloat(rows.count) * 48) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        empty.font = .systemFont(ofSize: 13); empty.textColor = SketchPalette.muted; addSubview(empty)
    }
    required init?(coder: NSCoder) { nil }
    func setItems(_ items: [NativeMenuBarChoice], active: Bool, onChange: @escaping (String, Bool) -> Void) {
        rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
        // Collected choices first; macOS remains responsible for native order.
        for item in items.filter(\.collected) + items.filter({ !$0.collected }) {
            let row = NativeMenuBarChoiceRow(item, onChange: onChange)
            row.button.isEnabled = active; rows.append(row); addSubview(row)
        }
        empty.isHidden = !rows.isEmpty; needsLayout = true; superview?.superview?.needsLayout = true
    }
    func setEnabled(_ enabled: Bool) { rows.forEach { $0.button.isEnabled = enabled } }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = CGRect(x: 0, y: CGFloat(index) * 48, width: bounds.width, height: 48) }
        empty.frame = CGRect(x: 8, y: 14, width: max(20, bounds.width - 16), height: 62)
    }
}

@MainActor private final class NativeMenuBarChoiceRow: NSView {
    let button: MinimalButton
    private let name: NSTextField
    private let item: NativeMenuBarChoice
    private let onChange: (String, Bool) -> Void
    override var isFlipped: Bool { true }
    init(_ item: NativeMenuBarChoice, onChange: @escaping (String, Bool) -> Void) {
        self.item = item; self.onChange = onChange
        name = NSTextField(labelWithString: item.name + (item.running ? "" : " · 未运行"))
        button = MinimalButton(title: item.collected ? "移出收纳" : "收纳", target: nil, action: nil)
        super.init(frame: .zero)
        name.font = .systemFont(ofSize: 14); name.textColor = SketchPalette.ink; name.lineBreakMode = .byTruncatingTail
        name.toolTip = item.name; button.toolTip = item.collected ? "恢复在菜单栏常驻显示" : "按应用收纳；悬停苹果展开后直接操作原图标"
        button.setAccessibilityLabel("\(item.collected ? "移出收纳" : "收纳") \(item.name)")
        button.target = self; button.action = #selector(change)
        addSubview(name); addSubview(button)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func change() { onChange(item.bundle, !item.collected) }
    override func layout() {
        super.layout()
        name.frame = CGRect(x: 8, y: 12, width: max(20, bounds.width - 108), height: 24)
        button.frame = CGRect(x: max(0, bounds.width - 92), y: 9, width: 88, height: 30)
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(); path.move(to: CGPoint(x: 8, y: bounds.maxY - 1)); path.line(to: CGPoint(x: bounds.maxX - 4, y: bounds.maxY - 1))
        SketchPencil.stroke(path, color: SketchPalette.line.withAlphaComponent(0.2), width: 0.7)
    }
}
