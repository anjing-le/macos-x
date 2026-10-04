import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CaptureEditor: NSObject, NSWindowDelegate {
    let window: NSWindow
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

    init(image: CGImage) {
        canvas = CaptureCanvas(image: image)
        let available = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: min(1040, available.width - 60), height: min(720, available.height - 60)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "截图标注"
        window.minSize = CGSize(width: 720, height: 440)
        window.isReleasedWhenClosed = false; window.delegate = self
        let container = NSView()
        let tools = NSSegmentedControl(labels: ["矩形", "椭圆", "箭头", "画笔", "高亮", "文字", "马赛克", "模糊", "橡皮"],
                                       trackingMode: .selectOne, target: self, action: #selector(changeTool(_:)))
        tools.selectedSegment = 0; tools.font = .systemFont(ofSize: 11)
        color.color = .systemRed; color.target = self; color.action = #selector(changeColor)
        color.translatesAutoresizingMaskIntoConstraints = false
        color.widthAnchor.constraint(equalToConstant: 38).isActive = true
        let width = NSSlider(value: 3, minValue: 1, maxValue: 12, target: self, action: #selector(changeWidth(_:)))
        width.toolTip = "线条粗细"; width.translatesAutoresizingMaskIntoConstraints = false
        width.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let toolRow = NSStackView(views: [tools, color, width]); toolRow.spacing = 10
        let undoButton = NSButton(title: "撤销", target: self, action: #selector(undoAction))
        let redoButton = NSButton(title: "重做", target: self, action: #selector(redoAction))
        let copy = NSButton(title: "复制", target: self, action: #selector(copyImage))
        let save = NSButton(title: "保存…", target: self, action: #selector(saveImage))
        let pin = NSButton(title: "贴图", target: self, action: #selector(pinImage))
        let actions = NSStackView(views: [undoButton, redoButton, copy, save, pin]); actions.spacing = 10
        let top = NSStackView(views: [toolRow, actions, status]); top.orientation = .vertical; top.alignment = .leading; top.spacing = 8
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        for view in [top, canvas] { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            top.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            top.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container; window.center()
        canvas.onAnnotation = { [weak self] in self?.append($0) }
        canvas.onErase = { [weak self] point, radius in self?.erase(point, radius) }
        canvas.onText = { [weak self] point, width, ink in self?.addText(point, width, ink) }
        canvas.onCopy = { [weak self] in self?.copyImage() }
        canvas.onUndo = { [weak self] in self?.undoAction() }
        canvas.onRedo = { [weak self] in self?.redoAction() }
    }

    func present() { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas); NSApp.activate(ignoringOtherApps: true) }
    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        window.close()
    }
    func windowWillClose(_ notification: Notification) {
        closed = true; revision &+= 1; lifetime.cancel(); preview?.cancel(); onClose?()
    }
    @objc private func changeTool(_ sender: NSSegmentedControl) { canvas.tool = CaptureTool(rawValue: sender.selectedSegment) ?? .rectangle; window.makeFirstResponder(canvas) }
    @objc private func changeColor() { canvas.ink = CaptureInk(color.color) }
    @objc private func changeWidth(_ sender: NSSlider) { canvas.lineWidth = CGFloat(sender.doubleValue) }

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
    @objc private func copyImage() {
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
                    NSPasteboard.general.setData(data, forType: .png)
                    self.status.stringValue = "已复制。"
                }
            }
        }
    }
    @objc private func pinImage() {
        guard beginExport() else { return }
        render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
            guard let self else { return }
            self.exporting = false; self.onPin?(image); self.status.stringValue = "已发送贴图。"
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
