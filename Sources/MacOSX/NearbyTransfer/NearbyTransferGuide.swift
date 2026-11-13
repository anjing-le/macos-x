import AppKit
import MacOSXCore

/// Settings explain the one real surface; they never embed another live drawer.
@MainActor final class NearbyTransferGuide: NSView {
    var onOpen: (() -> Void)?
    private let illustration = NSImageView()
    private let title = NSTextField(wrappingLabelWithString: AppLanguage.text("单击苹果，打开互传抽屉"))
    private let detail = NSTextField(wrappingLabelWithString: AppLanguage.text("连接设备 · 拖入文件 · ⌘V 发送"))
    private let open = MinimalButton(title: AppLanguage.text("打开抽屉"), target: nil, action: nil, style: .standard)
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 840, height: 300) }
    override init(frame: NSRect) {
        super.init(frame: frame)
        illustration.image = SketchCardArt.image("folder.badge.person.crop")
        illustration.imageScaling = .scaleProportionallyUpOrDown
        title.font = SketchPalette.heading(20); title.textColor = SketchPalette.ink; title.alignment = .center; title.maximumNumberOfLines = 2
        detail.font = .systemFont(ofSize: 13); detail.textColor = SketchPalette.muted; detail.alignment = .center
        open.target = self; open.action = #selector(openDrawer)
        for view in [illustration, title, detail, open] { addSubview(view) }
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    func update(enabled: Bool) { if open.isEnabled != enabled { open.isEnabled = enabled } }
    override func layout() {
        super.layout()
        let w = bounds.width, imageWidth = min(220, max(100, w - 40))
        illustration.frame = CGRect(x: (w - imageWidth) / 2, y: 4, width: imageWidth, height: 128)
        title.frame = CGRect(x: 12, y: 136, width: max(1, w - 24), height: 54)
        detail.frame = CGRect(x: 12, y: 196, width: max(1, w - 24), height: 42)
        open.frame = CGRect(x: (w - 140) / 2, y: 248, width: 140, height: 32)
    }
    @objc private func openDrawer() { onOpen?() }
}
