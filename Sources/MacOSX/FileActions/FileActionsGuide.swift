import AppKit
import ImageIO
import MacOSXCore

/// One shared, language-neutral illustration. Real captions and shortcut controls
/// stay native and use the same geometry as the artwork, including when scrolled.
@MainActor final class FileActionsGuide: NSView {
  var onOpen: (() -> Void)?
  private let scroll = NSScrollView()
  private let canvas: FileActionsGuideCanvas
  private let open = FileActionButton(AppLanguage.text("打开文件操作"))
  override var isFlipped: Bool { true }
  override var intrinsicContentSize: NSSize {
    NSSize(width: 840, height: min(840, max(800, bounds.width)) / 2 + 48)
  }
  init(shortcut: NSView) {
    canvas = FileActionsGuideCanvas(shortcut: shortcut)
    super.init(frame: .zero)
    scroll.drawsBackground = false
    scroll.borderType = .noBorder
    scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = canvas
    addSubview(scroll)
    addSubview(open)
    open.invoke = { [weak self] in self?.onOpen?() }
    scroll.setAccessibilityLabel(AppLanguage.text("文件操作使用图示"))
  }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    SketchPalette.paper.setFill()
    bounds.fill()
  }
  override func layout() {
    super.layout()
    let width = min(840, max(800, bounds.width))
    let height = width / 2
    // Keep text/control sizes readable on narrow windows rather than scaling
    // them into illegibility; the illustration and its controls scroll together.
    scroll.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height + 4)
    canvas.frame = CGRect(x: 0, y: 0, width: max(bounds.width, width), height: height)
    canvas.artworkFrame = CGRect(
      x: max(0, (canvas.bounds.width - width) / 2), y: 0, width: width, height: height)
    canvas.layoutSubtreeIfNeeded()
    open.frame = CGRect(
      x: max(0, bounds.width - 152), y: height + 12, width: min(152, bounds.width), height: 30)
  }
}

@MainActor final class FileActionsGuideCanvas: NSView {
  private static let illustration: NSImage? = {
    guard let url = AppLanguage.resource("SettingsFileActionsBoard", extension: "png"),
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 1680,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: 840, height: 420))
  }()
  let shortcut: NSView
  var artworkFrame = CGRect.zero { didSet { needsLayout = true } }
  private let art = NSImageView()
  private var captions: [(NSTextField, CGRect)] = []
  override var isFlipped: Bool { true }
  init(shortcut: NSView) {
    self.shortcut = shortcut
    super.init(frame: .zero)
    art.image = Self.illustration
    art.imageScaling = .scaleProportionallyUpOrDown
    art.setAccessibilityElement(false)
    addSubview(art)
    addSubview(shortcut)
    if let stack = shortcut as? NSStackView { stack.alignment = .centerX }
    shortcut.toolTip = AppLanguage.text("点击修改唤起快捷键")
    for (text, rect) in [
      (AppLanguage.text("选中一个文件"), CGRect(x: 0.04, y: 0.432, width: 0.26, height: 0.055)),
      (AppLanguage.text("选择操作"), CGRect(x: 0.70, y: 0.432, width: 0.26, height: 0.055)),
      (AppLanguage.text("转格式 · 压缩 · 缩尺寸"), CGRect(x: 0.025, y: 0.875, width: 0.285, height: 0.065)),
      (
        AppLanguage.text("文档转 Markdown / TXT"),
        CGRect(x: 0.35, y: 0.875, width: 0.30, height: 0.065)
      ),
      (AppLanguage.text("PDF 按页导出图片"), CGRect(x: 0.69, y: 0.875, width: 0.29, height: 0.065)),
    ] {
      let label = NSTextField(labelWithString: text)
      label.alignment = .center
      label.font = .systemFont(ofSize: 13, weight: .medium)
      label.textColor = SketchPalette.ink
      addSubview(label)
      captions.append((label, rect))
    }
  }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    art.frame = artworkFrame
    func frame(_ normalized: CGRect) -> CGRect {
      CGRect(
        x: artworkFrame.minX + normalized.minX * artworkFrame.width,
        y: artworkFrame.minY + normalized.minY * artworkFrame.height,
        width: normalized.width * artworkFrame.width,
        height: normalized.height * artworkFrame.height)
    }
    shortcut.frame = frame(CGRect(x: 0.36, y: 0.205, width: 0.28, height: 0.13))
    for (label, normalized) in captions { label.frame = frame(normalized) }
  }
}
