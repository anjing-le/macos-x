import AppKit
import UniformTypeIdentifiers

@MainActor
final class CapturePins {
    private struct Request { let image: CGImage; let frame: CGRect?; let onPresent: ((Bool) -> Void)? }
    private var entries: [PinEntry] = []
    private var pending: [Request] = []
    private var adding = false
    private var recovered: (PinSnapshot, Int)?
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.pins", qos: .userInitiated)
    private var generation: UInt64 = 0
    private var ticket = CaptureImageService.Ticket()
    var onStatus: ((String) -> Void)?
    var showsOutline = false {
        didSet {
            guard showsOutline != oldValue else { return }
            entries.forEach { $0.setOutline(showsOutline) }
        }
    }
    var count: Int { entries.count }
    var canAdd: Bool { entries.count + pending.count + (adding ? 1 : 0) < 8 }

    func add(_ image: CGImage, at frame: CGRect? = nil, onPresent: ((Bool) -> Void)? = nil) {
        guard canAdd else { onStatus?("最多 8 张贴图。"); onPresent?(false); return }
        recovered = nil
        pending.append(Request(image: image, frame: frame, onPresent: onPresent))
        addNext()
    }
    private func addNext() {
        guard !adding, !pending.isEmpty else { return }
        adding = true
        let request = pending.removeFirst(), expected = generation, ticket = ticket
        queue.async { [weak self] in
            let image = ticket.valid ? CaptureRaster.downsample(request.image, maximumPixels: 4_000_000) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.adding = false
                if self.generation == expected, ticket.valid, let image {
                    self.insert(PinEntry(image: image, frame: request.frame, queue: self.queue))
                    request.onPresent?(true)
                } else { request.onPresent?(false) }
                self.addNext()
            }
        }
    }
    private func insert(_ entry: PinEntry) {
        guard entries.count < 8 else { return }
        entry.onClose = { [weak self, weak entry] in
            guard let self, let entry, self.entries.contains(where: { $0 === entry }) else { return }
            self.recovered = (entry.snapshot, NSPasteboard.general.changeCount)
            self.entries.removeAll { $0 === entry }
            self.onStatus?("贴图 \(self.entries.count)/8")
        }
        entry.onStatus = { [weak self] in self?.onStatus?($0) }
        entry.setOutline(showsOutline)
        entries.append(entry); entry.present()
        onStatus?("贴图 \(entries.count)/8 · ⌘C 复制 · ⌘W 关闭")
    }
    func restoreLastClosed() -> Bool {
        guard let (snapshot, changeCount) = recovered else { return false }
        guard changeCount == NSPasteboard.general.changeCount else { recovered = nil; return false }
        guard canAdd else { return false }
        recovered = nil
        insert(PinEntry(snapshot: snapshot, queue: queue))
        return true
    }
    func applyActiveEdit() -> Bool { entries.contains { $0.applyEditIfKey() } }
    func toggleAll() { entries.contains(where: { $0.window.isVisible }) ? hideAll() : showAll() }
    func hideAll() { entries.forEach { $0.window.orderOut(nil) }; onStatus?("贴图已隐藏 · ⇧F3 显示") }
    func showAll() {
        entries.forEach { $0.window.ignoresMouseEvents = false; $0.present(focus: false) }
        onStatus?("已显示贴图。")
    }
    func closeAll() {
        generation &+= 1; ticket.cancel(); ticket = CaptureImageService.Ticket()
        let cancelled = pending; pending.removeAll(); recovered = nil
        cancelled.forEach { $0.onPresent?(false) }
        let old = entries; entries.removeAll()
        old.forEach { $0.dispose() }
    }
}

private struct PinSnapshot {
    let image: CGImage
    let baseSize: CGSize
    let frame: CGRect
    let transform: CapturePinTransform
    let zoom: CGFloat
    let thumbnail: Bool
    let opacity: CGFloat
}

private enum PinCommand { case copy, save, edit, close, hide, zoom(CGFloat), opacity(CGFloat), rotate(Bool), horizontal, vertical, thumbnail }

@MainActor
private final class PinEntry: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    let window: NSPanel
    private var image: CGImage
    private let view: PinView
    private let queue: DispatchQueue
    private var transform = CapturePinTransform()
    private var baseSize: CGSize
    private var zoom: CGFloat = 1
    private var thumbnail = false
    private var closed = false
    private var exporting = false
    private var samplingPending = false
    private var samplingTicket: CaptureImageService.Ticket?
    private let lifetime = CaptureImageService.Ticket()
    private var savePanel: NSSavePanel?
    private var editor: CaptureEditor?
    private var preparingEditor = false
    var onClose: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var snapshot: PinSnapshot {
        PinSnapshot(image: image, baseSize: baseSize, frame: window.frame, transform: transform,
                    zoom: zoom, thumbnail: thumbnail, opacity: window.alphaValue)
    }

    init(image: CGImage, frame: CGRect?, queue: DispatchQueue) {
        self.image = image; view = PinView(image: image); self.queue = queue
        let validFrame = frame.flatMap { rect -> CGRect? in
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }),
                rect.width > 0, rect.height > 0, rect.width <= 32_768, rect.height <= 32_768 else { return nil }
            return rect
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let factor = min(1, min(480 / CGFloat(max(image.width, image.height)),
                                min(available.width / CGFloat(image.width), available.height / CGFloat(image.height))))
        baseSize = validFrame?.size ?? CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
        let rect = validFrame ?? CGRect(x: available.midX - baseSize.width / 2, y: available.midY - baseSize.height / 2,
                                      width: baseSize.width, height: baseSize.height)
        window = Panel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "贴图"; window.isReleasedWhenClosed = false; window.delegate = self
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear
        window.hasShadow = false; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = view; window.initialFirstResponder = view
        window.setFrame(rect, display: false)
        view.onCommand = { [weak self] in self?.perform($0) }
        view.onMenu = { [weak self] in self?.menu() ?? NSMenu() }
        view.onSampling = { [weak self] in self?.setSampling($0) }
        view.onColor = { [weak self] color in
            guard let self, !self.closed else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(color, forType: .string)
            self.onStatus?("已复制 \(color)")
        }
    }
    convenience init(snapshot: PinSnapshot, queue: DispatchQueue) {
        self.init(image: snapshot.image, frame: snapshot.frame, queue: queue)
        baseSize = snapshot.baseSize; transform = snapshot.transform
        zoom = snapshot.zoom; thumbnail = snapshot.thumbnail; window.alphaValue = snapshot.opacity
        view.transform = transform; view.needsDisplay = true
    }
    func setOutline(_ visible: Bool) { view.showsOutline = visible }
    func present(focus: Bool = true) {
        guard !closed else { return }
        if focus { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view) }
        else { window.orderFrontRegardless() }
        window.displayIfNeeded()
    }
    func applyEditIfKey() -> Bool {
        guard !closed, let editor, editor.window.isKeyWindow else { return false }
        editor.pinCurrentImage(); return true
    }
    func windowDidResignKey(_ notification: Notification) { view.pauseSampling() }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; lifetime.cancel(); samplingTicket?.cancel(); samplingTicket = nil
        editor?.onClose = nil; editor?.close(); editor = nil
        savePanel?.cancel(nil); savePanel = nil; view.stopTracking(); window.acceptsMouseMovedEvents = false
        onClose?(); onClose = nil; onStatus = nil
        view.onCommand = nil; view.onMenu = nil; view.onSampling = nil; view.onColor = nil
        window.delegate = nil
    }
    func dispose() { onClose = nil; window.close(); if !closed { windowWillClose(Notification(name: NSWindow.willCloseNotification)) } }
    private func resize() {
        let rotated = transform.turns % 2 != 0
        let size = rotated ? CGSize(width: baseSize.height, height: baseSize.width) : baseSize
        let factor = thumbnail ? min(1, 150 / max(size.width, size.height)) : zoom
        let newSize = CGSize(width: max(8, size.width * factor), height: max(8, size.height * factor))
        let frame = window.frame
        window.setFrame(CGRect(x: frame.midX - newSize.width / 2, y: frame.midY - newSize.height / 2,
                               width: newSize.width, height: newSize.height), display: true)
        view.transform = transform; view.needsDisplay = true
    }
    private func perform(_ command: PinCommand) {
        guard !closed else { return }
        if preparingEditor {
            if case .close = command { window.close() }
            return
        }
        switch command {
        case .copy: copyImage()
        case .save: saveImage()
        case .edit: editImage()
        case .close: window.close()
        case .hide: window.close()
        case let .zoom(factor): thumbnail = false; zoom = min(4, max(0.15, zoom * factor)); resize()
        case let .opacity(delta): window.alphaValue = min(1, max(0.1, window.alphaValue + delta))
        case let .rotate(clockwise): transform.rotate(clockwise: clockwise); resize()
        case .horizontal: transform.horizontalFlip.toggle(); resize()
        case .vertical: transform.verticalFlip.toggle(); resize()
        case .thumbnail: thumbnail.toggle(); resize()
        }
    }
    private func setSampling(_ enabled: Bool) {
        if !enabled { samplingTicket?.cancel(); samplingTicket = nil; view.sampler = nil; view.needsDisplay = true; return }
        guard !closed, !samplingPending, view.sampler == nil else { return }
        samplingPending = true
        let ticket = CaptureImageService.Ticket(), image = image, lifetime = lifetime
        samplingTicket = ticket
        queue.async { [weak self] in
            let sampler = ticket.valid && lifetime.valid ? CapturePixelSampler(image: image, maximumBytes: 16_000_000) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.samplingPending = false
                if ticket.valid, lifetime.valid, self.view.isSampling {
                    self.view.sampler = sampler; self.view.needsDisplay = true
                } else if !self.closed, self.view.isSampling { self.setSampling(true) }
            }
        }
    }
    @objc private func copyImage() { encode(to: nil) }
    @objc private func editImage() {
        guard !closed, editor == nil, !preparingEditor, !exporting else { return }
        preparingEditor = true; view.pauseSampling()
        let image = image, transform = transform, lifetime = lifetime
        queue.async { [weak self] in
            let rendered = lifetime.valid ? transform.render(image) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, lifetime.valid else { return }
                self.preparingEditor = false
                guard let rendered else { self.onStatus?("贴图编辑失败。"); return }
                let editor = CaptureEditor(image: rendered, selectionFrame: self.window.frame, editingPin: true)
                self.editor = editor
                editor.onApply = { [weak self] result in
                    guard let self, !self.closed else { return }
                    self.image = result; self.view.image = result
                    self.transform = CapturePinTransform(); self.view.transform = self.transform
                    self.baseSize = self.window.frame.size; self.zoom = 1; self.thumbnail = false
                    self.samplingTicket?.cancel(); self.view.sampler = nil; self.view.needsDisplay = true
                }
                editor.onClose = { [weak self] in
                    guard let self, !self.closed else { return }
                    self.editor = nil; self.present()
                }
                editor.present()
                self.window.orderOut(nil)
            }
        }
    }
    @objc private func saveImage() {
        guard !closed, !exporting else { return }
        exporting = true
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "贴图.png"
        savePanel = panel
        panel.begin { [weak self] response in
            guard let self, !self.closed else { return }
            self.savePanel = nil; self.exporting = false
            if response == .OK, let url = panel.url { self.encode(to: url) }
        }
    }
    private func encode(to url: URL?) {
        guard !closed, !exporting else { return }
        exporting = true
        let image = image, transform = transform, lifetime = lifetime
        queue.async { [weak self] in
            let data: Data? = autoreleasepool {
                guard lifetime.valid, let rendered = transform.render(image), lifetime.valid else { return nil }
                return CaptureEditor.pngData(rendered)
            }
            var saved = false
            if lifetime.valid, let url, let data { saved = (try? data.write(to: url, options: .atomic)) != nil }
            let didSave = saved
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, lifetime.valid else { return }
                self.exporting = false
                guard let data else { self.onStatus?("贴图导出失败。"); return }
                if url != nil { self.onStatus?(didSave ? "已保存贴图。" : "贴图保存失败。") }
                else {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
                    self.onStatus?("已复制贴图。")
                }
            }
        }
    }
    @objc private func menuCommand(_ sender: NSMenuItem) {
        switch sender.tag {
        case 1: perform(.zoom(1.2)); case 2: perform(.zoom(1 / 1.2))
        case 3: perform(.rotate(true)); case 4: perform(.rotate(false))
        case 5: perform(.horizontal); case 6: perform(.vertical); case 7: perform(.thumbnail)
        case 8: window.ignoresMouseEvents = true; onStatus?("已穿透 · 隐藏后再显示可恢复交互")
        case 9: perform(.close)
        default: break
        }
    }
    private func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, selector, key) in [("复制", #selector(copyImage), "c"), ("编辑", #selector(editImage), "e"), ("另存为…", #selector(saveImage), "s")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        for (tag, title) in [(1, "放大"), (2, "缩小"), (3, "顺时针旋转"), (4, "逆时针旋转"),
                             (5, "水平翻转"), (6, "垂直翻转"), (7, thumbnail ? "恢复尺寸" : "缩略图"), (8, "点击穿透"), (9, "关闭")] {
            let item = NSMenuItem(title: title, action: #selector(menuCommand(_:)), keyEquivalent: "")
            item.tag = tag; item.target = self; menu.addItem(item)
        }
        return menu
    }
}

@MainActor
private final class PinView: NSView {
    var image: CGImage
    var showsOutline = false { didSet { if showsOutline != oldValue { needsDisplay = true } } }
    var transform = CapturePinTransform()
    var sampler: CapturePixelSampler?
    private(set) var isSampling = false
    private var rgbFormat = false
    private var shiftDown = false
    private var samplePoint: CGPoint?
    private var tracking: NSTrackingArea?
    var onCommand: ((PinCommand) -> Void)?
    var onMenu: (() -> NSMenu)?
    var onSampling: ((Bool) -> Void)?
    var onColor: ((String) -> Void)?
    private var drag: CapturePinDrag?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(image: CGImage) { self.image = image; super.init(frame: .zero); setAccessibilityLabel("贴图"); setAccessibilityRole(.image) }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    func stopTracking() {
        if let tracking { removeTrackingArea(tracking); self.tracking = nil }
        sampler = nil; samplePoint = nil; isSampling = false; drag = nil
    }
    func pauseSampling() { updateModifiers([]); samplePoint = nil; drag = nil }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        updateModifiers(event.modifierFlags)
        samplePoint = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            onCommand?(event.modifierFlags.contains(.shift) ? .thumbnail : .hide)
        } else if !isSampling, let window {
            drag = CapturePinDrag(anchor: window.convertPoint(toScreen: event.locationInWindow), original: window.frame)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard !isSampling, let window, var drag else { return }
        let frame = drag.frame(at: window.convertPoint(toScreen: event.locationInWindow))
        self.drag = drag
        if let frame { window.setFrame(frame, display: false) }
    }
    override func mouseUp(with event: NSEvent) { drag = nil }
    override func mouseMoved(with event: NSEvent) {
        updateModifiers(event.modifierFlags)
        samplePoint = convert(event.locationInWindow, from: nil)
        if isSampling { needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { updateModifiers(event.modifierFlags); samplePoint = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { pauseSampling(); needsDisplay = true }
    override func flagsChanged(with event: NSEvent) { updateModifiers(event.modifierFlags) }
    override func resignFirstResponder() -> Bool { updateModifiers([]); return super.resignFirstResponder() }
    private func updateModifiers(_ flags: NSEvent.ModifierFlags) {
        let wasSampling = isSampling, wasRGB = rgbFormat
        let active = flags.contains(.option)
        let nextShift = flags.contains(.shift)
        if active && !wasSampling {
            window?.makeKey()
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        }
        if active && !wasSampling { rgbFormat = false }
        if active && nextShift && !shiftDown { rgbFormat.toggle() }
        shiftDown = nextShift
        if isSampling != active { isSampling = active; onSampling?(active) }
        if active, samplePoint == nil, let window { samplePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil) }
        if wasSampling != isSampling || (isSampling && wasRGB != rgbFormat) { needsDisplay = true }
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = max(-10, min(10, event.scrollingDeltaY))
        guard abs(delta) > 0.01 else { return }
        onCommand?(event.modifierFlags.contains(.command) ? .opacity(delta * 0.025) : .zoom(pow(1.025, delta)))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c": onCommand?(.copy)
        case "s": onCommand?(.save)
        case "e": onCommand?(.edit)
        case "w": onCommand?(.close)
        case "+", "=": onCommand?(.opacity(0.1))
        case "-", "_": onCommand?(.opacity(-0.1))
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
    @objc func copy(_ sender: Any?) { onCommand?(.copy) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            if !event.isARepeat { onCommand?(.edit) }
            return
        }
        if event.keyCode == 53 { onCommand?(.close); return }
        if event.keyCode == 36 || event.keyCode == 76 { onCommand?(.copy); return }
        if event.modifierFlags.contains(.command) {
            if !performKeyEquivalent(with: event) { super.keyDown(with: event) }
            return
        }
        if event.modifierFlags.contains(.option), event.keyCode == 8, isSampling, let sample = currentSample() {
            onColor?(rgbFormat ? sample.rgb : sample.hex); return
        }
        switch event.charactersIgnoringModifiers {
        case "+", "=": onCommand?(.zoom(1.2)); case "-", "_": onCommand?(.zoom(1 / 1.2))
        case "1": onCommand?(.rotate(true)); case "2": onCommand?(.rotate(false))
        case "3": onCommand?(.horizontal); case "4": onCommand?(.vertical)
        default: super.keyDown(with: event)
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
    private func currentSample() -> CapturePixelSample? {
        guard let point = samplePoint, let pixel = transform.pixel(at: point, in: bounds, image: image) else { return nil }
        return sampler?.sample(x: Int(pixel.x), y: Int(pixel.y))
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.concatenate(transform.matrix(in: bounds, image: image))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        if showsOutline { CapturePinHighlight.draw(in: context, bounds: bounds) }
        guard isSampling, let point = samplePoint, let sample = currentSample(), let sampler,
              let rawPatch = sampler.magnifier(sample: sample, radius: 5), let patch = transform.render(rawPatch) else { return }
        let width = min(150, bounds.width), height = min(136, bounds.height)
        guard width >= 88, height >= 110 else { return }
        let rect = CGRect(x: min(max(bounds.minX, point.x + 18), bounds.maxX - width),
                          y: min(max(bounds.minY, point.y + 18), bounds.maxY - height), width: width, height: height)
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill(); NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let patchRect = CGRect(x: rect.midX - 44, y: rect.maxY - 96, width: 88, height: 88)
        context.saveGState(); context.interpolationQuality = .none; context.draw(patch, in: patchRect); context.restoreGState()
        NSColor.white.setStroke(); let path = NSBezierPath(rect: CGRect(x: patchRect.midX - 4, y: patchRect.midY - 4, width: 8, height: 8)); path.lineWidth = 1; path.stroke()
        let text = rgbFormat ? sample.rgb : sample.hex
        (text as NSString).draw(in: CGRect(x: rect.minX + 6, y: rect.minY + 8, width: rect.width - 12, height: 20),
                               withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: rgbFormat ? 10 : 12, weight: .medium), .foregroundColor: NSColor.labelColor])
    }
}
