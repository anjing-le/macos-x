import AppKit

/// A non-activating shelf on each screen. Tracking areas, rather than a global
/// mouse listener or timer, reveal its small central edge target on demand.
@MainActor final class CaptureShelf {
    typealias Item = CaptureShelfStore.Item
    private let store: CaptureShelfStore
    private let presenting: Bool
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.shelf", qos: .userInitiated)
    private var records: [Item] = []
    private var thumbnails: [UUID: NSImage] = [:]
    private var panels: [ShelfPanel] = []
    private var observer: NSObjectProtocol?
    private var messagePanel: ShelfPanel?
    private var running = false, busy = false, suspended = false, loaded = false
    private var epoch: UInt64 = 0
    private var previewBusy = false
    private var previewRequest: (UUID, ShelfPanel)?
    var onStatus: ((String) -> Void)?
    var onPin: ((CGImage, CGRect?) -> Void)?
    var canAdd: Bool { running && loaded && !busy && records.count < CaptureShelfStore.limit }

    init(directory: URL? = nil, presenting: Bool = true) {
        self.presenting = presenting
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macos-x/CaptureShelf", isDirectory: true)
        store = CaptureShelfStore(directory: base)
    }
    func start() {
        guard !running else { return }; running = true; epoch &+= 1
        refresh(load: true)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildPanels() } }
    }
    func stop() {
        running = false; loaded = false; suspended = false; epoch &+= 1; previewRequest = nil
        messagePanel?.dispose(); messagePanel = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        panels.forEach { $0.dispose() }; panels.removeAll(); records.removeAll(); thumbnails.removeAll()
    }
    func setSuspended(_ value: Bool) {
        suspended = value
        if value { messagePanel?.dispose(); messagePanel = nil; panels.forEach { $0.dispose() }; panels.removeAll() }
        else if running { rebuildPanels() }
    }
    func add(_ image: CGImage, completion: @escaping (Bool) -> Void) {
        guard canAdd else { showMessage(busy || !loaded ? "收纳正在处理，请稍后再试。" : "晾衣杆已满，请先整理。"); completion(false); return }
        busy = true; let expected = epoch, store = store
        queue.async { [weak self] in
            let result = Result { try store.add(image) }
            let thumbs = Self.loadThumbnails(store)
            let items = store.items
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                guard self.running, self.epoch == expected else { completion(false); return }
                switch result {
                case .success(let item):
                    self.records = items; self.thumbnails = thumbs; self.rebuildPanels()
                    self.onStatus?("已收纳 · 鼠标移到屏幕顶部中央查看")
                    completion(true)
                    self.reveal(item.id)
                case .failure(let error): self.showMessage(error.localizedDescription); completion(false)
                }
            }
        }
    }
    func showMessage(_ text: String) {
        onStatus?(text)
        guard running, !suspended,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        messagePanel?.dispose()
        let panel = ShelfPanel(screen: screen, records: [], thumbnails: [:], presenting: presenting)
        messagePanel = panel; panel.showNotice(text)
    }
    private nonisolated static func loadThumbnails(_ store: CaptureShelfStore) -> [UUID: NSImage] {
        var result: [UUID: NSImage] = [:]
        for item in store.items {
            if let cg = store.image(item.id, maximum: 280) { result[item.id] = NSImage(cgImage: cg, size: .zero) }
        }
        return result
    }
    private func refresh(load: Bool = false) {
        let expected = epoch, store = store
        queue.async { [weak self] in
            let result = Result { if load { _ = try store.load() }; return store.items }
            let thumbs = Self.loadThumbnails(store)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.epoch == expected else { return }
                switch result {
                case .success(let items): self.loaded = true; self.records = items; self.thumbnails = thumbs; self.rebuildPanels()
                case .failure(let error): self.loaded = false; self.onStatus?("收纳读取失败：\(error.localizedDescription)")
                }
            }
        }
    }
    private func rebuildPanels() {
        panels.forEach { $0.dispose() }; panels.removeAll()
        guard running, !suspended, !records.isEmpty else { return }
        for screen in NSScreen.screens {
            let panel = ShelfPanel(screen: screen, records: records, thumbnails: thumbnails, presenting: presenting)
            panel.shelfView.onAction = { [weak self, weak panel] action in
                guard let self, let panel else { return }; self.act(action, panel: panel)
            }
            panels.append(panel); panel.collapse()
        }
    }
    private func reveal(_ id: UUID) {
        guard !suspended else { return }
        let panel = panels.first { $0.screenFrame.contains(NSEvent.mouseLocation) } ?? panels.first
        panel?.shelfView.select(id); panel?.expand()
        panel?.scheduleCollapse(after: 1.5)
    }
    private func act(_ action: ShelfView.Action, panel: ShelfPanel) {
        guard running, !busy else { return }
        switch action {
        case .preview(let id):
            previewRequest = (id, panel); loadPreview()
        case .pin(let id, _), .copy(let id):
            busy = true; let expected = epoch, store = store
            let copy: Bool; if case .copy = action { copy = true } else { copy = false }
            let location: CGPoint?; if case .pin(_, let point) = action { location = point } else { location = nil }
            queue.async { [weak self, weak panel] in
                let image = store.image(id)
                let data = copy ? image.flatMap { CaptureEditor.pngData($0) } : nil
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self else { return }; self.busy = false
                    guard self.running, self.epoch == expected else { return }
                    guard let image else { self.onStatus?("图片读取失败，原记录已保留。"); return }
                    if copy {
                        guard let data else { self.onStatus?("图片编码失败。"); return }
                        NSPasteboard.general.clearContents()
                        self.onStatus?(NSPasteboard.general.setData(data, forType: .png) ? "已复制收纳原图。" : "复制失败。")
                    } else {
                        let frame = location.map { point -> CGRect in
                            let factor = min(1, 560 / CGFloat(max(image.width, image.height)))
                            let size = CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor)
                            return CGRect(x: point.x-size.width/2, y: point.y-size.height/2, width: size.width, height: size.height)
                        }
                        self.onPin?(image, frame); panel?.collapse()
                    }
                }
            }
        case .move(let id, let index): mutate { try $0.move(id, to: index) }
        case .remove(let id): mutate { try $0.remove(id) }
        case .undo: mutate { try $0.undo() }
        }
    }
    private func loadPreview() {
        guard !previewBusy, let (id, panel) = previewRequest else { return }
        previewRequest = nil; previewBusy = true
        let expected = epoch, store = store
        queue.async { [weak self, weak panel] in
            let image = store.image(id, maximum: 1200)
            DispatchQueue.main.async { [weak self, weak panel] in
                guard let self else { return }; self.previewBusy = false
                if self.running, self.epoch == expected, let panel, panel.expanded,
                   panel.shelfView.hovered == id, let image {
                    panel.shelfView.preview = NSImage(cgImage: image,size: .zero)
                    panel.expand(preview: true)
                }
                self.loadPreview()
            }
        }
    }
    private func mutate(_ action: @escaping (CaptureShelfStore) throws -> Void) {
        busy = true; let expected = epoch, store = store
        queue.async { [weak self] in
            let error: Error?; do { try action(store); error = nil } catch let caught { error = caught }
            let items = store.items, thumbs = Self.loadThumbnails(store)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                guard self.running, self.epoch == expected else { return }
                if let error { self.onStatus?(error.localizedDescription); return }
                self.records = items; self.thumbnails = thumbs; self.rebuildPanels()
                if let first = items.first { self.reveal(first.id) }
            }
        }
    }
}

@MainActor final class ShelfPanel: NSPanel {
    let shelfView: ShelfView
    let screenFrame: CGRect
    private let top: CGFloat, railWidth: CGFloat
    private var work: DispatchWorkItem?
    private let presenting: Bool
    private(set) var expanded = false
    private var disposed = false
    override var canBecomeKey: Bool { expanded }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    init(screen: NSScreen, records: [CaptureShelfStore.Item], thumbnails: [UUID: NSImage], presenting: Bool = true) {
        self.presenting = presenting
        screenFrame = screen.frame
        top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        railWidth = min(min(900, max(160, screen.visibleFrame.width - 32)), max(220, CGFloat(min(records.count,6))*144+28))
        shelfView = ShelfView(records: records, thumbnails: thumbnails)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "截图晾衣杆"; isReleasedWhenClosed = false; contentView = shelfView
        backgroundColor = .clear; isOpaque = false; hasShadow = false; hidesOnDeactivate = false
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none; acceptsMouseMovedEvents = true
    }
    func expand(preview: Bool = false) {
        guard !disposed else { return }
        work?.cancel(); work = nil; expanded = true
        shelfView.expanded = true
        let height = min(preview ? 420.0 : 184.0, max(184, screenFrame.height - 80))
        setFrame(CGRect(x: screenFrame.midX-railWidth/2, y: top-height, width: railWidth, height: height), display: true)
        shelfView.needsDisplay = true; if presenting { orderFrontRegardless() }
    }
    func collapse() {
        guard !disposed else { return }
        work?.cancel(); work = nil; if isKeyWindow { resignKey() }; expanded = false; shelfView.expanded = false
        shelfView.preview = nil; shelfView.hovered = nil
        let width = min(280, railWidth)
        setFrame(CGRect(x: screenFrame.midX-width/2,y: top-6,width: width,height: 6), display: true)
        if presenting { orderFrontRegardless() }
    }
    func scheduleCollapse(after delay: Double = 0.45) {
        work?.cancel()
        let next = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.frame.contains(NSEvent.mouseLocation) { return }
            self.collapse()
        }
        work = next; DispatchQueue.main.asyncAfter(deadline: .now()+delay, execute: next)
    }
    func hoverEntered() {
        work?.cancel()
        guard !expanded else { return }
        let next = DispatchWorkItem { [weak self] in self?.expand() }
        work = next; DispatchQueue.main.asyncAfter(deadline: .now()+0.18, execute: next)
    }
    func showNotice(_ text: String) {
        work?.cancel(); expanded = true; shelfView.expanded = true; shelfView.notice = text
        let width = min(520, screenFrame.width-32)
        setFrame(CGRect(x: screenFrame.midX-width/2,y: top-64,width: width,height: 64),display: true)
        if presenting { orderFrontRegardless() }
        let next = DispatchWorkItem { [weak self] in self?.dispose() }
        work = next; DispatchQueue.main.asyncAfter(deadline: .now()+2,execute: next)
    }
    func focusForInteraction() { if presenting { makeKeyAndOrderFront(nil) } }
    func dispose() {
        guard !disposed else { return }; disposed = true; expanded = false; shelfView.expanded = false
        work?.cancel(); work = nil; shelfView.onAction = nil
        shelfView.trackingAreas.forEach(shelfView.removeTrackingArea)
        orderOut(nil); close()
    }
}

@MainActor final class ShelfView: NSView {
    enum Action { case preview(UUID), pin(UUID, CGPoint?), copy(UUID), move(UUID, Int), remove(UUID), undo }
    let records: [CaptureShelfStore.Item]
    let thumbnails: [UUID: NSImage]
    var onAction: ((Action) -> Void)?
    var expanded = false
    var notice: String?
    var selected: UUID?
    var hovered: UUID?
    var preview: NSImage? { didSet { needsDisplay = true } }
    private var offset = 0
    private var dragging: (id: UUID, start: CGPoint)?
    private var moved = false
    private var insertion: Int?
    private var dragPoint: CGPoint?
    private var lastDragPageAt = -Double.infinity
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(records: [CaptureShelfStore.Item], thumbnails: [UUID: NSImage]) {
        self.records = records; self.thumbnails = thumbnails; selected = records.first?.id
        super.init(frame: .zero)
        toolTip = "点击贴出 · 横向拖动排序 · 向下拖出贴图 · 左右键选择 · Option＋方向键排序 · ⌘C 复制 · Delete 删除 · ⌘Z 撤销"
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("截图晾衣杆，左右选择，回车贴图，Command C 复制，Delete 删除，Command Z 撤销")
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityChildren() -> [Any]? {
        guard expanded else { return [] }
        var children: [Any] = records.indices.filter { $0 >= offset && $0 < offset+capacity }.map { index in
            let item = records[index]
            return ShelfAccessibleItem(view: self, rect: cardRect(index), title: "贴出图片 \(index+1)，\(item.width) × \(item.height)") { [weak self] in
                self?.onAction?(.pin(item.id,nil))
            }
        }
        if let selected {
            children.append(ShelfAccessibleItem(view: self,rect: CGRect(x: 16,y: 154,width: 90,height: 26),title: "删除选中的图片，可撤销") { [weak self] in self?.onAction?(.remove(selected)) })
        }
        children.append(ShelfAccessibleItem(view: self,rect: CGRect(x: 16,y: 154,width: 55,height: 26),title: "撤销删除") { [weak self] in self?.onAction?(.undo) })
        children.append(ShelfAccessibleItem(view: self,rect: CGRect(x: bounds.width-90,y: 154,width: 42,height: 26),title: "上一页") { [weak self] in self?.page(-1) })
        children.append(ShelfAccessibleItem(view: self,rect: CGRect(x: bounds.width-45,y: 154,width: 42,height: 26),title: "下一页") { [weak self] in self?.page(1) })
        return children
    }
    private var capacity: Int { max(1, Int((bounds.width-28)/144)) }
    private var cardWidth: CGFloat { min(132, bounds.width-32) }
    func cardRect(_ index: Int) -> CGRect { CGRect(x: 16+CGFloat(index-offset)*144,y: 46,width: cardWidth,height: 100) }
    func select(_ id: UUID) {
        selected = id
        if let index = records.firstIndex(where: { $0.id == id }) {
            if index < offset { offset = index }
            if index >= offset+capacity { offset = index-capacity+1 }
        }
        needsDisplay = true
    }
    private func item(at point: CGPoint) -> Int? {
        records.indices.first { $0 >= offset && $0 < offset+capacity && cardRect($0).contains(point) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect,.mouseEnteredAndExited,.mouseMoved,.activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { (window as? ShelfPanel)?.hoverEntered() }
    override func mouseExited(with event: NSEvent) {
        guard dragging == nil, let panel = window as? ShelfPanel else { return }
        let pointer = panel.convertPoint(toScreen: event.locationInWindow)
        guard !panel.frame.contains(pointer) else { return }
        // An in-flight hover preview must not reopen the shelf after exit.
        hovered = nil; panel.scheduleCollapse()
    }
    override func mouseMoved(with event: NSEvent) {
        guard expanded, dragging == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let index = item(at: point) else { return }
        let id = records[index].id
        if hovered != id { hovered = id; selected = id; preview = nil; onAction?(.preview(id)); needsDisplay = true }
    }
    override func resetCursorRects() {
        if expanded { addCursorRect(CGRect(x: 12,y: 40,width: bounds.width-24,height: 110), cursor: .openHand) }
    }
    override func mouseDown(with event: NSEvent) {
        guard expanded else { return }; if let panel = window as? ShelfPanel { panel.focusForInteraction() }; window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if point.y > 154 && point.y < 180 {
            if point.x < 70 { onAction?(.undo) }
            else if point.x > bounds.width-45 { page(1) }
            else if point.x > bounds.width-90 { page(-1) }
            return
        }
        guard let index = item(at: point) else { return }
        let id = records[index].id; selected = id
        let rect = cardRect(index)
        if point.x > rect.maxX-22 && point.y < rect.minY+22 { onAction?(.remove(id)); return }
        dragging = (id, window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow); moved = false; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if hypot(point.x-dragging.start.x,point.y-dragging.start.y) > 4 { moved = true; NSCursor.closedHand.set() }
        guard moved else { return }
        let local = convert(event.locationInWindow, from: nil)
        dragPoint = local
        if event.timestamp-lastDragPageAt > 0.25 {
            if local.x < 16, offset > 0 { offset -= 1; lastDragPageAt = event.timestamp }
            else if local.x > bounds.width-16, offset+capacity < records.count { offset += 1; lastDragPageAt = event.timestamp }
        }
        insertion = max(0,min(records.count-1,offset+Int(max(0,local.x-16)/144)))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let drag = dragging else { return }; dragging = nil; NSCursor.openHand.set()
        let point = convert(event.locationInWindow, from: nil)
        if moved {
            if point.y > 184 { onAction?(.pin(drag.id,window?.convertPoint(toScreen: event.locationInWindow))) }
            else if let insertion { onAction?(.move(drag.id,insertion)) }
        } else { onAction?(.pin(drag.id,nil)) }
        moved = false; insertion = nil; dragPoint = nil; needsDisplay = true
        if let panel = window as? ShelfPanel, !panel.frame.contains(NSEvent.mouseLocation) { panel.scheduleCollapse() }
    }
    private func page(_ direction: Int) {
        offset = max(0,min(max(0,records.count-capacity),offset+direction*capacity))
        hovered = nil; preview = nil; needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard expanded, event.momentumPhase.isEmpty else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if abs(delta) > 1 { page(delta < 0 ? 1 : -1) }
    }
    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 53 { (window as? ShelfPanel)?.collapse(); return }
        if command && event.charactersIgnoringModifiers?.lowercased() == "z" { onAction?(.undo); return }
        guard let selected else { return }
        if command && event.charactersIgnoringModifiers?.lowercased() == "c" { onAction?(.copy(selected)); return }
        if event.keyCode == 36 { onAction?(.pin(selected,nil)); return }
        if event.keyCode == 51 || event.keyCode == 117 { onAction?(.remove(selected)); return }
        if event.keyCode == 123 || event.keyCode == 124 {
            let index = max(0,min(records.count-1,(records.firstIndex { $0.id == selected } ?? 0)+(event.keyCode == 124 ? 1 : -1)))
            if event.modifierFlags.contains(.option) { onAction?(.move(selected,index)); return }
            self.selected = records[index].id
            if index < offset { offset = index }; if index >= offset+capacity { offset = index-capacity+1 }
            hovered = self.selected; if let hovered { onAction?(.preview(hovered)) }; needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard expanded else { return }
        let body = bounds.insetBy(dx: 1,dy: 1)
        SketchPalette.paper.setFill(); NSBezierPath(roundedRect: body,xRadius: 12,yRadius: 12).fill()
        SketchPencil.stroke(SketchPencil.outline(in: body,radius: 12),color: SketchPalette.line,width: 0.7)
        if let notice { label(notice,at: CGPoint(x: 18,y: 23),size: 12); return }
        label("截图晾衣杆", at: CGPoint(x: 18,y: 11),size: 13,heading: true)
        let countLabel = records.count > capacity ? "\(offset+1)–\(min(records.count,offset+capacity)) / \(records.count)" : "\(records.count) 张"
        let labelWidth = (countLabel as NSString).size(withAttributes: [.font:NSFont.systemFont(ofSize: 11)]).width
        label(countLabel,at: CGPoint(x: bounds.width-labelWidth-18,y: 12),size: 11)
        let rail = NSBezierPath(); rail.move(to: CGPoint(x: 16,y: 40)); rail.line(to: CGPoint(x: bounds.width-16,y: 40))
        SketchPencil.stroke(rail,color: SketchPalette.line,width: 1)
        for index in records.indices where index >= offset && index < offset+capacity {
            let item = records[index], rect = cardRect(index)
            NSColor.white.setFill(); NSBezierPath(roundedRect: rect,xRadius: 5,yRadius: 5).fill()
            if let image = thumbnails[item.id] { image.draw(in: fit(image.size, in: rect.insetBy(dx: 5,dy: 5)),from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: [.interpolation:NSImageInterpolation.high]) }
            let outline = NSBezierPath(roundedRect: rect,xRadius: 5,yRadius: 5)
            SketchPencil.stroke(outline,color: selected == item.id ? SketchPalette.blue : SketchPalette.line,width: selected == item.id ? 1.5 : 0.6)
            let clip = CGRect(x: rect.midX-5,y: 34,width: 10,height: 17)
            SketchPalette.yellow.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: clip,xRadius: 2,yRadius: 2).fill()
            SketchPencil.stroke(NSBezierPath(roundedRect: clip,xRadius: 2,yRadius: 2),color: SketchPalette.line,width: 0.6)
            if hovered == item.id || selected == item.id {
                NSColor.white.withAlphaComponent(0.95).setFill(); NSBezierPath(ovalIn: CGRect(x: rect.maxX-21,y: rect.minY+2,width: 19,height: 19)).fill()
                label("×",at: CGPoint(x: rect.maxX-18,y: rect.minY+1),size: 16)
            }
        }
        if moved, let dragPoint, let dragging, let image = thumbnails[dragging.id] {
            let ghost = CGRect(x: dragPoint.x-cardWidth/2,y: dragPoint.y-50,width: cardWidth,height: 100)
            NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: ghost,xRadius: 5,yRadius: 5).fill()
            image.draw(in: fit(image.size,in: ghost.insetBy(dx: 4,dy: 4)),from: .zero,operation: .sourceOver,fraction: 0.85,respectFlipped: true,hints: nil)
        }
        if let insertion, moved {
            SketchPalette.blue.setFill(); CGRect(x: cardRect(insertion).minX-5,y: 48,width: 3,height: 96).fill()
        }
        label("撤销",at: CGPoint(x: 18,y: 160),size: 11)
        if bounds.width > 400 { label("拖动排序 · 下拉贴图 · ⌘C 复制",at: CGPoint(x: 100,y: 160),size: 11) }
        if records.count > capacity { label("‹     ›",at: CGPoint(x: bounds.width-73,y: 154),size: 22) }
        if let preview, bounds.height > 200 {
            let area = CGRect(x: 18,y: 192,width: bounds.width-36,height: bounds.height-208)
            preview.draw(in: fit(preview.size,in: area),from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: [.interpolation:NSImageInterpolation.high])
        }
    }
    private func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        let scale = min(rect.width/max(1,size.width),rect.height/max(1,size.height))
        return CGRect(x: rect.midX-size.width*scale/2,y: rect.midY-size.height*scale/2,width: size.width*scale,height: size.height*scale)
    }
    private func label(_ text: String, at point: CGPoint, size: CGFloat, heading: Bool = false) {
        (text as NSString).draw(at: point,withAttributes: [.font:heading ? SketchPalette.heading(size) : NSFont.systemFont(ofSize: size),.foregroundColor:SketchPalette.ink])
    }
}

@MainActor private final class ShelfAccessibleItem: NSAccessibilityElement {
    private weak var view: ShelfView?
    private let rect: CGRect
    private let action: () -> Void
    init(view: ShelfView, rect: CGRect, title: String, action: @escaping () -> Void) {
        self.view = view; self.rect = rect; self.action = action; super.init()
        setAccessibilityRole(.button); setAccessibilityLabel(title); setAccessibilityParent(view); setAccessibilityElement(true)
    }
    override func accessibilityFrame() -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect,to: nil))
    }
    override func accessibilityPerformPress() -> Bool { action(); return true }
}
