import AppKit

@MainActor
enum SketchIcons {
    enum Kind: String { case capture, switcher, prompt, plus, back, update, settings, close, minimize, expand }
    private static var images: [String: NSImage] = [:]
    static func kind(for symbol: String) -> Kind? {
        switch symbol {
        case "camera.viewfinder": return .capture
        case "macwindow.on.rectangle": return .switcher
        case "text.bubble": return .prompt
        case "plus": return .plus
        case "chevron.left": return .back
        case "arrow.down.to.line": return .update
        case "gearshape": return .settings
        default: return nil
        }
    }
    static func image(_ symbol: String, size: CGFloat = 24) -> NSImage? {
        guard let kind = kind(for: symbol) else { return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return image(kind, size: size)
    }
    static func image(_ kind: Kind, size: CGFloat = 24) -> NSImage {
        let key = kind.rawValue + "-" + String(Int(size))
        if let image = images[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            MainActor.assumeIsolated {
                NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current?.cgContext.scaleBy(x: size / 64, y: size / 64)
                draw(kind)
                return true
            }
        }
        image.isTemplate = false
        if images.count >= 32 { images.removeAll() }
        images[key] = image; return image
    }
    private static func draw(_ kind: Kind) {
        let path = NSBezierPath()
        func line(_ points: [(CGFloat, CGFloat)]) {
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.0, y: first.1))
            for p in points.dropFirst() { path.line(to: CGPoint(x: p.0, y: p.1)) }
        }
        func tile(_ rect: NSRect, _ color: NSColor) {
            let tile = SketchPencil.outline(in: rect, radius: 5)
            SketchPalette.fill(tile, color: color.withAlphaComponent(0.58))
            SketchPencil.stroke(tile, color: SketchPalette.ink, width: 1.9)
        }
        switch kind {
        case .capture:
            tile(NSRect(x: 13, y: 15, width: 38, height: 32), SketchPalette.blue)
            path.appendOval(in: NSRect(x: 24, y: 23, width: 16, height: 16))
            line([(8, 53), (8, 10), (55, 10)]); line([(6, 48), (57, 48), (57, 7)])
        case .switcher:
            tile(NSRect(x: 10, y: 23, width: 29, height: 29), SketchPalette.green)
            tile(NSRect(x: 26, y: 10, width: 29, height: 29), SketchPalette.green)
        case .prompt:
            let bubble = NSBezierPath()
            bubble.move(to: CGPoint(x: 14, y: 16)); bubble.line(to: CGPoint(x: 9, y: 8))
            bubble.line(to: CGPoint(x: 10, y: 46)); bubble.curve(to: CGPoint(x: 17, y: 53), controlPoint1: CGPoint(x: 10, y: 52), controlPoint2: CGPoint(x: 12, y: 53))
            bubble.line(to: CGPoint(x: 47, y: 53)); bubble.curve(to: CGPoint(x: 54, y: 46), controlPoint1: CGPoint(x: 52, y: 53), controlPoint2: CGPoint(x: 54, y: 52))
            bubble.line(to: CGPoint(x: 54, y: 23)); bubble.curve(to: CGPoint(x: 47, y: 16), controlPoint1: CGPoint(x: 54, y: 18), controlPoint2: CGPoint(x: 52, y: 16)); bubble.close()
            SketchPalette.fill(bubble, color: SketchPalette.purple.withAlphaComponent(0.54))
            SketchPencil.stroke(bubble, color: SketchPalette.ink, width: 1.9)
            line([(21, 38), (44, 38)]); line([(21, 29), (37, 29)])
        case .plus: line([(13, 32), (51, 32)]); line([(32, 13), (32, 51)])
        case .back: line([(40, 12), (20, 32), (40, 52)])
        case .update: line([(32, 53), (32, 20)]); line([(19, 33), (32, 20), (45, 33)]); line([(14, 12), (50, 12)])
        case .settings:
            path.appendOval(in: NSRect(x: 23, y: 23, width: 18, height: 18))
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                line([(32 + cos(a) * 18, 32 + sin(a) * 18), (32 + cos(a) * 25, 32 + sin(a) * 25)])
            }
            path.appendOval(in: NSRect(x: 13, y: 13, width: 38, height: 38))
        case .close: line([(20, 20), (44, 44)]); line([(20, 44), (44, 20)])
        case .minimize: line([(18, 32), (46, 32)])
        case .expand: line([(18, 32), (18, 18), (32, 18)]); line([(32, 46), (46, 46), (46, 32)]); line([(19, 19), (45, 45)])
        }
        SketchPencil.stroke(path, color: SketchPalette.ink, width: kind == .update ? 5.5 : kind == .plus ? 2.5 : 2.2)
    }
}

@MainActor
final class SketchWindowHeader: SketchSurface {
    private let titleLabel = NSTextField(labelWithString: "macos-x")
    private let close = WindowControl(.close, color: SketchPalette.coral)
    private let minimize = WindowControl(.minimize, color: SketchPalette.yellow)
    private let expand = WindowControl(.expand, color: SketchPalette.green)
    let back = MinimalButton(title: "", target: nil, action: nil, style: .quiet)
    let update = MinimalButton(title: "", target: nil, action: nil, style: .quiet)
    var onBack: (() -> Void)?
    var onUpdate: (() -> Void)?
    var compact = false { didSet { close.showsGlyph = compact; needsLayout = true } }
    var title: String { get { titleLabel.stringValue } set { titleLabel.stringValue = newValue } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        edge = nil; radius = 0
        titleLabel.font = SketchPalette.heading(20); titleLabel.textColor = SketchPalette.ink
        titleLabel.alignment = .center; titleLabel.lineBreakMode = .byTruncatingTail
        for view in [close, minimize, expand, titleLabel, back, update] { addSubview(view) }
        close.target = self; close.action = #selector(closeWindow)
        minimize.target = self; minimize.action = #selector(minimizeWindow)
        expand.target = self; expand.action = #selector(expandWindow)
        back.image = SketchIcons.image(.back, size: 18); back.imagePosition = .imageOnly
        back.target = self; back.action = #selector(goBack); back.toolTip = "返回首页"; back.setAccessibilityLabel("返回首页")
        update.style = .primary
        update.image = SketchIcons.image(.update, size: 28); update.imagePosition = .imageOnly
        update.target = self; update.action = #selector(checkUpdates); update.toolTip = "检查更新"; update.setAccessibilityLabel("检查更新")
        back.isHidden = true
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let y = (bounds.height - 20) / 2
        close.frame = NSRect(x: 20, y: y, width: 20, height: 20)
        minimize.frame = NSRect(x: 48, y: y, width: 20, height: 20)
        expand.frame = NSRect(x: 76, y: y, width: 20, height: 20)
        back.frame = NSRect(x: 116, y: (bounds.height - 30) / 2, width: 30, height: 30)
        update.frame = NSRect(x: bounds.width - 58, y: (bounds.height - 38) / 2, width: 38, height: 38)
        titleLabel.frame = NSRect(x: compact ? 48 : 158, y: y - 2, width: max(0, bounds.width - (compact ? 72 : 316)), height: 24)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshActions() }
    func refreshActions() {
        close.isEnabled = window?.standardWindowButton(.closeButton)?.isEnabled != false
        minimize.isHidden = compact || window?.styleMask.contains(.miniaturizable) != true
        expand.isHidden = compact || window?.styleMask.contains(.resizable) != true
        if compact { back.isHidden = true; update.isHidden = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        if compact { return }
        SketchPalette.paper.setFill(); bounds.fill()
        let line = NSBezierPath(); line.move(to: CGPoint(x: 16, y: 1)); line.line(to: CGPoint(x: bounds.width - 16, y: 1))
        SketchPencil.stroke(line, color: SketchPalette.line.withAlphaComponent(0.45), width: 0.6)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
    }
    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.performMiniaturize(nil) }
    @objc private func expandWindow() { window?.toggleFullScreen(nil) }
    @objc private func goBack() { onBack?() }
    @objc private func checkUpdates() { onUpdate?() }

    private final class WindowControl: NSButton {
        let glyph: SketchIcons.Kind
        let color: NSColor
        private var hovered = false
        var showsGlyph = false { didSet { needsDisplay = true } }
        private var area: NSTrackingArea?
        init(_ glyph: SketchIcons.Kind, color: NSColor) {
            self.glyph = glyph; self.color = color
            super.init(frame: .zero); title = ""; isBordered = false; setButtonType(.momentaryPushIn)
            setAccessibilityLabel(glyph == .close ? "关闭窗口" : glyph == .minimize ? "最小化窗口" : "全屏窗口")
        }
        required init?(coder: NSCoder) { nil }
        override func updateTrackingAreas() {
            super.updateTrackingAreas(); if let area { removeTrackingArea(area) }
            let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(next); area = next
        }
        override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) {
            let shape = NSBezierPath(ovalIn: bounds.insetBy(dx: 2.5, dy: 2.5))
            SketchPalette.fill(shape, color: (isEnabled ? color : SketchPalette.line).withAlphaComponent(0.75))
            SketchPencil.stroke(shape, color: color, width: 0.7)
            if (hovered || showsGlyph) && isEnabled { SketchIcons.image(glyph, size: 15).draw(in: bounds.insetBy(dx: 2.5, dy: 2.5)) }
        }
    }
}

/// Three small bundled illustrations, lazily decoded and shared by home/catalog.
@MainActor
enum SketchCardArt {
    private static var images: [String: NSImage] = [:]
    static func image(_ symbol: String) -> NSImage? {
        let name: String
        switch symbol {
        case "camera.viewfinder": name = "CardCapture"
        case "macwindow.on.rectangle": name = "CardSwitcher"
        case "text.bubble": name = "CardPrompts"
        default: return nil
        }
        if let image = images[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        images[name] = image
        return image
    }
}
