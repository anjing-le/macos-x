import AppKit

/// One illustrated instruction sheet. The module switch belongs to the host;
/// permission and recovery actions appear only when the user needs them.
@MainActor final class MenuBarNativeShelfDashboard: NSView {
    var onRead: (() -> Void)?
    var onAccess: (() -> Void)?
    private let guideScroll = NSScrollView()
    private let guide = NSImageView()
    private let assistance = NSView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let action = MinimalButton(title: "", target: nil, action: nil)
    private var needsPermission = false
    private var lastWidth: CGFloat = 0
    private static let artwork: NSImage? = Bundle.main.url(forResource: "SettingsMenuBarBoard", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    private var guideWidth: CGFloat { max(680, bounds.width) }
    private var guideHeight: CGFloat {
        let size = Self.artwork?.size ?? NSSize(width: 2, height: 1)
        return guideWidth * size.height / max(1, size.width)
    }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: 840, height: guideHeight + (assistance.isHidden ? 0 : 86))
    }
    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 840, height: 420))
        guide.image = Self.artwork; guide.imageScaling = .scaleProportionallyUpOrDown
        guide.setAccessibilityElement(true); guide.setAccessibilityRole(.image)
        guide.setAccessibilityLabel("按住 Command，把应用图标拖到我们的苹果左侧，松手自动收纳；拖到右侧保持常驻。悬停苹果展开原生图标，移开后自动收起。同一应用的多个图标请放在同一侧。")
        guide.toolTip = "同一应用的多个图标请放在同一侧；单击、双击仍由原应用处理。"
        guideScroll.drawsBackground = false; guideScroll.borderType = .noBorder
        guideScroll.hasHorizontalScroller = true; guideScroll.autohidesScrollers = true
        guideScroll.scrollerStyle = .overlay; guideScroll.documentView = guide
        addSubview(guideScroll)
        message.font = .systemFont(ofSize: 13); message.textColor = SketchPalette.muted
        action.target = self; action.action = #selector(resolveIssue)
        assistance.addSubview(message); assistance.addSubview(action)
        assistance.isHidden = true; addSubview(assistance)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func resolveIssue() { if needsPermission { onAccess?() } else { onRead?() } }
    func update(active: Bool, busy: Bool, reading: Bool, issue: String?, permitted: Bool) {
        needsPermission = active && !permitted
        let text: String? = needsPermission ? "需要辅助功能权限，授权后即可使用菜单栏收纳。" : active ? issue : nil
        let wasHidden = assistance.isHidden
        assistance.isHidden = text == nil
        message.stringValue = text ?? ""
        action.title = needsPermission ? "授权辅助功能" : "重试"
        action.isEnabled = active && !reading && !busy
        if wasHidden != assistance.isHidden { invalidateIntrinsicContentSize() }
        needsLayout = true
    }
    override func draw(_ dirtyRect: NSRect) { SketchPalette.paper.setFill(); dirtyRect.fill() }
    override func layout() {
        super.layout()
        if lastWidth != bounds.width { lastWidth = bounds.width; invalidateIntrinsicContentSize() }
        // Fill the page with the actual artwork. On narrow windows preserve
        // legibility with horizontal scrolling rather than shrinking the text.
        guideScroll.frame = CGRect(x: 0, y: 0, width: max(1, bounds.width), height: guideHeight)
        guide.frame = CGRect(x: 0, y: 0, width: guideWidth, height: guideHeight)
        assistance.frame = CGRect(x: 0, y: guideHeight + 10, width: max(1, bounds.width), height: 76)
        message.frame = CGRect(x: 0, y: 0, width: assistance.bounds.width, height: 34)
        action.frame = CGRect(x: 0, y: 40, width: needsPermission ? 128 : 70, height: 30)
    }
}
