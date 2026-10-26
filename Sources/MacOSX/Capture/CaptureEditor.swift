import AppKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import Vision

@MainActor
final class CaptureEditor: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private final class TextInput: NSTextView {
        var editableWidth: CGFloat = 44
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard local.x <= editableWidth else { return nil }
            return super.hitTest(point)
        }
    }
    /// An edit-only overlay. Only its border participates in hit testing;
    /// native text selection and input pass through the transparent interior.
    private final class TextEditingFrame: NSView {
        var onBegin: ((CGPoint) -> Void)?
        var onMove: ((CGPoint) -> Void)?
        var onEnd: (() -> Void)?
        var canTrackPointer: (() -> Bool)?
        var outlineRect = CGRect.zero
        var inputRect = CGRect.zero
        static let hitRadius: CGFloat = 8
        private var dragging = false
        private var borderRects: [CGRect] {
            let r = Self.hitRadius, rect = outlineRect
            return [CGRect(x: rect.minX-r,y: rect.minY-r,width: rect.width+r*2,height: r*2),
                    CGRect(x: rect.minX-r,y: rect.maxY-r,width: rect.width+r*2,height: r*2),
                    CGRect(x: rect.minX-r,y: rect.minY-r,width: r*2,height: rect.height+r*2),
                    CGRect(x: rect.maxX-r,y: rect.minY-r,width: r*2,height: rect.height+r*2)]
                .flatMap { band -> [CGRect] in
                    let band = band.intersection(bounds)
                    let interior = band.intersection(inputRect.insetBy(dx: 2,dy: 2))
                    guard !interior.isEmpty, !interior.isNull else { return [band] }
                    // A clipped border must not take over typing near image edges.
                    return [CGRect(x: band.minX,y: band.minY,width: band.width,height: interior.minY-band.minY),
                            CGRect(x: band.minX,y: interior.maxY,width: band.width,height: band.maxY-interior.maxY),
                            CGRect(x: band.minX,y: interior.minY,width: interior.minX-band.minX,height: interior.height),
                            CGRect(x: interior.maxX,y: interior.minY,width: band.maxX-interior.maxX,height: interior.height)]
                }.filter { !$0.isEmpty && !$0.isNull }
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point,from: superview)
            return borderRects.contains(where: { $0.contains(local) }) ? self : nil
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            for rect in borderRects { addCursorRect(rect,cursor: .openHand) }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            for rect in borderRects {
                addTrackingArea(NSTrackingArea(rect: rect,options: [.mouseEnteredAndExited,.activeInActiveApp],owner: self,userInfo: nil))
            }
        }
        private func refreshCursor(with event: NSEvent) {
            guard window != nil, canTrackPointer?() == true,
                  dragging || borderRects.contains(where: { $0.contains(convert(event.locationInWindow,from: nil)) }) else { return }
            (dragging ? NSCursor.closedHand : NSCursor.openHand).set()
        }
        override func mouseEntered(with event: NSEvent) { refreshCursor(with: event) }
        override func cursorUpdate(with event: NSEvent) { refreshCursor(with: event) }
        override func mouseDown(with event: NSEvent) {
            guard canTrackPointer?() == true else { return }
            dragging = true; NSCursor.closedHand.set(); onBegin?(event.locationInWindow)
        }
        override func mouseDragged(with event: NSEvent) {
            guard dragging, canTrackPointer?() == true else { return }
            onMove?(event.locationInWindow)
        }
        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            if canTrackPointer?() == true { onMove?(event.locationInWindow) }
            onEnd?(); refreshCursor(with: event)
        }
        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: outlineRect)
            NSColor.white.withAlphaComponent(0.85).setStroke(); path.lineWidth = 3; path.stroke()
            SketchPalette.blue.setStroke(); path.lineWidth = 1
            path.setLineDash([4,3],count: 2,phase: 0); path.stroke()
        }
    }
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
    private var annotationEditingSuspended = false
    private var suspendedTool: CaptureTool?
    private var ownsCursor = true
    private var localMonitor: Any?
    private var toolButtons = [CaptureToolButton]()
    private let canvas: CaptureCanvas
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.render", qos: .userInitiated)
    private let status = NSTextField(labelWithString: "Enter / ⌘C 复制")
    private var colorButton: CaptureToolButton!
    private var recognitionButton: CaptureToolButton!
    private var colorPopover: NSPopover?
    private var wheelRemainder: CGFloat = 0
    private var recognition: VNRecognizeTextRequest?
    private let editingPin: Bool
    private let defaults: UserDefaults
    private let clipboard: NSPasteboard
    private let textRecognizer: (CGImage, VNRecognizeTextRequest) throws -> String
    private var colorIndex: Int
    var onApply: ((CGImage) -> Void)?
    private var annotations: [CaptureAnnotation] = []
    private var undo: [[CaptureAnnotation]] = [], redo: [[CaptureAnnotation]] = []
    private var revision: UInt64 = 0
    private var closed = false
    private var exporting = false
    private var textInput: NSTextView?
    private var textLayout: CaptureTextLayout?
    private var textFirstLineHeight: CGFloat?
    private var textAnnotation: CaptureAnnotation?
    private var textEditingFrame: TextEditingFrame?
    private var textDrag: (pointer: CGPoint, anchor: CGPoint)?
    private let lifetime = CaptureImageService.Ticket()
    private var preview: CaptureImageService.Ticket?
    var onPin: ((CGImage) -> Void)?
    var onClose: (() -> Void)?

    var onExport: (() -> Void)?
    var onCopied: (() -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    private var adjustingRegion = false
    private var regionWasVisible = false
    var selectionFrame: CGRect { window.frame }
    var onReselect: (() -> Void)?
    var colorAtPointer: ((Bool) -> String?)?

    init(image: CGImage, selectionFrame: CGRect? = nil, editingPin: Bool = false, defaults: UserDefaults = .standard, clipboard: NSPasteboard = .general, textRecognizer: @escaping (CGImage, VNRecognizeTextRequest) throws -> String = CaptureTextRecognition.recognize) {
        self.editingPin = editingPin
        self.defaults = defaults
        self.clipboard = clipboard
        self.textRecognizer = textRecognizer
        let savedColor = (defaults.object(forKey: "capture.editor.color") as? NSNumber)?.intValue ?? 1
        colorIndex = Self.colors.indices.contains(savedColor) ? savedColor : 1
        canvas = CaptureCanvas(image: image)
        func restored(_ key: String, fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
            guard let number = defaults.object(forKey: key) as? NSNumber,
                  number.doubleValue.isFinite else { return fallback }
            return min(range.upperBound, max(range.lowerBound, CGFloat(number.doubleValue)))
        }
        canvas.lineWidth = restored("capture.editor.line-width", fallback: 3, range: 1...12)
        canvas.mosaicDiameter = restored("capture.editor.mosaic-diameter", fallback: 32, range: 8...160)
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
        window.acceptsMouseMovedEvents = true
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
        recognitionButton = CaptureToolButton(.recognition, title: editingPin ? "提取文字 · 6 / ⇧⌘C" : "提取文字 · ⌘T", target: self, action: #selector(copyRecognizedText))
        row.addArrangedSubview(recognitionButton)
        colorButton = CaptureToolButton(.color, title: "共用颜色 · 7", target: self, action: #selector(showColors))
        applyColor(colorIndex); row.addArrangedSubview(colorButton)
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
        canvas.onDraftBegan = { [weak self] in self?.cancelRecognition() }
        canvas.onErase = { [weak self] point, radius in self?.erase(point, radius) }
        canvas.onText = { [weak self] point, width, ink in self?.addText(point, width, ink) }
        canvas.onBackgroundClick = { [weak self] in
            guard let self, self.textInput != nil else { return false }
            self.finishText(commit: true); return true
        }
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
        updateSelectionInput()
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, !self.closed, self.window.attachedSheet == nil,
                          event.window === self.window || event.window === self.toolbar else { return false }
                    return event.type == .scrollWheel ? self.handleThicknessScroll(event) : self.handleSelectionKey(event)
                }
                return handled ? nil : event
            }
        }
    }
    // Selection backdrop owns pointer input while no annotation tool is active.
    @discardableResult func handleSelectionKey(_ event: NSEvent) -> Bool {
        guard !closed, !adjustingRegion, window.attachedSheet == nil else { return false }
        let screenshotCopy = !editingPin && event.keyCode == 8 &&
            event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command
        let screenshotRecognition = !editingPin && event.keyCode == 17 &&
            event.modifierFlags.intersection([.command,.control,.option,.shift]) == .command
        if textInput != nil && !screenshotCopy && !screenshotRecognition { return false }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 8 where command && event.modifierFlags.contains(.shift): copyRecognizedText()
        case 8 where command: copyImage(closeAfter: !editingPin)
        case 8 where event.modifierFlags.contains(.option):
            if let value = colorAtPointer?(event.modifierFlags.contains(.shift)) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                close()
            }
        case 1 where command: saveImage()
        case 17 where command: editingPin ? confirm() : copyRecognizedText()
        case 6 where command:
            if !annotationEditingSuspended { event.modifierFlags.contains(.shift) ? redoAction() : undoAction() }
        case 13 where command: close()
        case 15 where command && !editingPin: reselect()
        case 36, 76: confirm()
        case 53: cancelCurrentOperation()
        case 49 where event.modifierFlags.intersection([.command, .control, .option]).isEmpty:
            guard !event.isARepeat else { return true }
            if editingPin {
                confirm()
            } else {
                toggleAnnotationEditing()
            }
        default:
            guard !annotationEditingSuspended, !command, !event.modifierFlags.contains(.control),
                  let key = event.charactersIgnoringModifiers else { return false }
            if event.modifierFlags.contains(.option) {
                switch key {
                case "1": selectTool(.ellipse)
                case "3": selectTool(.highlighter)
                case "5": selectTool(.blur)
                default: return false
                }
            } else {
                switch key {
                case "1": selectTool(.rectangle)
                case "2": selectTool(.arrow)
                case "3": selectTool(.pen)
                case "4": selectTool(.text)
                case "5": selectTool(.mosaic)
                case "6": copyRecognizedText()
                case "7": showColors()
                case "e": selectTool(.eraser)
                case "[": adjustLineWidth(by: -1)
                case "]": adjustLineWidth(by: 1)
                default: return false
                }
            }
        }
        return true
    }
    private func toggleAnnotationEditing() {
        guard !closed, !exporting, !adjustingRegion else { return }
        if annotationEditingSuspended {
            annotationEditingSuspended = false; canvas.tool = suspendedTool; suspendedTool = nil
            toolbarVisible = true
        } else {
            finishText(commit: true); canvas.commitDraft(); cancelRecognition()
            colorPopover?.close(); wheelRemainder = 0
            suspendedTool = canvas.tool; canvas.tool = nil; annotationEditingSuspended = true
            toolbarVisible = false; toolbar.orderOut(nil)
        }
        updateToolButtons(); updateSelectionInput()
        if toolbarVisible, window.isVisible { positionToolbar() }
    }
    /// Only the active drawing tool consumes wheel input. No global listener or idle timer.
    func handleThicknessScroll(_ event: NSEvent) -> Bool {
        guard !closed, !exporting, !adjustingRegion, textInput == nil,
              let tool = canvas.tool, [.rectangle, .ellipse, .arrow, .pen, .highlighter, .mosaic].contains(tool),
              event.momentumPhase.isEmpty else { return false }
        if event.phase.contains(.began) { wheelRemainder = 0 }
        let delta = event.scrollingDeltaY * (event.isDirectionInvertedFromDevice ? -1 : 1)
        if event.hasPreciseScrollingDeltas {
            wheelRemainder = max(-96, min(96, wheelRemainder + delta))
            let steps = Int(max(-12, min(12, wheelRemainder / 8)))
            if steps != 0 { wheelRemainder -= CGFloat(steps) * 8; adjustLineWidth(by: steps) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) { wheelRemainder = 0 }
        } else if delta != 0 { adjustLineWidth(by: delta > 0 ? 1 : -1) }
        return true
    }
    private func adjustLineWidth(by steps: Int) {
        if canvas.tool == .mosaic {
            let diameter = max(8, min(160, canvas.mosaicDiameter + CGFloat(steps) * 4))
            guard diameter != canvas.mosaicDiameter else { return }
            canvas.mosaicDiameter = diameter
            defaults.set(Double(diameter), forKey: "capture.editor.mosaic-diameter")
            status.stringValue = "笔刷 \(Int(diameter)) · 滚轮调节"; status.isHidden = false
            toolButtons.forEach { $0.setAccessibilityValue("笔刷直径 \(Int(diameter))") }
            if window.isVisible { positionToolbar() }
            return
        }
        let width = max(1, min(12, canvas.lineWidth + CGFloat(steps)))
        guard width != canvas.lineWidth else { return }
        canvas.lineWidth = width
        defaults.set(Double(width), forKey: "capture.editor.line-width")
        status.stringValue = "粗细 \(Int(width)) · 滚轮调节"; status.isHidden = false
        toolButtons.forEach { $0.setAccessibilityValue("粗细 \(Int(width))") }
        if window.isVisible { positionToolbar() }
    }
    func copyCurrentImage() { guard !adjustingRegion else { return }; copyImage(closeAfter: !editingPin) }
    func activateEditing() {
        guard !editingPin, !closed, !exporting, !adjustingRegion else { return }
        if annotationEditingSuspended { toggleAnnotationEditing() }
    }
    func beginRegionAdjustment() {
        guard !editingPin, !closed, !exporting, !adjustingRegion else { return }
        regionWasVisible = window.isVisible
        adjustingRegion = true
        canvas.pointerActive = false; window.acceptsMouseMovedEvents = false
        cancelRecognition()
        revision &+= 1; preview?.cancel()
        window.orderOut(nil); toolbar.orderOut(nil)
    }
    func replaceSelectionImage(_ image: CGImage, at region: CGRect) {
        guard !closed, !editingPin, !exporting else { return }
        let old = window.frame, oldPixels = CGSize(width: canvas.base.width, height: canvas.base.height)
        let newPixels = CGSize(width: image.width, height: image.height)
        func remap(_ marks: [CaptureAnnotation]) -> [CaptureAnnotation] {
            marks.map { $0.reframed(from: old, pixels: oldPixels, to: region, pixels: newPixels) }
        }
        annotations = remap(annotations); undo = undo.map(remap); redo = redo.map(remap)
        canvas.base = image; canvas.image = image
        window.setFrame(region, display: false); adjustingRegion = false
        if regionWasVisible || window.isVisible { window.orderFrontRegardless(); positionToolbar() }
        regionWasVisible = false; refresh(); updateSelectionInput()
    }
    private func updateSelectionInput() {
        canvas.inputEnabled = !closed && !exporting && !adjustingRegion && !annotationEditingSuspended
        let nextOwner = canvas.inputEnabled && (editingPin || canvas.tool != nil)
        canvas.pointerActive = nextOwner
        window.acceptsMouseMovedEvents = nextOwner
        if nextOwner != ownsCursor {
            ownsCursor = nextOwner
            if nextOwner { window.enableCursorRects() } else { window.disableCursorRects() }
        }
        guard !editingPin else { return }
        let editing = canvas.tool != nil
        window.ignoresMouseEvents = !editing
        onEditingChanged?(editing)
        if editing, window.isVisible { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(canvas) }
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
        canvas.pointerActive = false; canvas.inputEnabled = false
        canvas.cancelDraft(); canvas.closeBrushPreview(); window.acceptsMouseMovedEvents = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        recognition?.cancel(); recognition = nil
        colorPopover?.close(); colorPopover = nil
        toolbar.orderOut(nil); toolbar.close()
        textInput?.delegate = nil; textInput?.removeFromSuperview(); textInput = nil; textAnnotation = nil; textLayout = nil; textFirstLineHeight = nil
        textEditingFrame?.removeFromSuperview(); textEditingFrame = nil; textDrag = nil
        let callback = onClose; onClose = nil; onExport = nil; onCopied = nil; onPin = nil
        onEditingChanged = nil; onReselect = nil; colorAtPointer = nil; onApply = nil; callback?()
    }
    private func updateToolButtons() { for button in toolButtons { button.state = button.tag == canvas.tool?.rawValue ? .on : .off } }
    @objc private func changeTool(_ sender: NSButton) {
        guard let tool = CaptureTool(rawValue: sender.tag) else { return }
        selectTool(tool)
    }
    @objc private func reselect() { guard !exporting else { return }; onReselect?() }
    private func selectTool(_ tool: CaptureTool) {
        guard !closed, !exporting, !adjustingRegion, !annotationEditingSuspended else { return }
        finishText(commit: true); canvas.cancelDraft(); wheelRemainder = 0
        canvas.tool = canvas.tool == tool ? nil : tool
        if status.stringValue.hasPrefix("笔刷 ") || (status.stringValue.hasPrefix("粗细 ") && (canvas.tool == nil || canvas.tool == .text || canvas.tool == .mosaic || canvas.tool == .blur || canvas.tool == .eraser)) {
            status.stringValue = ""; status.isHidden = true
        }
        updateToolButtons(); updateSelectionInput()
        if editingPin { window.makeFirstResponder(canvas) }
    }
    private static let colorNames = ["黑", "红", "橙", "黄", "绿", "蓝", "紫", "白"]
    private static let colors: [NSColor] = [SketchPalette.ink, SketchPalette.coral, SketchPalette.orange, SketchPalette.yellow, SketchPalette.green, SketchPalette.blue, SketchPalette.purple, .white]
    @objc private func showColors() {
        if colorPopover?.isShown == true { colorPopover?.close(); return }
        finishText(commit: true)
        let controller = NSViewController()
        controller.view = CaptureColorPalette(colors: Self.colors, selected: colorButton.ink, target: self, action: #selector(chooseColor(_:)))
        controller.preferredContentSize = controller.view.frame.size
        let popover = NSPopover(); popover.behavior = .transient; popover.contentViewController = controller
        colorPopover = popover; popover.show(relativeTo: colorButton.bounds, of: colorButton, preferredEdge: .minY)
    }
    @objc private func chooseColor(_ sender: NSButton) {
        guard Self.colors.indices.contains(sender.tag) else { return }
        if colorIndex != sender.tag {
            colorIndex = sender.tag
            defaults.set(colorIndex, forKey: "capture.editor.color")
        }
        applyColor(colorIndex)
        colorPopover?.close()
        window.makeFirstResponder(canvas)
    }
    private func applyColor(_ index: Int) {
        let ink = Self.colors[index]; canvas.ink = CaptureInk(ink); colorButton.ink = ink
        let description = "调色盘 · 当前：\(Self.colorNames[index]) · 7"
        colorButton.toolTip = description; colorButton.setAccessibilityLabel(description)
        toolButtons.forEach { $0.ink = ink }
    }
    private func cancelCurrentOperation() {
        if exporting { close(); return }
        if canvas.cancelDraft() { return }
        if !editingPin, canvas.tool != nil {
            finishText(commit: true); canvas.tool = nil; updateToolButtons(); updateSelectionInput(); return
        }
        close()
    }
    private func confirm() {
        if editingPin {
            guard beginExport() else { return }
            render(onFailure: { [weak self] in self?.exporting = false; self?.updateSelectionInput() }) { [weak self] image in
                guard let self else { return }; self.onApply?(image); self.close()
            }
        } else { copyImage(closeAfter: true) }
    }
    @objc func copyRecognizedText() {
        guard !closed, !exporting, recognition == nil else { return }
        finishText(commit: true)
        canvas.commitDraft()
        let request = CaptureTextRecognition.request(), base = canvas.base, marks = annotations, lifetime = lifetime, recognize = textRecognizer
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
                    return try recognize(image, request)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, lifetime.valid, self.recognition === request else { return }
                self.recognition = nil; self.recognitionButton.isEnabled = true
                switch result {
                case .success(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                    self.clipboard.clearContents()
                    guard self.clipboard.setString(text, forType: .string) else { self.showStatus("复制失败"); return }
                    self.showStatus("文字已复制")
                    if !self.editingPin { self.close() }
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
        var annotation = CaptureAnnotation(tool: .text, points: [point], ink: ink, width: width)
        let lineHeight = CaptureTextLayout(annotation: annotation).size.height
        annotation.points = [CGPoint(x: min(point.x, max(0, CGFloat(canvas.base.width) - max(18, width * 7))),
                                     y: min(CGFloat(canvas.base.height),max(min(lineHeight, CGFloat(canvas.base.height)), point.y + lineHeight / 2)))]
        annotation.textLayoutWidth = max(1, CGFloat(canvas.base.width) - annotation.points[0].x)
        let layout = CaptureTextLayout(annotation: annotation)
        let input = TextInput(frame: .zero, textContainer: layout.container)
        input.isRichText = false; input.importsGraphics = false; input.usesFontPanel = false; input.allowsUndo = true
        input.drawsBackground = false; input.backgroundColor = .clear; input.focusRingType = .none
        input.textContainerInset = .zero
        input.isHorizontallyResizable = false; input.isVerticallyResizable = false
        layout.container.widthTracksTextView = false; layout.container.heightTracksTextView = false
        input.font = layout.attributes[.font] as? NSFont
        input.textColor = layout.attributes[.foregroundColor] as? NSColor
        input.defaultParagraphStyle = layout.attributes[.paragraphStyle] as? NSParagraphStyle
        input.typingAttributes = layout.attributes
        input.insertionPointColor = input.textColor ?? .black
        input.delegate = self; input.setAccessibilityLabel("截图文字")
        canvas.addSubview(input); textInput = input; textLayout = layout; textAnnotation = annotation; textFirstLineHeight = lineHeight
        let frameView = TextEditingFrame(frame: .zero)
        frameView.canTrackPointer = { [weak canvas] in canvas?.pointerActive == true && canvas?.inputEnabled == true }
        frameView.toolTip = "拖动边框移动文字 · 点击框外完成编辑"
        frameView.setAccessibilityLabel("文字编辑边框，可拖动")
        frameView.onBegin = { [weak self] point in
            guard let self, let anchor = self.textAnnotation?.points.first else { return }
            self.textDrag = (point, anchor)
        }
        frameView.onMove = { [weak self] point in self?.moveText(to: point) }
        frameView.onEnd = { [weak self] in self?.textDrag = nil }
        canvas.addSubview(frameView); textEditingFrame = frameView
        layoutTextInput()
        window.makeFirstResponder(input)
    }
    private func layoutTextInput() {
        guard let input = textInput, let layout = textLayout, var annotation = textAnnotation,
              var anchor = annotation.points.first else { return }
        let lineHeight = layout.firstLineHeight
        if let previous = textFirstLineHeight {
            // CJK/emoji fallback can enlarge the first line after typing.
            // Keep its centre at the original click without changing TextKit.
            anchor.y = min(CGFloat(canvas.base.height),max(min(lineHeight,CGFloat(canvas.base.height)),anchor.y + (lineHeight-previous)/2))
            annotation.points[0] = anchor; textAnnotation = annotation
        }
        textFirstLineHeight = lineHeight
        let location = canvas.viewPoint(for: anchor), scale = canvas.scale
        let size = CGSize(width: layout.container.size.width, height: min(anchor.y, layout.size.height + 1))
        input.frame = CGRect(x: location.x, y: location.y - size.height * scale,
                             width: size.width * scale, height: size.height * scale)
        input.bounds = CGRect(origin: .zero, size: size)
        let textWidth = min(input.frame.width,max(44,(layout.size.width + 6) * scale))
        (input as? TextInput)?.editableWidth = textWidth / max(0.01,scale)
        let textRect = CGRect(x: input.frame.minX,y: input.frame.minY,width: textWidth,height: input.frame.height)
        // Padding belongs to the overlay only; glyph coordinates, wrapping and
        // exported pixels remain exactly those of the transparent NSTextView.
        if let frame = textEditingFrame {
            let inset = min(1.5,canvas.bounds.width/4,canvas.bounds.height/4)
            let outline = textRect.insetBy(dx: -10,dy: -10).intersection(canvas.bounds.insetBy(dx: inset,dy: inset))
            frame.frame = outline.insetBy(dx: -TextEditingFrame.hitRadius,dy: -TextEditingFrame.hitRadius).intersection(canvas.bounds)
            frame.outlineRect = outline.offsetBy(dx: -frame.frame.minX,dy: -frame.frame.minY)
            frame.inputRect = textRect.offsetBy(dx: -frame.frame.minX,dy: -frame.frame.minY)
            frame.updateTrackingAreas(); frame.needsDisplay = true
        }
        window.invalidateCursorRects(for: textEditingFrame ?? input)
    }
    private func moveText(to pointer: CGPoint) {
        guard let drag = textDrag, var annotation = textAnnotation, let layout = textLayout else { return }
        let scale = max(0.01,canvas.scale), size = layout.size
        annotation.points = [CGPoint(
            x: min(max(0,CGFloat(canvas.base.width) - size.width),max(0,drag.anchor.x + (pointer.x - drag.pointer.x) / scale)),
            y: min(CGFloat(canvas.base.height),max(min(size.height,CGFloat(canvas.base.height)),drag.anchor.y + (pointer.y - drag.pointer.y) / scale)))]
        textAnnotation = annotation; layoutTextInput()
    }
    func textDidChange(_ notification: Notification) {
        guard let input = textInput, notification.object as? NSTextView === input else { return }
        if !input.hasMarkedText(), input.string.count > 1000 {
            input.string = String(input.string.prefix(1000))
            input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        }
        layoutTextInput()
    }
    private func finishText(commit: Bool) {
        guard let input = textInput else { return }
        let annotation = textAnnotation
        let value = String(input.string.prefix(1000))
        textInput = nil; textAnnotation = nil; textLayout = nil; textFirstLineHeight = nil; input.delegate = nil; input.removeFromSuperview()
        textEditingFrame?.removeFromSuperview(); textEditingFrame = nil; textDrag = nil
        window.makeFirstResponder(canvas)
        if commit, !value.isEmpty, var annotation { annotation.text = value; append(annotation) }
    }
    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === textInput else { return }
        finishText(commit: true)
    }
    func textView(_ textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        if command == #selector(NSResponder.insertNewline(_:)) { finishText(commit: true); return true }
        if command == #selector(NSResponder.cancelOperation(_:)) { finishText(commit: false); return true }
        return false
    }
    @objc private func undoAction() {
        guard !closed, !exporting else { return }
        if canvas.cancelDraft() { return }
        guard let previous = undo.popLast() else { return }
        redo.append(annotations); annotations = previous; refresh()
    }
    @objc private func redoAction() {
        guard !closed, !exporting else { return }
        if canvas.cancelDraft() { return }
        guard let next = redo.popLast() else { return }
        undo.append(annotations); annotations = next; refresh()
    }
    private func refresh() {
        cancelRecognition()
        revision &+= 1; let expected = revision
        preview?.cancel()
        let ticket = CaptureImageService.Ticket(); preview = ticket
        render(ticket: ticket) { [weak self] image in
            guard let self, self.revision == expected else { return }
            self.canvas.image = image
        }
    }
    private func cancelRecognition() {
        let wasRecognizing = recognition != nil
        recognition?.cancel(); recognition = nil; recognitionButton.isEnabled = true
        if wasRecognizing, status.stringValue == "正在提取文字…" { showStatus("") }
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
        render(onFailure: { [weak self] in self?.exporting = false; self?.updateSelectionInput() }) { [weak self] image in
            guard let self else { return }
            let lifetime = self.lifetime
            self.queue.async { [weak self] in
                guard lifetime.valid else { return }
                let data = Self.pngData(image)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.closed else { return }
                    self.exporting = false; self.updateSelectionInput()
                    guard let data else { self.showStatus("图像编码失败，未修改剪贴板。"); return }
                    self.clipboard.clearContents()
                    guard self.clipboard.setData(data, forType: .png) else { self.showStatus("复制失败。"); return }
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
    /// Uses exactly the same committed draft/render as copy and F3. A failed
    /// persistence attempt restores editing rather than discarding the image.
    func renderForShelf(_ save: @escaping (CGImage, @escaping (Bool) -> Void) -> Void) {
        guard window.attachedSheet == nil, beginExport() else { return }
        render(onFailure: { [weak self] in self?.exporting = false; self?.updateSelectionInput() }) { [weak self] image in
            guard let self else { return }
            save(image) { [weak self] saved in
                guard let self, !self.closed else { return }
                self.exporting = false; self.updateSelectionInput()
                if saved { self.onExport?(); self.close() }
                else { self.showStatus("收纳失败，图片已保留，可重试。") }
            }
        }
    }
    @objc private func pinImage() {
        guard beginExport() else { return }
        render(onFailure: { [weak self] in self?.exporting = false; self?.updateSelectionInput() }) { [weak self] image in
            guard let self else { return }
            guard let pin = self.onPin else { self.exporting = false; self.updateSelectionInput(); self.showStatus("贴图不可用。"); return }
            // The owner closes us after the new pin is on screen, keeping the
            // frozen desktop in place through render/downsample/presentation.
            pin(image); self.onExport?()
        }
    }
    private func beginExport() -> Bool {
        guard !closed, !exporting, !adjustingRegion else { return false }
        cancelRecognition()
        finishText(commit: true)
        canvas.commitDraft()
        exporting = true; canvas.inputEnabled = false; canvas.pointerActive = false; onEditingChanged?(true); return true
    }
    @objc private func saveImage() {
        guard beginExport() else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "截图.png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.closed else { return }
            guard response == .OK, let url = panel.url else { self.exporting = false; self.updateSelectionInput(); self.showStatus("已取消。"); return }
            self.render(onFailure: { [weak self] in self?.exporting = false; self?.updateSelectionInput() }) { [weak self] image in
                guard let self else { return }
                let lifetime = self.lifetime
                self.queue.async { [weak self] in
                    guard lifetime.valid else { return }
                    let saved = Self.writePNG(image, to: url)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.exporting = false; self.updateSelectionInput()
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
