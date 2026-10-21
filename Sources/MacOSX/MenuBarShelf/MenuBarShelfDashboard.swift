import AppKit

/// This page uses the same actionable drawer as the status-item entry, rather
/// than displaying two similar pictures for transient expanded/hidden states.
@MainActor final class MenuBarShelfDashboard: NSView {
    var onExpand: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onAutoCollapse: ((Bool) -> Void)?
    var onRefresh: (() -> Void)?
    var onAdd: ((String) -> Void)?
    var onMove: ((String, Int) -> Void)?
    var onRestore: ((String, CGPoint) -> Void)?
    var onOpen: ((String) -> Void)?
    var onPreview: (() -> Void)?
    let drawer = MenuBarDrawerView(frame: .zero)
    let visible = MenuBarDrawerView(frame: .zero)
    let expanded = MinimalButton(title: "全部显示", target: nil, action: nil)
    let collapsed = MinimalButton(title: "收纳", target: nil, action: nil)
    let automatic = MinimalToggle(title: "展开后 10 秒自动收起", target: nil, action: nil)
    private let drawerScroll = NSScrollView()
    private let visibleScroll = NSScrollView()
    private let refresh = MinimalButton(title: "读取图标", target: nil, action: nil)
    private let preview = MinimalButton(title: "打开抽屉", target: nil, action: nil)
    private let heading = NSTextField(labelWithString: "苹果下面，放下不常用的图标")
    private let instruction = NSTextField(wrappingLabelWithString: "悬停苹果展开 · 按住 ⌘ 拖入收纳，拖出恢复 · 抽屉内左右换位置")
    private let drawerLabel = NSTextField(labelWithString: "收纳在抽屉")
    private let visibleLabel = NSTextField(labelWithString: "留在菜单栏")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private var native = true
    private var compact = false
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: compact ? 580 : 500) }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 840, height: 500))
        heading.font = SketchPalette.heading(23); heading.textColor = SketchPalette.ink
        instruction.font = .systemFont(ofSize: 13); instruction.textColor = SketchPalette.muted
        for label in [drawerLabel, visibleLabel] { label.font = SketchPalette.heading(17); label.textColor = SketchPalette.ink }
        status.font = .systemFont(ofSize: 12); status.textColor = SketchPalette.muted
        note.font = .systemFont(ofSize: 12); note.textColor = SketchPalette.muted
        expanded.target = self; expanded.action = #selector(showAll)
        collapsed.target = self; collapsed.action = #selector(hideChosen)
        refresh.target = self; refresh.action = #selector(read)
        preview.target = self; preview.action = #selector(openDrawer)
        automatic.target = self; automatic.action = #selector(autoChanged)
        drawer.onOpen = { [weak self] in self?.onOpen?($0) }
        drawer.onMove = { [weak self] in self?.onMove?($0, $1) }
        drawer.onRestore = { [weak self] in self?.onRestore?($0, $1) }
        // Visible icons are real choices: click to add, or Command-drag into
        // the upper drawer. No configuration opens another app's settings.
        visible.onOpen = { [weak self] in self?.onAdd?($0) }
        visible.onRestore = { [weak self] bundle, point in
            guard let self, let window = self.window else { return }
            let local = self.drawer.convert(window.convertPoint(fromScreen: point), from: nil)
            if self.drawer.bounds.contains(local) { self.onAdd?(bundle) }
        }
        for (scroll, document) in [(drawerScroll, drawer), (visibleScroll, visible)] {
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
            document.singleRow = true; scroll.documentView = document
        }
        [heading, instruction, drawerLabel, visibleLabel, drawerScroll, visibleScroll, expanded, collapsed, refresh, preview, automatic, status, note].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func showAll() { onExpand?() }
    @objc private func hideChosen() { onCollapse?() }
    @objc private func read() { onRefresh?() }
    @objc private func openDrawer() { onPreview?() }
    @objc private func autoChanged() { onAutoCollapse?(automatic.state == .on) }
    func setItems(drawer: [MenuDrawerItem], visible: [MenuDrawerItem]) {
        // Keep one compact row here. Every item remains reachable through the
        // horizontal scroll views; runtime drawer wraps all saved entries.
        self.drawer.items = drawer; self.visible.items = visible
        self.drawer.message = drawer.isEmpty ? "⌘ 拖入图标，收纳在这里" : "点击打开 · ⌘ 拖动排序，拖出恢复"
        self.visible.message = "点击收纳 · 或按住 ⌘ 拖到上方"
        needsLayout = true
    }
    func update(active: Bool, state: MenuBarShelfModule.State, auto: Bool, issue: String?, count: Int, native: Bool) {
        self.native = native
        expanded.isEnabled = active; collapsed.isEnabled = active && state != .reading
        refresh.isEnabled = active; preview.isEnabled = active && native
        automatic.isHidden = native; automatic.isEnabled = active; automatic.state = auto ? .on : .off
        status.stringValue = issue ?? (!active ? "开启模块后，从顶部苹果进入。" : state == .reading ? "正在更新收纳…" : native ? "图标按应用收纳 · 顺序自动保存" : "按住 ⌘ 将图标拖到收纳箭头左侧，再点击收纳。")
        note.stringValue = native ? "图标使用应用本身的图标。点击会临时恢复真实菜单栏并打开对应菜单；读取不到的应用保留显示。\n离开抽屉后自动收起；系统图标和苹果入口始终保留。" : "当前系统使用原生菜单栏分隔方式；抽屉拖入功能需要 macOS 27。"
        needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) { SketchPalette.paper.setFill(); dirtyRect.fill() }
    override func layout() {
        super.layout()
        let width = max(220, bounds.width), narrow = width < 520
        if compact != narrow { compact = narrow; invalidateIntrinsicContentSize(); superview?.needsLayout = true }
        heading.frame = CGRect(x: 0, y: 4, width: width, height: narrow ? 58 : 32)
        instruction.frame = CGRect(x: 0, y: narrow ? 66 : 46, width: width, height: 40)
        let top: CGFloat = narrow ? 116 : 86
        drawerLabel.frame = CGRect(x: 0, y: top, width: width - 110, height: 24)
        preview.frame = CGRect(x: width - 100, y: top - 2, width: 100, height: 28)
        drawerScroll.frame = CGRect(x: 0, y: top + 32, width: width, height: 112)
        visibleLabel.frame = CGRect(x: 0, y: top + 158, width: width - 110, height: 24)
        refresh.frame = CGRect(x: width - 100, y: top + 154, width: 100, height: 28)
        visibleScroll.frame = CGRect(x: 0, y: top + 190, width: width, height: 112)
        for (scroll, document) in [(drawerScroll, drawer), (visibleScroll, visible)] {
            document.frame = CGRect(x: 0, y: 0, width: max(scroll.contentSize.width, CGFloat(document.items.count) * 64 + 24), height: 108)
        }
        let bottom = top + 314
        expanded.frame = CGRect(x: 0, y: bottom, width: 96, height: 30)
        collapsed.frame = CGRect(x: 106, y: bottom, width: 72, height: 30)
        automatic.frame = CGRect(x: 188, y: bottom, width: max(32, width - 188), height: 30)
        status.frame = CGRect(x: narrow ? 0 : 200, y: narrow ? bottom + 42 : bottom + 4, width: narrow ? width : max(20, width - 200), height: narrow ? 34 : 30)
        note.frame = CGRect(x: 0, y: narrow ? bottom + 84 : bottom + 48, width: width, height: narrow ? 64 : 48)
    }
}
