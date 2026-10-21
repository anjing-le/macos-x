import AppKit

/// The whole diagram is a real button. Artwork illustrates state; no static
/// screenshot pretends to enumerate the user's installed menu-bar applications.
@MainActor final class MenuBarChoice: MinimalButton {
    let collapsed: Bool
    init(collapsed: Bool) {
        self.collapsed = collapsed
        super.init(frame: .zero)
        title = ""; style = .quiet
        setAccessibilityLabel(collapsed ? "收起箭头左侧的图标" : "展开全部图标")
        toolTip = collapsed ? "点击收起左侧应用图标" : "点击恢复全部菜单栏图标"
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let outline = SketchPencil.outline(in: bounds.insetBy(dx: 2, dy: 2), radius: 12)
        SketchPalette.fill(outline, color: SketchPalette.paper)
        SketchPencil.stroke(outline, color: selected ? SketchPalette.blue : SketchPalette.line, width: selected ? 2 : 1)
        let bar = CGRect(x: 16, y: bounds.midY - 2, width: max(20, bounds.width - 32), height: 42)
        let shape = SketchPencil.outline(in: bar, radius: 7)
        SketchPalette.fill(shape, color: SketchPalette.blue.withAlphaComponent(0.08))
        SketchPencil.stroke(shape, color: SketchPalette.line, width: 1)
        let w = min(24, (bar.width - 20) / 7), start = bar.maxX - w * 6 - 6
        for index in 0..<6 {
            let hidden = collapsed && index < 3
            let alpha: CGFloat = hidden ? 0.12 : 0.85
            let color = [SketchPalette.purple, SketchPalette.coral, SketchPalette.green][index % 3]
            if index == 3 {
                let p = NSBezierPath(); let x = start + CGFloat(index) * w
                p.move(to: CGPoint(x: x + 6, y: bar.midY - 6)); p.line(to: CGPoint(x: x + (collapsed ? 12 : 0), y: bar.midY)); p.line(to: CGPoint(x: x + 6, y: bar.midY + 6))
                SketchPencil.stroke(p, color: SketchPalette.ink, width: 2)
            } else {
                let tile = SketchPencil.outline(in: CGRect(x: start + CGFloat(index) * w, y: bar.midY - 7, width: max(6, w - 7), height: 14), radius: 3)
                SketchPalette.fill(tile, color: color.withAlphaComponent(alpha * 0.7))
                SketchPencil.stroke(tile, color: SketchPalette.ink.withAlphaComponent(alpha), width: 1)
            }
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        ((collapsed ? "收起" : "展开") as NSString).draw(in: CGRect(x: 8, y: 18, width: bounds.width - 16, height: 24), withAttributes: [.font: SketchPalette.heading(18), .foregroundColor: SketchPalette.ink, .paragraphStyle: paragraph])
        if selected {
            ("✓" as NSString).draw(at: CGPoint(x: bounds.width - 30, y: bounds.height - 30), withAttributes: [.font: NSFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: SketchPalette.blue])
        }
        if window?.firstResponder === self {
            SketchPencil.stroke(SketchPencil.outline(in: bounds.insetBy(dx: 5, dy: 5), radius: 10), color: SketchPalette.blue, width: 1)
        }
    }
}

@MainActor final class MenuBarShelfDashboard: NSView {
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onAutoCollapse: ((Bool) -> Void)?
    let expanded = MenuBarChoice(collapsed: false)
    let collapsed = MenuBarChoice(collapsed: true)
    let automatic = MinimalToggle(title: "手动展开后 10 秒自动收起", target: nil, action: nil)
    private var compact = false
    private let heading = NSTextField(labelWithString: "把菜单栏留给常用图标")
    private let instruction = NSTextField(wrappingLabelWithString: "按住 ⌘，把不常用的图标拖到收纳箭头左侧。点击箭头即可展开或收起。")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: compact ? 540 : 400) }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 840, height: 400))
        heading.font = SketchPalette.heading(22); heading.textColor = SketchPalette.ink
        instruction.font = .systemFont(ofSize: 14); instruction.textColor = SketchPalette.ink
        status.font = .systemFont(ofSize: 13); status.textColor = SketchPalette.ink
        note.font = .systemFont(ofSize: 12); note.textColor = SketchPalette.muted
        expanded.target = self; expanded.action = #selector(showAll)
        collapsed.target = self; collapsed.action = #selector(hideLeft)
        automatic.target = self; automatic.action = #selector(autoChanged)
        [heading, instruction, expanded, collapsed, automatic, status, note].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showAll() { onExpand?() }
    @objc private func hideLeft() { onCollapse?() }
    @objc private func autoChanged() { onAutoCollapse?(automatic.state == .on) }
    func update(active: Bool, state: MenuBarShelfModule.State, auto: Bool, issue: String?, count: Int, native: Bool) {
        expanded.state = state == .expanded ? .on : .off
        collapsed.state = state == .collapsed ? .on : .off
        expanded.isEnabled = active; collapsed.isEnabled = active && state == .expanded
        automatic.isEnabled = active; automatic.state = auto ? .on : .off
        status.stringValue = issue ?? (!active ? "开启后，菜单栏会出现收纳箭头。" : state == .reading ? "正在读取图标位置，点击展开可取消…" : state == .collapsed ? (native ? "已收纳 \(count) 个应用的图标" : "已收起左侧图标") : "当前全部展开，可按住 ⌘ 调整分组。")
        status.textColor = issue == nil ? SketchPalette.muted : SketchPalette.ink
        note.stringValue = native ? "macOS 27 按应用收纳，同一应用的多个图标一起变化；系统图标保持显示。\n辅助功能仅用于按需读取位置。新应用启动、屏幕变化或关闭模块会恢复全部图标。" : "带刘海的屏幕可能无法展示全部图标。关闭模块会恢复全部图标。"
        expanded.needsDisplay = true; collapsed.needsDisplay = true
        needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) { SketchPalette.paper.setFill(); dirtyRect.fill() }
    override func layout() {
        super.layout()
        let width = max(220, bounds.width), stacked = width < 430
        if compact != stacked { compact = stacked; invalidateIntrinsicContentSize(); superview?.needsLayout = true }
        heading.frame = CGRect(x: 0, y: 4, width: width, height: 32)
        instruction.frame = CGRect(x: 0, y: 46, width: width, height: 48)
        let cardWidth = stacked ? width : (width - 16) / 2
        expanded.frame = CGRect(x: 0, y: 104, width: cardWidth, height: 128)
        collapsed.frame = CGRect(x: stacked ? 0 : cardWidth + 16, y: stacked ? 244 : 104, width: cardWidth, height: 128)
        let bottom: CGFloat = stacked ? 384 : 244
        automatic.frame = CGRect(x: 0, y: bottom, width: width, height: 30)
        status.frame = CGRect(x: 0, y: bottom + 42, width: width, height: 44)
        note.frame = CGRect(x: 0, y: bottom + 92, width: width, height: 60)
    }
}
