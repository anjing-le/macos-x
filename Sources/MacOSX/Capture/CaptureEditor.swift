import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CaptureEditor: NSObject, NSWindowDelegate {
    let window: NSWindow
    private final class Panel: NSPanel {
        var onCopy: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        @objc func copy(_ sender: Any?) { onCopy?() }
    }
    private final class ToolbarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let toolbar: NSPanel
    private var toolbarVisible = true
    private var localMonitor: Any?
    private var toolButtons = [NSButton]()
    private let canvas: CaptureCanvas
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.render", qos: .userInitiated)
    private let status = NSTextField(labelWithString: "Enter / ⌘C 复制")
    private let color = NSColorWell()
    private var annotations: [CaptureAnnotation] = []
    private var undo: [[CaptureAnnotation]] = [], redo: [[CaptureAnnotation]] = []
    private var revision: UInt64 = 0
    private var closed = false
    private var exporting = false
    private let lifetime = CaptureImageService.Ticket()
    private var preview: CaptureImageService.Ticket?
    var onPin: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    var onExport: (() -> Void)?

    init(image: CGImage, selectionFrame: CGRect? = nil, initialTool: CaptureTool = .rectangle) {
        canvas = CaptureCanvas(image: image)
        canvas.imageInset = 0; canvas.tool = initialTool
        let available = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = min(1, (available.width - 80) / CGFloat(image.width), (available.height - 100) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let region = selectionFrame ?? CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                               width: size.width, height: size.height)
        window = Panel(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        toolbar = ToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "截图标注"; toolbar.title = "标注工具"
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        toolbar.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        for panel in [window, toolbar] {
            panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        window.delegate = self; window.contentView = canvas
        (window as? Panel)?.onCopy = { [weak self] in self?.copyImage() }
        let background = NSVisualEffectView(); background.material = .hudWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 9
        toolbar.isOpaque = false; toolbar.backgroundColor = .clear; toolbar.hasShadow = true
        let row = NSStackView(); row.spacing = 3
        for (tool, symbol, title) in [(CaptureTool.rectangle, "rectangle", "矩形"), (.ellipse, "circle", "椭圆"),
            (.arrow, "arrow.up.right", "箭头"), (.pen, "pencil.tip", "画笔"), (.highlighter, "highlighter", "高亮"),
            (.text, "textformat", "文字"), (.mosaic, "square.grid.3x3", "马赛克"), (.blur, "drop.halffull", "模糊"), (.eraser, "eraser", "橡皮")] {
            let button = icon(symbol, title: title, action: #selector(changeTool(_:)))
            button.tag = tool.rawValue; button.setButtonType(.toggle); row.addArrangedSubview(button); toolButtons.append(button)
        }
        color.color = .systemRed; color.target = self; color.action = #selector(changeColor)
        color.controlSize = .mini; color.toolTip = "标注颜色"; color.setAccessibilityLabel("标注颜色")
        color.translatesAutoresizingMaskIntoConstraints = false; color.widthAnchor.constraint(equalToConstant: 30).isActive = true
        color.heightAnchor.constraint(equalToConstant: 24).isActive = true; row.addArrangedSubview(color)
        let width = NSSlider(value: 3, minValue: 1, maxValue: 12, target: self, action: #selector(changeWidth(_:)))
        width.toolTip = "线条粗细"; width.setAccessibilityLabel("线条粗细"); width.translatesAutoresizingMaskIntoConstraints = false
        width.widthAnchor.constraint(equalToConstant: 46).isActive = true; row.addArrangedSubview(width)
        for (symbol, title, action) in [("arrow.uturn.backward", "撤销 ⌘Z", #selector(undoAction)),
            ("arrow.uturn.forward", "重做 ⌘⇧Z / ⌘Y", #selector(redoAction)), ("square.and.arrow.down", "保存 ⌘S", #selector(saveImage)),
            ("pin", "贴图 ⌘T", #selector(pinImage)), ("doc.on.doc", "复制并退出 Enter", #selector(copyAndClose)), ("xmark", "退出 Esc", #selector(cancelPressed))] {
            row.addArrangedSubview(icon(symbol, title: title, action: action))
        }
        status.font = .systemFont(ofSize: 10); status.textColor = .secondaryLabelColor
        status.stringValue = "Enter 复制并退出 · ⌘C 复制 · Space 显隐工具"
        let stack = NSStackView(views: [row, status]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: background.leadingAnchor), stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor), stack.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
        toolbar.contentView = background
        updateToolButtons()
        canvas.onAnnotation = { [weak self] in self?.append($0) }
        canvas.onErase = { [weak self] point, radius in self?.erase(point, radius) }
        canvas.onText = { [weak self] point, width, ink in self?.addText(point, width, ink) }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onUndo = { [weak self] in self?.undoAction() }
        canvas.onRedo = { [weak self] in self?.redoAction() }
    }

    private func icon(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        button.isBordered = false; button.toolTip = title; button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 25).isActive = true; button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
    func present() {
        guard !closed else { return }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas); positionToolbar()
        NSApp.activate(ignoringOtherApps: true)
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, !self.closed, self.window.attachedSheet == nil,
                          event.window === self.window || event.window === self.toolbar else { return false }
                    let command = event.modifierFlags.contains(.command)
                    switch event.keyCode {
                    case 8 where command: self.copyImage()
                    case 1 where command: self.saveImage()
                    case 17 where command: self.pinImage()
                    case 6 where command: event.modifierFlags.contains(.shift) ? self.redoAction() : self.undoAction()
                    case 16 where command: self.redoAction()
                    case 36, 76: self.copyImage(closeAfter: true)
                    case 53: self.close()
                    case 49 where !command:
                        self.toolbarVisible.toggle()
                        if self.toolbarVisible { self.positionToolbar() } else { self.toolbar.orderOut(nil) }
                    default: return false
                    }
                    return true
                }
                return handled ? nil : event
            }
        }
    }
    private func positionToolbar() {
        guard toolbarVisible, !closed else { return }
        let region = window.frame
        let area = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: region.midX, y: region.midY)) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? region
        let size = toolbar.contentView?.fittingSize ?? CGSize(width: 520, height: 48)
        let x = min(max(area.minX + 6, region.maxX - size.width), area.maxX - size.width - 6)
        let preferredY = region.minY - size.height - 8
        let y = preferredY >= area.minY + 6 ? preferredY : min(area.maxY - size.height - 6, region.maxY + 8)
        toolbar.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true); toolbar.orderFrontRegardless()
    }
    func close() {
        guard !closed else { return }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        window.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; revision &+= 1; lifetime.cancel(); preview?.cancel()
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        toolbar.orderOut(nil); toolbar.close()
        let callback = onClose; onClose = nil; onExport = nil; onPin = nil; callback?()
    }
    private func updateToolButtons() { for button in toolButtons { button.state = button.tag == canvas.tool.rawValue ? .on : .off } }
    @objc private func changeTool(_ sender: NSButton) { canvas.tool = CaptureTool(rawValue: sender.tag) ?? .rectangle; updateToolButtons(); window.makeFirstResponder(canvas) }
    @objc private func changeColor() { canvas.ink = CaptureInk(color.color); window.makeFirstResponder(canvas) }
    @objc private func changeWidth(_ sender: NSSlider) { canvas.lineWidth = CGFloat(sender.doubleValue); window.makeFirstResponder(canvas) }
    @objc private func cancelPressed() { close() }
    @objc private func copyAndClose() { copyImage(closeAfter: true) }

    private func remember() { undo.append(annotations); if undo.count > 60 { undo.removeFirst() }; redo.removeAll() }
    private func append(_ annotation: CaptureAnnotation) {
        guard annotations.count < 256 else { status.stringValue = "标注数量已达 256，请撤销部分标注。"; return }
        remember(); annotations.append(annotation); refresh()
    }
    private func erase(_ point: CGPoint, _ radius: CGFloat) {
        guard let index = annotations.lastIndex(where: { $0.bounds.insetBy(dx: -radius, dy: -radius).contains(point) }) else { return }
        remember(); annotations.remove(at: index); refresh()
    }
    private func addText(_ point: CGPoint, _ width: CGFloat, _ ink: CaptureInk) {
        let alert = NSAlert(); alert.messageText = "添加文字"
        let input = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 26))
        alert.accessoryView = input; alert.addButton(withTitle: "添加"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
            self?.append(CaptureAnnotation(tool: .text, points: [point], ink: ink, width: width, text: String(input.stringValue.prefix(1000))))
        }
    }
    @objc private func undoAction() {
        guard let previous = undo.popLast() else { return }
        redo.append(annotations); annotations = previous; refresh()
    }
    @objc private func redoAction() {
        guard let next = redo.popLast() else { return }
        undo.append(annotations); annotations = next; refresh()
    }
    private func refresh() {
        revision &+= 1; let expected = revision
        preview?.cancel()
        let ticket = CaptureImageService.Ticket(); preview = ticket
        render(ticket: ticket) { [weak self] image in
            guard let self, self.revision == expected else { return }
            self.canvas.image = image
        }
    }
    private func render(ticket: CaptureImageService.Ticket? = nil, onFailure: (() -> Void)? = nil,
                        _ completion: @escaping (CGImage) -> Void) {
        let base = canvas.base, snapshot = annotations, lifetime = lifetime
        queue.async { [weak self] in
            guard lifetime.valid, ticket?.valid != false else { return }
            let image = autoreleasepool {
                CaptureAnnotationRenderer.render(base: base, annotations: snapshot,
                                                  isCurrent: { lifetime.valid && ticket?.valid != false })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, ticket?.valid != false else { return }
                if let image { completion(image) }
                else { self.status.stringValue = "渲染失败，请缩小截图。"; onFailure?() }
            }
        }
    }
    private func copyImage(closeAfter: Bool = false) {
        guard beginExport() else { return }
        render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
            guard let self else { return }
            let lifetime = self.lifetime
            self.queue.async { [weak self] in
                guard lifetime.valid else { return }
                let data = Self.pngData(image)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.exporting = false
                    guard let data else { self.status.stringValue = "图像编码失败，未修改剪贴板。"; return }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setData(data, forType: .png) else { self.status.stringValue = "复制失败。"; return }
                    self.onExport?(); self.status.stringValue = "已复制。"
                    if closeAfter { self.close() }
                }
            }
        }
    }
    @objc private func pinImage() {
        guard beginExport() else { return }
        render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
            guard let self else { return }
            self.exporting = false
            guard let pin = self.onPin else { self.status.stringValue = "贴图不可用。"; return }
            pin(image); self.onExport?(); self.close()
        }
    }
    private func beginExport() -> Bool {
        guard !closed, !exporting else { return false }
        exporting = true; status.stringValue = "处理中…"; return true
    }
    @objc private func saveImage() {
        guard beginExport() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "截图.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.closed else { return }
            guard response == .OK, let url = panel.url else { self.exporting = false; self.status.stringValue = "已取消。"; return }
            self.render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
                guard let self else { return }
                let lifetime = self.lifetime
                self.queue.async { [weak self] in
                    guard lifetime.valid else { return }
                    let saved = Self.writePNG(image, to: url)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.exporting = false
                        self.status.stringValue = saved ? "已保存。" : "保存失败，请检查目标文件夹。"
                        if saved { self.onExport?() }
                    }
                }
            }
        }
    }
    nonisolated static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let data = pngData(image) else { return false }
        do { try data.write(to: url, options: .atomic); return true } catch { return false }
    }
    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
