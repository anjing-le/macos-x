import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CapturePins {
    private var entries: [PinEntry] = []
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.pins", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var pendingAdds = 0
    private var ticket = CaptureImageService.Ticket()
    var onStatus: ((String) -> Void)?
    var count: Int { entries.count }

    func add(_ image: CGImage) {
        guard entries.count + pendingAdds < 8 else { onStatus?("最多 8 张贴图。" ); return }
        let expected = generation, ticket = ticket
        pendingAdds += 1
        queue.async { [weak self] in
            let reduced = ticket.valid ? CaptureRaster.downsample(image, maximumPixels: 4_000_000) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingAdds -= 1
                guard self.generation == expected, ticket.valid, self.entries.count < 8, let reduced else { return }
                let entry = PinEntry(image: reduced)
                entry.onClose = { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    self.entries.removeAll { $0 === entry }
                    self.onStatus?("贴图 \(self.entries.count)/8")
                }
                entry.onStatus = { [weak self] in self?.onStatus?($0) }
                self.entries.append(entry)
                entry.present()
                self.onStatus?("贴图 \(self.entries.count)/8 · 右键操作")
            }
        }
    }
    func hideAll() { entries.forEach { $0.window.orderOut(nil) }; onStatus?("贴图已隐藏。") }
    func showAll() { entries.forEach { $0.window.orderFrontRegardless() } }
    func restoreInteraction() { entries.forEach { $0.window.ignoresMouseEvents = false }; showAll(); onStatus?("已恢复交互。") }
    func closeAll() {
        generation &+= 1
        ticket.cancel(); ticket = CaptureImageService.Ticket()
        let old = entries; entries.removeAll()
        old.forEach { $0.window.close() }
    }
}

@MainActor
private final class PinEntry: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel { override var canBecomeKey: Bool { false } }
    let window: NSPanel
    let image: CGImage
    private let view: PinView
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.pin-export", qos: .userInitiated)
    private var turns = 0
    private var flipped = false
    private var zoom: CGFloat = 1
    private var thumbnail = false
    private var closed = false
    private var exporting = false
    private let lifetime = CaptureImageService.Ticket()
    private var savePanel: NSSavePanel?
    var onClose: (() -> Void)?
    var onStatus: ((String) -> Void)?

    init(image: CGImage) {
        self.image = image; view = PinView(image: image)
        window = Panel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 260),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false; window.delegate = self
        window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view
        view.onZoom = { [weak self] factor in self?.changeZoom(factor) }
        view.onThumbnail = { [weak self] in self?.toggleThumbnail() }
        view.onMenu = { [weak self] in self?.menu() ?? NSMenu() }
        resize()
        window.center()
    }
    func present() { window.orderFrontRegardless() }
    func windowWillClose(_ notification: Notification) {
        closed = true; lifetime.cancel(); savePanel?.cancel(nil); savePanel = nil; onClose?()
    }

    private func resize() {
        let width = turns % 2 == 0 ? image.width : image.height
        let height = turns % 2 == 0 ? image.height : image.width
        let factor = min(1, (thumbnail ? 150 : 480) / CGFloat(max(width, height))) * (thumbnail ? 1 : zoom)
        let size = CGSize(width: max(40, CGFloat(width) * factor), height: max(40, CGFloat(height) * factor))
        let frame = window.frame
        window.setFrame(CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                               width: size.width, height: size.height), display: true)
        view.turns = turns; view.horizontalFlip = flipped; view.needsDisplay = true
    }
    private func changeZoom(_ factor: CGFloat) { thumbnail = false; zoom = min(4, max(0.15, zoom * factor)); resize() }
    @objc private func zoomIn() { changeZoom(1.2) }
    @objc private func zoomOut() { changeZoom(1 / 1.2) }
    @objc private func rotate() { turns = (turns + 1) % 4; resize() }
    @objc private func flip() { flipped.toggle(); resize() }
    @objc private func toggleThumbnail() { thumbnail.toggle(); resize() }
    @objc private func hide() { window.orderOut(nil); onStatus?("贴图已隐藏。") }
    @objc private func closePin() { window.close() }
    @objc private func clickThrough() {
        window.ignoresMouseEvents = true
        onStatus?("已穿透 · 设置可恢复交互")
    }
    @objc private func opacity(_ sender: NSMenuItem) { window.alphaValue = CGFloat(sender.tag) / 100 }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        item("复制", #selector(copyImage)); item("另存为…", #selector(saveImage))
        menu.addItem(.separator())
        item("放大", #selector(zoomIn)); item("缩小", #selector(zoomOut))
        item("旋转 90°", #selector(rotate)); item("水平翻转", #selector(flip))
        let alpha = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for value in [100, 75, 50, 25] {
            let option = NSMenuItem(title: "\(value)%", action: #selector(opacity(_:)), keyEquivalent: "")
            option.tag = value; option.target = self; submenu.addItem(option)
        }
        alpha.submenu = submenu; menu.addItem(alpha)
        item(thumbnail ? "恢复尺寸" : "缩略图", #selector(toggleThumbnail))
        item("点击穿透", #selector(clickThrough)); item("隐藏", #selector(hide))
        menu.addItem(.separator()); item("关闭", #selector(closePin))
        return menu
    }
    private func export(_ completion: @escaping (CGImage?) -> Void) {
        let source = image, turns = turns, flipped = flipped, lifetime = lifetime
        queue.async { [weak self] in
            guard lifetime.valid else { return }
            let result: CGImage? = autoreleasepool {
                let width = turns % 2 == 0 ? source.width : source.height
                let height = turns % 2 == 0 ? source.height : source.width
                guard let context = CaptureRaster.context(width: width, height: height) else { return nil }
                context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
                context.rotate(by: CGFloat(turns) * .pi / 2)
                context.scaleBy(x: flipped ? -1 : 1, y: 1)
                context.draw(source, in: CGRect(x: -CGFloat(source.width) / 2, y: -CGFloat(source.height) / 2,
                                               width: CGFloat(source.width), height: CGFloat(source.height)))
                return context.makeImage()
            }
            DispatchQueue.main.async { [weak self] in
                guard self?.closed == false else { return }; completion(result)
            }
        }
    }
    @objc private func copyImage() {
        guard !closed, !exporting else { return }; exporting = true
        export { [weak self] image in
            guard let self else { return }
            guard let image else { self.exporting = false; self.onStatus?("贴图渲染失败。" ); return }
            let lifetime = self.lifetime
            self.queue.async { [weak self] in
                guard lifetime.valid else { return }
                let data = CaptureEditor.pngData(image)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.exporting = false
                    guard let data else { self.onStatus?("贴图编码失败，未修改剪贴板。"); return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
                    self.onStatus?("已复制贴图。")
                }
            }
        }
    }
    @objc private func saveImage() {
        guard !closed, !exporting else { return }; exporting = true
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "贴图.png"
        savePanel = panel
        panel.begin { [weak self] response in
            guard let self, !self.closed else { return }
            self.savePanel = nil
            guard response == .OK, let url = panel.url else { self.exporting = false; return }
            self.export { [weak self] image in
                guard let self else { return }
                guard let image else { self.exporting = false; self.onStatus?("贴图渲染失败。" ); return }
                let lifetime = self.lifetime
                self.queue.async { [weak self] in
                    guard lifetime.valid else { return }
                    let success = CaptureEditor.writePNG(image, to: url)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.exporting = false; self.onStatus?(success ? "已保存贴图。" : "贴图保存失败。")
                    }
                }
            }
        }
    }
}

@MainActor
private final class PinView: NSView {
    private let image: CGImage
    var turns = 0, horizontalFlip = false
    var onZoom: ((CGFloat) -> Void)?
    var onThumbnail: (() -> Void)?
    var onMenu: (() -> NSMenu)?
    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onThumbnail?() } else { window?.performDrag(with: event) }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = max(-10, min(10, event.scrollingDeltaY))
        if abs(delta) > 0.01 { onZoom?(pow(1.025, delta)) }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = turns % 2 == 0 ? image.width : image.height
        let height = turns % 2 == 0 ? image.height : image.width
        let scale = min(bounds.width / CGFloat(width), bounds.height / CGFloat(height))
        context.saveGState(); defer { context.restoreGState() }
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: CGFloat(turns) * .pi / 2); context.scaleBy(x: horizontalFlip ? -scale : scale, y: scale)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
    }
}

enum CaptureClipboard {
    static func image(from data: Data) -> CGImage? {
        guard data.count <= 64_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return CaptureRaster.downsample(image, maximumPixels: 4_000_000)
    }
    static func text(_ value: String) -> CGImage? {
        guard !value.isEmpty, value.count <= 4096 else { return nil }
        let font = CTFontCreateWithName("Helvetica" as CFString, 22, nil)
        let attributed = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: 550, height: CGFloat.greatestFiniteMagnitude), nil)
        guard size.height <= 1800, let context = CaptureRaster.context(width: 590, height: max(80, Int(size.height.rounded(.up)) + 40)) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0.99, blue: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let path = CGPath(rect: CGRect(x: 20, y: 20, width: 550, height: context.height - 40), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        return context.makeImage()
    }
}
