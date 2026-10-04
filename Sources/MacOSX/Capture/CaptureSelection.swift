import AppKit

@MainActor final class CaptureSelection: NSObject {
    enum Result { case copy(CGRect), pin(CGRect), edit(CGRect), color(String), cancel }
    private final class Panel: NSPanel {
        var acceptsSelectionInput = true
        var onKey: ((NSEvent) -> Bool)?
        var onCopy: (() -> Void)?
        var onSelectAll: (() -> Void)?
        override var canBecomeKey: Bool { acceptsSelectionInput }
        override var canBecomeMain: Bool { false }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.contains(.command), onKey?(event) == true { return true }
            return super.performKeyEquivalent(with: event)
        }
        @objc func copy(_ sender: Any?) { onCopy?() }
        override func selectAll(_ sender: Any?) { onSelectAll?() }
    }
    private final class ToolbarPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private enum Drag { case create(CGPoint), move(CGPoint, CGRect), resize(Int, CGPoint, CGRect) }
    private var panels = [NSPanel](), views = [SelectionView]()
    private var frames = [CaptureFrame]()
    private var toolbar: NSPanel?
    private var selection = CGRect.null
    private var previousRegion: CGRect?
    private var candidates = [CGRect]()
    private var drag: Drag?
    private var spaceDown = false
    private var spaceAnchor = CGPoint.zero
    private var spaceRegion = CGRect.null
    private var pointer = CGPoint.zero
    private var option = false, shiftDown = false, rgbFormat = false
    private var candidateIndex = 0
    private var completion: ((Result) -> Void)?
    private var acceptsInput = false
    private(set) var selectedTool: CaptureTool = .rectangle

    func present(_ frames: [CaptureFrame], previousRegion: CGRect? = nil, windows: [CGRect] = [],
                 completion: @escaping (Result) -> Void) {
        dismiss()
        self.frames = Array(frames.prefix(16)); self.previousRegion = previousRegion
        self.completion = completion; selectedTool = .rectangle
        acceptsInput = true
        pointer = NSEvent.mouseLocation
        option = NSEvent.modifierFlags.contains(.option); shiftDown = NSEvent.modifierFlags.contains(.shift)
        rgbFormat = false; candidateIndex = 0
        candidates = windows.prefix(256).map { CaptureSelectionGeometry.clamped($0, to: desktop) }.filter { !$0.isNull }
        guard !self.frames.isEmpty else { finish(.cancel); return }
        for frame in self.frames {
            let panel = Panel(contentRect: frame.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.title = "截图"
            panel.onKey = { [weak self] in self?.keyDown($0) ?? false }
            panel.onCopy = { [weak self] in self?.copyPressed() }
            panel.onSelectAll = { [weak self] in self?.selectFullScreen() }
            panel.level = .screenSaver; panel.isOpaque = true; panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false; panel.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: CGRect(origin: .zero, size: frame.screen.frame.size), snapshot: frame)
            view.region = { [weak self] in self?.visibleRegion ?? .null }
            view.pointer = { [weak self] in self?.pointer ?? .zero }
            view.magnifierVisible = { [weak self] in self?.magnifierVisible ?? false }
            view.rgbFormat = { [weak self] in self?.rgbFormat ?? false }
            view.onPointer = { [weak self] in self?.pointerMoved($0) }
            view.onDown = { [weak self] point, twice in self?.mouseDown(point, twice: twice) }
            view.onDrag = { [weak self] in self?.mouseDragged($0) }
            view.onUp = { [weak self] in self?.mouseUp($0) }
            view.onReset = { [weak self] in self?.resetOrCancel() }
            view.onKey = { [weak self] in self?.keyDown($0) ?? false }
            view.onFlags = { [weak self] in self?.flagsChanged($0) }
            view.onKeyUp = { [weak self] in if $0.keyCode == 49 { self?.releaseSpace() } }
            panel.contentView = view; panel.makeFirstResponder(view); panel.orderFrontRegardless()
            panels.append(panel); views.append(view)
        }
        let index = self.frames.firstIndex { $0.screen.frame.contains(pointer) } ?? 0
        panels[index].makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        completion = nil; acceptsInput = false
        toolbar?.orderOut(nil); toolbar?.close(); toolbar = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll(); views.removeAll(); frames.removeAll(); candidates.removeAll()
        drag = nil; spaceDown = false; spaceRegion = .null; selection = .null; previousRegion = nil
    }

    func pinCurrentSelection() {
        guard acceptsInput, let region = validRegion() else { return }
        finish(.pin(region))
    }

    private var desktop: CGRect { frames.reduce(.null) { $0.union($1.screen.frame) } }
    private var hovered: CGRect { candidates.first { $0.contains(pointer) } ?? .null }
    private var visibleRegion: CGRect { selection.isNull ? hovered : selection }
    private var magnifierVisible: Bool { acceptsInput && (option || selection.isNull || drag != nil) }
    private func step(at point: CGPoint) -> CGSize {
        guard let frame = frames.first(where: { $0.screen.frame.contains(point) }) ?? frames.first else { return CGSize(width: 1, height: 1) }
        return CGSize(width: frame.screen.frame.width / CGFloat(frame.image.width), height: frame.screen.frame.height / CGFloat(frame.image.height))
    }
    private func redraw() { views.forEach { $0.needsDisplay = true } }
    private func pointerMoved(_ point: CGPoint) { guard acceptsInput else { return }; pointer = point; redraw() }
    private func finish(_ result: Result) {
        guard acceptsInput else { return }
        let callback = completion
        if case .edit = result {
            // The editor sits above this frozen desktop until its owner dismisses us.
            completion = nil; acceptsInput = false; drag = nil; spaceDown = false; spaceRegion = .null
            toolbar?.orderOut(nil); toolbar?.close(); toolbar = nil
            for panel in panels { (panel as? Panel)?.acceptsSelectionInput = false; panel.acceptsMouseMovedEvents = false }
            redraw()
        } else { dismiss() }
        callback?(result)
    }
    private func validRegion() -> CGRect? {
        let value = CaptureSelectionGeometry.clamped(visibleRegion, to: desktop), unit = step(at: pointer)
        return !value.isNull && value.width >= unit.width && value.height >= unit.height ? value : nil
    }

    private func mouseDown(_ point: CGPoint, twice: Bool) {
        guard acceptsInput else { return }
        pointer = point
        if twice, let region = validRegion() { finish(.copy(region)); return }
        toolbar?.orderOut(nil)
        if !selection.isNull, let handle = SelectionView.handles(selection).firstIndex(where: { $0.insetBy(dx: -4, dy: -4).contains(point) }) {
            drag = .resize(handle, point, selection)
        } else if !selection.isNull, selection.contains(point) { drag = .move(point, selection) }
        else { drag = .create(point); selection = .null }
        redraw()
    }
    private func mouseDragged(_ point: CGPoint) {
        guard acceptsInput else { return }
        pointer = point
        if spaceDown, drag != nil, !spaceRegion.isNull {
            selection = CaptureSelectionGeometry.moved(spaceRegion, dx: point.x - spaceAnchor.x, dy: point.y - spaceAnchor.y, in: desktop)
            redraw(); return
        }
        switch drag {
        case let .create(start):
            selection = CaptureSelectionGeometry.clamped(CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                    width: abs(start.x - point.x), height: abs(start.y - point.y)), to: desktop)
        case let .move(start, original):
            selection = CaptureSelectionGeometry.moved(original, dx: point.x - start.x, dy: point.y - start.y, in: desktop)
        case let .resize(handle, start, original):
            let dx = point.x - start.x, dy = point.y - start.y
            var x0 = original.minX, x1 = original.maxX, y0 = original.minY, y1 = original.maxY
            if [0, 6, 7].contains(handle) { x0 += dx }; if [2, 3, 4].contains(handle) { x1 += dx }
            if [0, 1, 2].contains(handle) { y0 += dy }; if [4, 5, 6].contains(handle) { y1 += dy }
            selection = CaptureSelectionGeometry.clamped(CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)), to: desktop)
        case nil: return
        }
        redraw()
    }
    private func mouseUp(_ point: CGPoint) {
        guard let drag else { return }
        mouseDragged(point)
        if case let .create(start) = drag, hypot(point.x - start.x, point.y - start.y) < 3 { selection = hovered }
        self.drag = nil
        spaceDown = false; spaceRegion = .null
        let unit = step(at: point)
        if !selection.isNull && (selection.width < unit.width || selection.height < unit.height) { selection = .null }
        redraw(); showToolbar()
    }
    private func resetOrCancel() {
        guard acceptsInput else { return }
        if !selection.isNull || drag != nil { selection = .null; drag = nil; toolbar?.orderOut(nil); redraw() }
        else { finish(.cancel) }
    }
    private func releaseSpace() {
        guard spaceDown else { return }
        let dx = selection.isNull || spaceRegion.isNull ? 0 : selection.minX - spaceRegion.minX
        let dy = selection.isNull || spaceRegion.isNull ? 0 : selection.minY - spaceRegion.minY
        switch drag {
        case let .create(start): drag = .create(CGPoint(x: start.x + dx, y: start.y + dy))
        case .move: drag = .move(pointer, selection)
        case let .resize(handle, _, _): drag = .resize(handle, pointer, selection)
        case nil: break
        }
        spaceDown = false; spaceRegion = .null
    }
    private func selectFullScreen() {
        guard acceptsInput else { return }
        if let frame = frames.first(where: { $0.screen.frame.contains(pointer) }) ?? frames.first {
            selection = selection == frame.screen.frame && frames.count > 1 ? desktop : frame.screen.frame
            drag = nil; spaceDown = false; spaceRegion = .null; redraw(); showToolbar()
        }
    }
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        guard acceptsInput else { return }
        option = flags.contains(.option)
        let nextShift = flags.contains(.shift)
        if nextShift && !shiftDown && magnifierVisible { rgbFormat.toggle() }
        shiftDown = nextShift; redraw()
    }
    private func keyDown(_ event: NSEvent) -> Bool {
        guard acceptsInput else { return false }
        let command = event.modifierFlags.contains(.command), shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: finish(.cancel)
        case 36, 76: if let region = validRegion() { finish(.copy(region)) }
        case 8 where command: if let region = validRegion() { finish(.copy(region)) }
        case 8:
            if magnifierVisible, let frame = frames.first(where: { $0.screen.frame.contains(pointer) }),
               let sample = frame.sampler?.sample(globalPoint: pointer, in: frame.screen.frame) {
                finish(.color(rgbFormat ? sample.rgb : sample.hex))
            }
        case 17 where command: pinCurrentSelection()
        case 0 where command: selectFullScreen()
        case 15 where !command:
            if let previousRegion { selection = CaptureSelectionGeometry.clamped(previousRegion, to: desktop); drag = nil; redraw(); showToolbar() }
        case 48:
            let matches = candidates.filter { $0.contains(pointer) }
            let choices = matches.isEmpty ? candidates : matches
            if !choices.isEmpty {
                candidateIndex = (candidateIndex + (shift ? choices.count - 1 : 1)) % choices.count
                selection = choices[candidateIndex]; drag = nil; redraw(); showToolbar()
            }
        case 49:
            if drag != nil {
                if !spaceDown { spaceDown = true; spaceAnchor = pointer; spaceRegion = selection }
            } else if let region = validRegion() { selectedTool = .rectangle; finish(.edit(region)) }
        case 123...126:
            guard let region = validRegion() else { return true }
            let unit = step(at: CGPoint(x: region.midX, y: region.midY))
            if command || shift { selection = CaptureSelectionGeometry.adjusted(region, key: event.keyCode, enlarge: command, step: unit, in: desktop) }
            else { selection = CaptureSelectionGeometry.moved(region,
                dx: event.keyCode == 123 ? -unit.width : event.keyCode == 124 ? unit.width : 0,
                dy: event.keyCode == 125 ? -unit.height : event.keyCode == 126 ? unit.height : 0, in: desktop) }
            drag = nil; redraw(); showToolbar()
        default: return false
        }
        return true
    }

    private func showToolbar() {
        guard drag == nil, !selection.isNull else { toolbar?.orderOut(nil); return }
        if toolbar == nil {
            let panel = ToolbarPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "截图工具"
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let background = NSVisualEffectView(); background.material = .hudWindow; background.state = .active
            background.wantsLayer = true; background.layer?.cornerRadius = 9
            let row = NSStackView(); row.spacing = 3; row.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
            for (tool, symbol, title) in [(CaptureTool.rectangle, "rectangle", "矩形"), (.arrow, "arrow.up.right", "箭头"),
                (.pen, "pencil.tip", "画笔"), (.text, "textformat", "文字"), (.mosaic, "square.grid.3x3", "马赛克")] {
                let button = icon(symbol, title: title, action: #selector(editPressed(_:))); button.tag = tool.rawValue; row.addArrangedSubview(button)
            }
            for (symbol, title, action) in [("pin", "贴图 ⌘T", #selector(pinPressed)), ("doc.on.doc", "复制 Enter / ⌘C", #selector(copyPressed)),
                ("xmark", "取消 Esc", #selector(cancelPressed))] { row.addArrangedSubview(icon(symbol, title: title, action: action)) }
            row.translatesAutoresizingMaskIntoConstraints = false; background.addSubview(row)
            NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: background.leadingAnchor), row.trailingAnchor.constraint(equalTo: background.trailingAnchor),
                row.topAnchor.constraint(equalTo: background.topAnchor), row.bottomAnchor.constraint(equalTo: background.bottomAnchor)])
            panel.contentView = background; toolbar = panel
        }
        guard let toolbar else { return }
        let area = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: selection.midX, y: selection.midY)) })?.visibleFrame
            ?? frames.first?.screen.frame ?? desktop
        let size = toolbar.contentView?.fittingSize ?? CGSize(width: 270, height: 36)
        let x = min(max(area.minX + 6, selection.maxX - size.width), area.maxX - size.width - 6)
        let preferredY = selection.minY - size.height - 8
        let y = preferredY >= area.minY + 6 ? preferredY : min(area.maxY - size.height - 6, selection.maxY + 8)
        toolbar.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true); toolbar.orderFrontRegardless()
    }
    private func icon(_ symbol: String, title: String, action: Selector) -> NSButton {
        let button = MinimalButton(title: "", target: self, action: action, style: .quiet)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        button.imagePosition = .imageOnly; button.toolTip = title; button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true; button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
    @objc private func editPressed(_ sender: NSButton) { if let region = validRegion() { selectedTool = CaptureTool(rawValue: sender.tag) ?? .rectangle; finish(.edit(region)) } }
    @objc private func copyPressed() { if let region = validRegion() { finish(.copy(region)) } }
    @objc private func pinPressed() { pinCurrentSelection() }
    @objc private func cancelPressed() { finish(.cancel) }
}

@MainActor private final class SelectionView: NSView {
    private let snapshot: CaptureFrame
    private let displayImage: NSImage
    private var tracking: NSTrackingArea?
    var region: (() -> CGRect)?
    var pointer: (() -> CGPoint)?
    var magnifierVisible: (() -> Bool)?
    var rgbFormat: (() -> Bool)?
    var onPointer: ((CGPoint) -> Void)?
    var onDown: ((CGPoint, Bool) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onUp: ((CGPoint) -> Void)?
    var onReset: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onFlags: ((NSEvent.ModifierFlags) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect, snapshot: CaptureFrame) {
        self.snapshot = snapshot; displayImage = NSImage(cgImage: snapshot.image, size: snapshot.screen.frame.size)
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        tracking = area; addTrackingArea(area)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    private func global(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? .zero }
    override func mouseMoved(with event: NSEvent) { onPointer?(global(event)) }
    override func mouseDown(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self); onDown?(global(event), event.clickCount == 2) }
    override func mouseDragged(with event: NSEvent) { onDrag?(global(event)) }
    override func mouseUp(with event: NSEvent) { onUp?(global(event)) }
    override func rightMouseDown(with event: NSEvent) { onReset?() }
    override func flagsChanged(with event: NSEvent) { onFlags?(event.modifierFlags) }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
    override func keyUp(with event: NSEvent) { onKeyUp?(event) }
    static func handles(_ rect: CGRect) -> [CGRect] {
        [(rect.minX, rect.minY), (rect.midX, rect.minY), (rect.maxX, rect.minY), (rect.maxX, rect.midY),
         (rect.maxX, rect.maxY), (rect.midX, rect.maxY), (rect.minX, rect.maxY), (rect.minX, rect.midY)]
            .map { CGRect(x: $0.0 - 3, y: $0.1 - 3, width: 6, height: 6) }
    }
    override func draw(_ dirtyRect: NSRect) {
        displayImage.draw(in: bounds)
        let globalRegion = region?() ?? .null, overlap = globalRegion.intersection(snapshot.screen.frame)
        let local = overlap.offsetBy(dx: -snapshot.screen.frame.minX, dy: -snapshot.screen.frame.minY)
        let shade = NSBezierPath(rect: bounds); if !overlap.isNull { shade.appendRect(local) }
        shade.windingRule = .evenOdd; NSColor.black.withAlphaComponent(0.3).setFill(); shade.fill()
        if !overlap.isNull {
            NSColor.white.setStroke(); let outline = NSBezierPath(rect: local); outline.lineWidth = 1; outline.stroke()
            for handle in Self.handles(globalRegion) {
                let rect = handle.offsetBy(dx: -snapshot.screen.frame.minX, dy: -snapshot.screen.frame.minY)
                NSColor.white.setFill(); rect.fill(); NSColor.controlAccentColor.setStroke(); NSBezierPath(rect: rect).stroke()
            }
            label("\(Int((globalRegion.width * CGFloat(snapshot.image.width) / snapshot.screen.frame.width).rounded())) × \(Int((globalRegion.height * CGFloat(snapshot.image.height) / snapshot.screen.frame.height).rounded()))",
                  at: CGPoint(x: max(8, local.minX), y: min(bounds.maxY - 26, local.maxY + 6)))
        }
        let point = pointer?() ?? .zero
        if magnifierVisible?() == true, snapshot.screen.frame.contains(point),
           let sampler = snapshot.sampler, let sample = sampler.sample(globalPoint: point, in: snapshot.screen.frame), let patch = sampler.magnifier(sample: sample) {
            let cursor = CGPoint(x: point.x - snapshot.screen.frame.minX, y: point.y - snapshot.screen.frame.minY)
            let box = CGRect(x: min(max(8, cursor.x + 22), bounds.maxX - 162), y: min(max(8, cursor.y - 196), bounds.maxY - 192), width: 154, height: 184)
            NSColor.black.withAlphaComponent(0.88).setFill(); NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
            let pixels = CGRect(x: box.minX + 11, y: box.maxY - 143, width: 132, height: 132)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: patch, size: CGSize(width: 11, height: 11)).draw(in: pixels)
            NSColor.white.setStroke(); NSBezierPath(rect: CGRect(x: pixels.midX - 6, y: pixels.midY - 6, width: 12, height: 12)).stroke()
            label("\(sample.pixelX), \(sample.pixelY)", at: CGPoint(x: box.minX + 11, y: box.minY + 25), background: false)
            label(rgbFormat?() == true ? sample.rgb : sample.hex, at: CGPoint(x: box.minX + 11, y: box.minY + 7), background: false)
        }
        label("⌘C 复制 · ⌥ 取色 · Esc 退出", at: CGPoint(x: max(12, bounds.midX - 115), y: 24))
    }
    private func label(_ value: String, at point: CGPoint, background: Bool = true) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let rect = CGRect(origin: point, size: (value as NSString).size(withAttributes: attributes))
        if background { NSColor.black.withAlphaComponent(0.7).setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: -6, dy: -4), xRadius: 5, yRadius: 5).fill() }
        (value as NSString).draw(in: rect, withAttributes: attributes)
    }
}
