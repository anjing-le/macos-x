import AppKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

@MainActor
final class CaptureEditor: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    let window: NSWindow
    private final class Panel: NSPanel {
        var onCopy: (() -> Void)?
        var onUndo: (() -> Void)?
        var onRedo: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
        @objc func copy(_ sender: Any?) { onCopy?() }
        @objc func undo(_ sender: Any?) { onUndo?() }
        @objc func redo(_ sender: Any?) { onRedo?() }
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
    private var colorButton: CaptureToolButton!
    private var recognitionButton: CaptureToolButton!
    private var colorPopover: NSPopover?
    private var recognition: VNRecognizeTextRequest?
    private let editingPin: Bool
    var onApply: ((CGImage) -> Void)?
    private var annotations: [CaptureAnnotation] = []
    private var undo: [[CaptureAnnotation]] = [], redo: [[CaptureAnnotation]] = []
    private var revision: UInt64 = 0
    private var closed = false
    private var exporting = false
    private var textInput: NSTextField?
    private var textAnnotation: CaptureAnnotation?
    private let lifetime = CaptureImageService.Ticket()
    private var preview: CaptureImageService.Ticket?
    var onPin: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    var onExport: (() -> Void)?
    var onCopied: (() -> Void)?
    var onReselect: (() -> Void)?
    var colorAtPointer: ((Bool) -> String?)?

    init(image: CGImage, selectionFrame: CGRect? = nil, editingPin: Bool = false) {
        self.editingPin = editingPin
        canvas = CaptureCanvas(image: image)
        canvas.imageInset = 0
        let available = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let scale = min(1, (available.width - 80) / CGFloat(image.width), (available.height - 100) / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let region = selectionFrame ?? CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                               width: size.width, height: size.height)
        window = Panel(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        toolbar = ToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.appearance = NSAppearance(named: .aqua); toolbar.appearance = NSAppearance(named: .aqua)
        window.title = "截图标注"; toolbar.title = "标注工具"
        let level = editingPin ? NSWindow.Level.floating.rawValue : NSWindow.Level.screenSaver.rawValue
        window.level = NSWindow.Level(rawValue: level + 1)
        toolbar.level = NSWindow.Level(rawValue: level + 2)
        for panel in [window, toolbar] {
            panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.animationBehavior = .none
        }
        window.hasShadow = false
        window.delegate = self; window.contentView = canvas
        let background = CaptureToolbarSurface()
        toolbar.isOpaque = false; toolbar.backgroundColor = .clear; toolbar.hasShadow = false
        let row = NSStackView(); row.spacing = 4
        for (tool, glyph, title) in [(CaptureTool.rectangle, CaptureToolButton.Glyph.rectangle, "矩形 · 1"),
            (.arrow, .arrow, "箭头 · 2"), (.pen, .pen, "画笔 · 3"), (.text, .text, "文字 · 4"), (.mosaic, .mosaic, "马赛克 · 5")] {
            let button = CaptureToolButton(glyph, title: title, target: self, action: #selector(changeTool(_:)))
            button.tag = tool.rawValue; button.setButtonType(.toggle)
            row.addArrangedSubview(button); toolButtons.append(button)
        }
        recognitionButton = CaptureToolButton(.recognition, title: "提取文字 · 6 / ⇧⌘C", target: self, action: #selector(copyRecognizedText))
        row.addArrangedSubview(recognitionButton)
        colorButton = CaptureToolButton(.color, title: "共用颜色 · 7", target: self, action: #selector(showColors))
        colorButton.ink = .systemRed; canvas.ink = CaptureInk(colorButton.ink); row.addArrangedSubview(colorButton)
        status.font = .systemFont(ofSize: 10); status.textColor = NSColor(calibratedWhite: 0.3, alpha: 1)
        status.stringValue = ""; status.isHidden = true
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
        canvas.onCopy = { [weak self] in self?.copyImage(closeAfter: self?.editingPin != true) }
        canvas.onUndo = { [weak self] in self?.undoAction() }
        canvas.onRedo = { [weak self] in self?.redoAction() }
        canvas.onConfirm = { [weak self] in self?.confirm() }
        canvas.onCancel = { [weak self] in self?.cancelCurrentOperation() }
        if let panel = window as? Panel {
            panel.onCopy = { [weak self] in self?.copyImage(closeAfter: self?.editingPin != true) }
            panel.onUndo = { [weak self] in self?.undoAction() }
            panel.onRedo = { [weak self] in self?.redoAction() }
        }
    }

    func present() {
        guard !closed else { return }
        window.displayIfNeeded()
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas); positionToolbar()
        NSApp.activate(ignoringOtherApps: true)
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, !self.closed, self.window.attachedSheet == nil,
                          event.window === self.window || event.window === self.toolbar else { return false }
                    if self.textInput != nil { return false }
                    let command = event.modifierFlags.contains(.command)
                    switch event.keyCode {
                    case 8 where command && event.modifierFlags.contains(.shift): self.copyRecognizedText()
                    case 8 where command: self.copyImage(closeAfter: !self.editingPin)
                    case 8 where event.modifierFlags.contains(.option):
                        if let value = self.colorAtPointer?(event.modifierFlags.contains(.shift)) {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                            self.close()
                        }
                    case 1 where command: self.saveImage()
                    case 17 where command: self.editingPin ? self.confirm() : self.pinImage()
                    case 6 where command: event.modifierFlags.contains(.shift) ? self.redoAction() : self.undoAction()
                    case 13 where command: self.close()
                    case 15 where command && !self.editingPin: self.reselect()
                    case 36, 76: self.confirm()
                    case 53: self.cancelCurrentOperation()
                    case 49 where !command:
                        self.toolbarVisible.toggle()
                        if self.toolbarVisible { self.positionToolbar() } else { self.toolbar.orderOut(nil) }
                    default:
                        guard !command, !event.modifierFlags.contains(.control), let key = event.charactersIgnoringModifiers else { return false }
                        if event.modifierFlags.contains(.option) {
                            switch key {
                            case "1": self.selectTool(.ellipse)
                            case "3": self.selectTool(.highlighter)
                            case "5": self.selectTool(.blur)
                            default: return false
                            }
                        } else {
                            switch key {
                            case "1": self.selectTool(.rectangle)
                            case "2": self.selectTool(.arrow)
                            case "3": self.selectTool(.pen)
                            case "4": self.selectTool(.text)
                            case "5": self.selectTool(.mosaic)
                            case "6": self.copyRecognizedText()
                            case "7": self.showColors()
                            case "e": self.selectTool(.eraser)
                            case "[": self.canvas.lineWidth = max(1, self.canvas.lineWidth - 1)
                            case "]": self.canvas.lineWidth = min(12, self.canvas.lineWidth + 1)
                            default: return false
                            }
                        }
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
        recognition?.cancel(); recognition = nil
        colorPopover?.close(); colorPopover = nil
        toolbar.orderOut(nil); toolbar.close()
        textInput?.delegate = nil; textInput?.removeFromSuperview(); textInput = nil; textAnnotation = nil
        let callback = onClose; onClose = nil; onExport = nil; onCopied = nil; onPin = nil
        onReselect = nil; colorAtPointer = nil; onApply = nil; callback?()
    }
    private func updateToolButtons() { for button in toolButtons { button.state = button.tag == canvas.tool?.rawValue ? .on : .off } }
    @objc private func changeTool(_ sender: NSButton) {
        guard let tool = CaptureTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }
    @objc private func reselect() { guard !exporting else { return }; onReselect?() }
    private func selectTool(_ tool: CaptureTool) {
        finishText(commit: true); canvas.cancelDraft()
        canvas.tool = canvas.tool == tool ? nil : tool
        updateToolButtons(); window.makeFirstResponder(canvas)
    }
    private static let colors: [NSColor] = [.black, .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white]
    @objc private func showColors() {
        if colorPopover?.isShown == true { colorPopover?.close(); return }
        finishText(commit: true)
        let row = NSStackView(); row.spacing = 3; row.edgeInsets = NSEdgeInsets(top: 7, left: 7, bottom: 7, right: 7)
        for (index, ink) in Self.colors.enumerated() {
            let button = CaptureToolButton(.color, title: ["黑", "红", "橙", "黄", "绿", "蓝", "紫", "白"][index], target: self, action: #selector(chooseColor(_:)))
            button.ink = ink; button.tag = index; row.addArrangedSubview(button)
        }
        let controller = NSViewController(); controller.view = row
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        colorPopover = popover; popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .minY)
    }
    @objc private func chooseColor(_ sender: NSButton) {
        guard Self.colors.indices.contains(sender.tag) else { return }
        let ink = Self.colors[sender.tag]; canvas.ink = CaptureInk(ink); colorButton.ink = ink
        colorPopover?.close(); window.makeFirstResponder(canvas)
    }
    private func cancelCurrentOperation() {
        if canvas.cancelDraft() { return }
        close()
    }
    private func confirm() {
        if editingPin {
            guard beginExport() else { return }
            render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
                guard let self else { return }; self.onApply?(image); self.close()
            }
        } else { copyImage(closeAfter: true) }
    }
    @objc private func copyRecognizedText() {
        guard !closed, !exporting, recognition == nil else { return }
        finishText(commit: true)
        let request = CaptureTextRecognition.request(), base = canvas.base, marks = annotations, lifetime = lifetime
        recognition = request; recognitionButton.isEnabled = false
        showStatus("正在提取文字…")
        queue.async { [weak self] in
            let result: Result<String, Error> = autoreleasepool {
                guard lifetime.valid else { return .failure(CaptureFailure.cancelled) }
                return Result {
                    guard let image = CaptureAnnotationRenderer.render(base: base, annotations: marks, isCurrent: { lifetime.valid }) else {
                        throw CaptureFailure.cancelled
                    }
                    guard lifetime.valid else { throw CaptureFailure.cancelled }
                    return try CaptureTextRecognition.recognize(image, request: request)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, lifetime.valid, self.recognition === request else { return }
                self.recognition = nil; self.recognitionButton.isEnabled = true
                switch result {
                case .success(let text) where !text.isEmpty:
                    NSPasteboard.general.clearContents()
                    self.showStatus(NSPasteboard.general.setString(text, forType: .string) ? "文字已复制" : "复制失败")
                case .success: self.showStatus("未识别到文字")
                case .failure: self.showStatus("文字提取失败，请重试")
                }
            }
        }
    }
    private func showStatus(_ value: String) { status.stringValue = value; status.isHidden = value.isEmpty; positionToolbar() }

    private func remember() { undo.append(annotations); if undo.count > 60 { undo.removeFirst() }; redo.removeAll() }
    private func append(_ annotation: CaptureAnnotation) {
        guard annotations.count < 256 else { showStatus("标注数量已达 256，请撤销部分标注。"); return }
        remember(); annotations.append(annotation); refresh()
    }
    private func erase(_ point: CGPoint, _ radius: CGFloat) {
        guard let index = annotations.lastIndex(where: { $0.bounds.insetBy(dx: -radius, dy: -radius).contains(point) }) else { return }
        remember(); annotations.remove(at: index); refresh()
    }
    private func addText(_ point: CGPoint, _ width: CGFloat, _ ink: CaptureInk) {
        finishText(commit: true)
        let location = canvas.viewPoint(for: point)
        let input = SketchTextField(frame: CGRect(x: min(location.x, max(0, canvas.bounds.width - 80)),
            y: min(max(0, location.y - 4), max(0, canvas.bounds.height - 28)),
            width: min(280, max(80, canvas.bounds.width - location.x)), height: 28))
        input.font = .systemFont(ofSize: 15); input.placeholderString = "输入文字"
        input.delegate = self; input.setAccessibilityLabel("截图文字")
        canvas.addSubview(input); textInput = input
        textAnnotation = CaptureAnnotation(tool: .text, points: [point], ink: ink, width: width)
        window.makeFirstResponder(input)
    }
    private func finishText(commit: Bool) {
        guard let input = textInput else { return }
        let annotation = textAnnotation
        let value = String(input.stringValue.prefix(1000))
        textInput = nil; textAnnotation = nil; input.delegate = nil; input.removeFromSuperview()
        window.makeFirstResponder(canvas)
        if commit, !value.isEmpty, var annotation { annotation.text = value; append(annotation) }
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishText(commit: true) }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.insertNewline(_:)) { finishText(commit: true); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { finishText(commit: false); return true }
        return false
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
                else { self.showStatus("渲染失败，请缩小截图。"); onFailure?() }
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
                    guard let data else { self.showStatus("图像编码失败，未修改剪贴板。"); return }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setData(data, forType: .png) else { self.showStatus("复制失败。"); return }
                    self.onCopied?(); self.onExport?(); self.showStatus("已复制。")
                    if closeAfter { self.close() }
                }
            }
        }
    }
    func pinCurrentImage() {
        guard window.attachedSheet == nil else { return }
        editingPin ? confirm() : pinImage()
    }
    @objc private func pinImage() {
        guard beginExport() else { return }
        render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
            guard let self else { return }
            guard let pin = self.onPin else { self.exporting = false; self.showStatus("贴图不可用。"); return }
            // The owner closes us after the new pin is on screen, keeping the
            // frozen desktop in place through render/downsample/presentation.
            pin(image); self.onExport?()
        }
    }
    private func beginExport() -> Bool {
        guard !closed, !exporting else { return false }
        recognition?.cancel(); recognition = nil; recognitionButton.isEnabled = true
        finishText(commit: true)
        exporting = true; return true
    }
    @objc private func saveImage() {
        guard beginExport() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "截图.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.closed else { return }
            guard response == .OK, let url = panel.url else { self.exporting = false; self.showStatus("已取消。"); return }
            self.render(onFailure: { [weak self] in self?.exporting = false }) { [weak self] image in
                guard let self else { return }
                let lifetime = self.lifetime
                self.queue.async { [weak self] in
                    guard lifetime.valid else { return }
                    let saved = Self.writePNG(image, to: url)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.exporting = false
                        self.showStatus(saved ? "已保存。" : "保存失败，请检查目标文件夹。")
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
