import AppKit

/// Explanatory artwork, never a replacement for a live control or preview.
/// Three small, process-local lazy resources; no network, timers or full-size decode.
@MainActor final class SettingsGuideView: NSView {
    private static var images: [String: NSImage] = [:]
    private let artwork = NSImageView()
    private let captions: [NSTextField]
    private let detail: NSTextField
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 540, height: 240) }

    init(kind: String) {
        let asset: String, titles: [String], help: String
        switch kind {
        case "capture":
            asset = "GuideCapture"; titles = ["吸附窗口", "贴图白光", "区域录屏"]
            help = "截图时指向窗口可吸附；贴图边缘可选；录屏先框选，再确认开始，再用同一快捷键结束。"
        case "windowSwitcher":
            asset = "GuideSwitcher"; titles = ["两行 · 分页", "全部 · 滚动"]
            help = "两行显示页数；全部可滚动。Tab / 方向键选择，松开 ⌘ 切换；下方显示窗口总数。"
        default:
            asset = "GuidePrompts"; titles = ["常用位置", "搜索标题", "复制内容"]
            help = "下方是真实布局预览，点击位置编辑标题与内容；呼出后 ↑↓ 选择，Enter 复制。"
        }
        captions = titles.map {
            let label = NSTextField(labelWithString: $0)
            label.alignment = .center; label.font = SketchPalette.heading(15)
            label.textColor = SketchPalette.ink; return label
        }
        detail = NSTextField(wrappingLabelWithString: help)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        super.init(frame: CGRect(x: 0, y: 0, width: 540, height: 240))
        if Self.images[asset] == nil, let url = Bundle.main.url(forResource: asset, withExtension: "png"),
           let image = NSImage(contentsOf: url) { Self.images[asset] = image }
        artwork.image = Self.images[asset]; artwork.imageScaling = .scaleProportionallyUpOrDown
        artwork.setAccessibilityLabel(titles.joined(separator: "，"))
        for view in [artwork, detail] + captions { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        SketchPalette.paper.setFill(); dirtyRect.fill()
    }
    override func layout() {
        super.layout()
        let width = min(540, bounds.width), imageHeight = width / 3
        artwork.frame = CGRect(x: 0, y: 0, width: width, height: imageHeight)
        for (index, label) in captions.enumerated() {
            label.frame = CGRect(x: CGFloat(index) * width / CGFloat(captions.count), y: imageHeight + 1,
                                 width: width / CGFloat(captions.count), height: 23)
        }
        detail.frame = CGRect(x: 0, y: imageHeight + 29, width: width, height: 31)
    }
}
