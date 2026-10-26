import AppKit

/// An illustrated native guide; application controls remain in the system bar.
@MainActor final class MenuBarNativeShelfDashboard: NSView {
    var onCollect: ((String, Bool) -> Void)?
    var onRead: (() -> Void)?
    var onShow: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onAccess: (() -> Void)?
    private let heading = NSTextField(wrappingLabelWithString: "左侧收纳，右侧常驻")
    private let explanation = NSTextField(wrappingLabelWithString: "按住 ⌘ 拖动图标，松手后自动按苹果左右归类。")
    private let note = NSTextField(wrappingLabelWithString: "悬停苹果展开原图标；单击、双击仍由原应用处理。同一应用的多个图标请放在同侧。")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let read = MinimalButton(title: "按当前位置收纳", target: nil, action: nil)
    private let show = MinimalButton(title: "全部显示", target: nil, action: nil)
    private let access = MinimalButton(title: "授权辅助功能", target: nil, action: nil)
    private let guideScroll = NSScrollView()
    private let guide = NSImageView()
    private let scroll = NSScrollView()
    private let list = NativeMenuBarCollectedList()
    private var items: [NativeMenuBarChoice] = []
    private var narrow = false
    private static let artwork: NSImage? = Bundle.main.url(forResource: "SettingsMenuBarBoard", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: narrow ? 590 : 500) }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 840, height: 500))
        heading.font = SketchPalette.heading(23); heading.textColor = SketchPalette.ink
        for label in [explanation, note, status] { label.font = .systemFont(ofSize: 13); label.textColor = SketchPalette.muted }
        read.target = self; read.action = #selector(readItems)
        show.target = self; show.action = #selector(showItems)
        access.target = self; access.action = #selector(requestAccess)
        guide.image = Self.artwork; guide.imageScaling = .scaleProportionallyUpOrDown
        guide.setAccessibilityElement(true); guide.setAccessibilityRole(.image)
        guide.setAccessibilityLabel("按住 Command，把应用图标拖到我们的苹果左侧，松手自动收纳；苹果右侧保持常驻。")
        guideScroll.drawsBackground = false; guideScroll.borderType = .noBorder
        guideScroll.hasHorizontalScroller = true; guideScroll.autohidesScrollers = true; guideScroll.documentView = guide
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = list
        [heading, explanation, guideScroll, read, show, access, scroll, status, note].forEach { addSubview($0) }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func readItems() { onRead?() }
    @objc private func showItems() { onShow?() }
    @objc private func requestAccess() { onAccess?() }
    func update(active: Bool, hidden: Bool, busy: Bool, reading: Bool, issue: String?, choices: [NativeMenuBarChoice], permitted: Bool) {
        read.isEnabled = active && !reading && !busy; show.isEnabled = active
        access.isHidden = permitted; access.isEnabled = active
        let collected = choices.filter(\.collected)
        if collected.map({ "\($0.bundle)|\($0.running)|\($0.name)" }) != items.map({ "\($0.bundle)|\($0.running)|\($0.name)" }) {
            items = collected; list.setItems(collected)
        }
        status.stringValue = issue ?? (!active ? "开启后可从顶部苹果展开。" : reading ? "正在确认拖动后的位置…" : busy ? "正在收纳左侧图标…" : hidden ? "已收纳 \(collected.count) 个应用 · 悬停苹果展开" : "原生图标已展开 · 右侧常驻")
        needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) { SketchPalette.paper.setFill(); dirtyRect.fill() }
    override func layout() {
        super.layout()
        let width = max(220, bounds.width), compact = width < 500
        if narrow != compact { narrow = compact; invalidateIntrinsicContentSize() }
        heading.frame = CGRect(x: 0, y: 4, width: width, height: compact ? 62 : 32)
        explanation.frame = CGRect(x: 0, y: compact ? 70 : 44, width: width, height: compact ? 40 : 24)
        let guideY: CGFloat = compact ? 112 : 74, guideHeight: CGFloat = compact ? 214 : 198
        guideScroll.frame = CGRect(x: 0, y: guideY, width: width, height: guideHeight)
        // Narrow settings scroll the guide instead of making its titles tiny.
        guide.frame = CGRect(x: 0, y: 0, width: max(600, guideScroll.contentSize.width), height: guideScroll.contentSize.height)
        let top = guideY + guideHeight + 8
        read.frame = CGRect(x: 0, y: top, width: 144, height: 30)
        show.frame = CGRect(x: compact ? 0 : 154, y: compact ? top + 40 : top, width: 96, height: 30)
        access.frame = CGRect(x: compact ? 106 : 260, y: compact ? top + 40 : top, width: 114, height: 30)
        let start = top + (compact ? 82 : 42), bottom = max(start + 60, bounds.height - (compact ? 94 : 78))
        scroll.frame = CGRect(x: 0, y: start, width: width, height: bottom - start)
        list.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, list.contentHeight))
        status.frame = CGRect(x: 0, y: bottom + 8, width: width, height: 28)
        note.frame = CGRect(x: 0, y: bottom + 38, width: width, height: compact ? 56 : 40)
    }
}

@MainActor private final class NativeMenuBarCollectedList: NSView {
    private var rows: [NSTextField] = []
    private let empty = NSTextField(wrappingLabelWithString: "还没有收纳图标 · 按住 ⌘ 拖到苹果左侧开始")
    override var isFlipped: Bool { true }
    var contentHeight: CGFloat { max(60, CGFloat(rows.count) * 30) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        empty.font = .systemFont(ofSize: 13); empty.textColor = SketchPalette.muted; addSubview(empty)
    }
    required init?(coder: NSCoder) { nil }
    func setItems(_ items: [NativeMenuBarChoice]) {
        rows.forEach { $0.removeFromSuperview() }; rows.removeAll()
        for item in items {
            let name = NSTextField(labelWithString: item.name + (item.running ? "" : " · 未运行"))
            name.font = .systemFont(ofSize: 14); name.textColor = SketchPalette.ink
            name.lineBreakMode = .byTruncatingTail; name.toolTip = item.name
            rows.append(name); addSubview(name)
        }
        empty.isHidden = !rows.isEmpty; needsLayout = true; superview?.superview?.needsLayout = true
    }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = CGRect(x: 8, y: CGFloat(index) * 30 + 3, width: max(20, bounds.width - 16), height: 24) }
        empty.frame = CGRect(x: 8, y: 10, width: max(20, bounds.width - 16), height: 48)
    }
}
