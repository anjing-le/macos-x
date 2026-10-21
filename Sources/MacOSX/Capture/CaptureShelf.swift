import AppKit

/// A non-activating shelf on each screen. Tracking areas, rather than a global
/// mouse listener or timer, reveal a borderless detail view below its rail.
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
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.frame
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
                    self.onStatus?("已收纳 · 鼠标移到屏幕顶部查看")
                    completion(true)
                    self.reveal(item.id, keyboard: true, on: screen)
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
            panel.shelfView.canEdit = { [weak self] in self?.running == true && self?.busy == false }
            panel.shelfView.onAction = { [weak self, weak panel] action in
                guard let self, let panel else { return }; self.act(action, panel: panel)
            }
            panels.append(panel); panel.collapse()
        }
    }
    @discardableResult func showForKeyboard() -> Bool {
        guard running, !suspended, let id = records.first?.id else { return false }
        reveal(id, keyboard: true); return true
    }
    func focusIfAlreadyOpen() -> Bool {
        guard let panel = panels.first(where: { $0.keyboardSession }) else { return false }
        panel.beginKeyboardSelection(); return true
    }
    private func reveal(_ id: UUID, keyboard: Bool = false, on frame: CGRect? = nil) {
        guard !suspended else { return }
        let panel = frame.flatMap { frame in panels.first { $0.screenFrame == frame } }
            ?? panels.first { $0.screenFrame.contains(NSEvent.mouseLocation) } ?? panels.first
        panel?.expand(); panel?.shelfView.select(id)
        if keyboard { panel?.beginKeyboardSelection() }
        else { panel?.scheduleCollapse(after: 1.5) }
    }
    private func act(_ action: ShelfView.Action, panel: ShelfPanel) {
        guard running, !busy else {
            if case .place = action { panel.shelfView.completeLayoutCommit() }
            return
        }
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
        case .place(_, let display, let order, let positions):
            savePlacement(display:display,order:order,positions:positions,source:panel)
        case .move(let id, let index): mutate(focusID: id, on:panel.screenFrame) { try $0.move(id, to: index) }
        case .remove(let id): mutate { try $0.remove(id) }
        case .undo: mutate { try $0.undo() }
        }
    }
    private func savePlacement(display:String,order:[UUID],positions:[UUID:Double],source:ShelfPanel) {
        busy=true; let expected=epoch, store=store
        queue.async { [weak self,weak source] in
            let result=Result { try store.arrange(on:display,order:order,positions:positions) }
            let items=store.items
            DispatchQueue.main.async { [weak self,weak source] in
                guard let self else { return }; self.busy=false
                guard self.running, self.epoch == expected else { return }
                let success:Bool
                switch result {
                case .success: success=true
                case .failure(let error): success=false; self.onStatus?(error.localizedDescription)
                }
                self.records=items
                for panel in self.panels {
                    panel.shelfView.applySavedItems(items,preserveLayout:success && panel === source)
                }
            }
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
    private func mutate(focusID: UUID? = nil, on sourceScreen: CGRect? = nil, _ action: @escaping (CaptureShelfStore) throws -> Void) {
        busy = true; let expected = epoch, store = store
        let active = panels.first { $0.keyboardSession }
        let keyboard = active != nil, screen = sourceScreen ?? active?.screenFrame, selected = focusID ?? active?.shelfView.selected
        let rebounds = panels.compactMap { panel in panel.ropePull.map { (panel.screenFrame,$0) } }
        queue.async { [weak self] in
            let error: Error?; do { try action(store); error = nil } catch let caught { error = caught }
            let items = store.items, thumbs = Self.loadThumbnails(store)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.busy = false
                guard self.running, self.epoch == expected else { return }
                if let error { self.onStatus?(error.localizedDescription) }
                self.records = items; self.thumbnails = thumbs; self.rebuildPanels()
                if let first = items.first {
                    let id = selected.flatMap { id in items.contains(where: { $0.id == id }) ? id : nil } ?? first.id
                    self.reveal(id, keyboard: keyboard, on: screen)
                    for (frame,pull) in rebounds {
                        self.panels.first { $0.screenFrame == frame && $0.expanded }?.resumeRope(pull)
                    }
                }
            }
        }
    }
}

enum ShelfRope {
    static let idleHeight: CGFloat = 6
    static let height: CGFloat = 80
    static let footerY: CGFloat = 188
    static let detailHeight: CGFloat = 220
    static func y(_ x: CGFloat, width: CGFloat) -> CGFloat {
        let t = min(1,max(0,x/max(1,width)))
        return 3 + 56*t*(1-t)
    }
    static func capacity(_ width: CGFloat) -> Int { max(1,Int((width-28)/144)) }

    // Six fixed-end string modes share one clock, but have different phases.
    // Sample temporal coefficients once per frame, not once per drawn rope point.
    struct Pull {
        static let duration: Double = 3.6
        let anchor: CGFloat
        let offset: CGSize
        let coefficients: [Double]
        let inheritedLateral: Double
        let inheritedSwing: Double
        var releasedAt: Double?
        init(anchor: CGFloat, offset: CGSize, baseline: Pose? = nil) {
            self.anchor = min(0.97,max(0.03,anchor))
            self.offset = CGSize(width:min(18,max(-18,offset.width*0.10)),
                                 height:min(48,max(-10,offset.height*0.62+min(10,abs(offset.width)*0.06))))
            let a=Double(self.anchor)
            let basis=(1...6).map { n in sin(Double(n)*Double.pi*a)/Double(n*n) }
            let normalization=(1...6).reduce(0.0) { $0+basis[$1-1]*sin(Double($1)*Double.pi*a) }
            let height=Double(self.offset.height)
            let previous=baseline?.coefficients ?? []
            let combined=basis.enumerated().map { index, value in
                value/max(0.001,normalization)*height+(previous.indices.contains(index) ? previous[index] : 0)
            }
            let peak=(0...32).map { step in
                abs(combined.enumerated().reduce(0) { $0+$1.element*sin(Double($1.offset+1)*Double.pi*Double(step)/32) })
            }.max() ?? 0
            let limit=min(1,48/max(1,peak))
            coefficients=combined.map { $0*limit }
            inheritedLateral=baseline?.lateral ?? 0
            inheritedSwing=baseline?.swingAmplitude ?? 0
        }
        func displacement(at time: Double) -> CGSize {
            let pose=Pose(pull:self,time:time)
            return CGSize(width:pose.lateral,height:pose.heightOffset(anchor))
        }
    }
    struct Pose {
        let coefficients: [Double]
        let offset: CGSize
        let lateral: Double
        let swingAmplitude: Double
        init(pull: Pull? = nil, time: Double = 0) {
            guard let pull else { coefficients=[]; offset = .zero; lateral=0; swingAmplitude=0; return }
            offset=pull.offset
            guard let start=pull.releasedAt else {
                coefficients=pull.coefficients; lateral=min(28,max(-28,Double(pull.offset.width)+pull.inheritedLateral))
                swingAmplitude=pull.inheritedSwing; return
            }
            let age=max(0,time-start)
            let tail=min(1,max(0,(Pull.duration-age)/0.6))
            let fade=tail*tail*(3-2*tail)
            coefficients=pull.coefficients.enumerated().map { index, coefficient in
                let n=Double(index+1), frequency=4.4*n, damping=1.55+0.16*n
                return coefficient*exp(-damping*age)*(cos(frequency*age)+damping/frequency*sin(frequency*age))*fade
            }
            lateral=min(28,max(-28,Double(offset.width)+pull.inheritedLateral))*exp(-1.8*age)*cos(4.4*age)*fade
            swingAmplitude=((Double(offset.width)*0.002+Double(offset.height)*0.0015)*sin(5.5*age)
                + pull.inheritedSwing*cos(5.5*age))*exp(-1.2*age)*fade
        }
        func heightOffset(_ t: CGFloat) -> Double {
            coefficients.enumerated().reduce(0) { $0+$1.element*sin(Double($1.offset+1)*Double.pi*Double(t)) }
        }
        func point(_ x: CGFloat, width: CGFloat) -> CGPoint {
            let t=min(1,max(0,x/max(1,width)))
            guard t > 0, t < 1 else { return CGPoint(x:x,y:3) }
            return CGPoint(x:x+lateral*sin(Double.pi*Double(t)),
                           y:min(ShelfRope.height-6,max(2,ShelfRope.y(x,width:width)+heightOffset(t))))
        }
        func angle(_ x: CGFloat, width: CGFloat) -> CGFloat {
            CGFloat(min(0.09,max(-0.09,swingAmplitude))*sin(Double.pi*Double(min(1,max(0,x/max(1,width))))))
        }
    }
    static func point(_ x: CGFloat, width: CGFloat, pull: Pull?, time: Double) -> CGPoint {
        Pose(pull:pull,time:time).point(x,width:width)
    }
    static func rotate(_ point: CGPoint, around pivot: CGPoint, angle: CGFloat) -> CGPoint {
        let x=point.x-pivot.x, y=point.y-pivot.y
        return CGPoint(x:pivot.x+x*cos(angle)-y*sin(angle),y:pivot.y+x*sin(angle)+y*cos(angle))
    }

}

@MainActor final class ShelfPanel: NSPanel {
    let shelfView: ShelfView
    let screenFrame: CGRect
    private let top: CGFloat, railWidth: CGFloat, detailCenterX: CGFloat
    private var work: DispatchWorkItem?
    private let presenting: Bool
    private var railPanel: NSPanel?
    var railFrame: CGRect { railPanel?.frame ?? .zero }
    var railView: NSView? { railPanel?.contentView }
    private(set) var expanded = false
    private(set) var keyboardSession = false
    private var disposed = false
    private var waitsForTriggerExit = false
    private(set) var ropePull: ShelfRope.Pull?
    private var motionTimer: Timer?
    private var pullingRope = false
    private var heldPose: ShelfRope.Pose?
    var hasRopeAnimation: Bool { motionTimer != nil }
    override var canBecomeKey: Bool { expanded }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    init(screen: NSScreen, records: [CaptureShelfStore.Item], thumbnails: [UUID: NSImage], presenting: Bool = true) {
        self.presenting = presenting
        screenFrame = screen.frame
        detailCenterX = screen.frame.midX
        top = min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top)
        railWidth = screen.frame.width
        shelfView = ShelfView(records: records, thumbnails: thumbnails)
        shelfView.ropeWidth = screen.frame.width
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        if let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
           let uuid=CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            shelfView.displayKey=CFUUIDCreateString(nil,uuid) as String
        }
        title = "截图晾衣杆"; isReleasedWhenClosed = false; contentView = shelfView
        backgroundColor = .clear; isOpaque = false; hasShadow = false; hidesOnDeactivate = false
        level = .floating; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .none; acceptsMouseMovedEvents = true
        let rail = ShelfRailPanel(contentRect: CGRect(x: screenFrame.minX,y: top-6,width: screenFrame.width,height: 6),
                           styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        rail.title = "截图晾衣杆细线"; rail.isReleasedWhenClosed = false
        rail.backgroundColor = .clear; rail.isOpaque = false; rail.hasShadow = false
        rail.hidesOnDeactivate = false; rail.level = .floating; rail.collectionBehavior = collectionBehavior
        rail.animationBehavior = .none; rail.acceptsMouseMovedEvents = true
        let trigger = ShelfRailView(frame: CGRect(origin: .zero,size: rail.frame.size))
        trigger.onEnter = { [weak self] in self?.hoverEntered() }
        trigger.onExit = { [weak self] in self?.triggerExited() }
        trigger.shelf = self
        rail.contentView = trigger; railPanel = rail
    }
    func expand(preview: Bool = false) {
        guard !disposed else { return }
        work?.cancel(); work = nil; expanded = true
        (railPanel?.contentView as? ShelfRailView)?.showsRope = true
        shelfView.expanded = true
        let height = min(preview ? 420.0 : ShelfRope.detailHeight, max(ShelfRope.detailHeight, screenFrame.height - 80))
        shelfView.ropeOriginX = detailCenterX-railWidth/2-screenFrame.minX
        railPanel?.setFrame(CGRect(x: screenFrame.minX,y: top-ShelfRope.height,width: screenFrame.width,height: ShelfRope.height),display: true)
        setFrame(CGRect(x: detailCenterX-railWidth/2, y: top-height, width: railWidth, height: height), display: true)
        shelfView.prepareLayout()
        shelfView.needsDisplay = true; if presenting { orderFrontRegardless() }
    }
    func collapse() {
        guard !disposed else { return }
        work?.cancel(); work = nil; keyboardSession = false
        stopRope(); shelfView.cancelDrag()
        if isKeyWindow { resignKey() }; expanded = false; shelfView.expanded = false
        shelfView.preview = nil; shelfView.hovered = nil; shelfView.keyboardPointer = nil
        (railPanel?.contentView as? ShelfRailView)?.showsRope = false
        railPanel?.setFrame(CGRect(x: screenFrame.minX,y: top-6,width: screenFrame.width,height: 6),display: true)
        orderOut(nil)
        setFrame(CGRect(x: screenFrame.minX,y: top-6,width: screenFrame.width,height: 6), display: false)
        if presenting { railPanel?.orderFrontRegardless() }
    }
    func scheduleCollapse(after delay: Double = 0.45) {
        work?.cancel()
        guard !keyboardSession, !pullingRope else { work = nil; return }
        let next = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if (self.expanded && self.frame.contains(point)) || self.railFrame.contains(point) { return }
            self.collapse()
        }
        let remaining=ropePull?.releasedAt.map { max(0,ShelfRope.Pull.duration-(ProcessInfo.processInfo.systemUptime-$0))+0.15 } ?? 0
        work = next; DispatchQueue.main.asyncAfter(deadline: .now()+max(delay,remaining), execute: next)
    }
    func hoverEntered() {
        guard !waitsForTriggerExit else { return }
        work?.cancel()
        guard !expanded else { return }
        let next = DispatchWorkItem { [weak self] in self?.expand() }
        work = next; DispatchQueue.main.asyncAfter(deadline: .now()+0.18, execute: next)
    }
    func dismissFromKeyboard(pointer: CGPoint? = nil) {
        let idle = CGRect(x: screenFrame.minX,y: top-6,width: screenFrame.width,height: 6)
        waitsForTriggerExit = idle.contains(pointer ?? NSEvent.mouseLocation)
        collapse()
    }
    func triggerExited() { waitsForTriggerExit = false; scheduleCollapse() }
    func showNotice(_ text: String) {
        work?.cancel(); expanded = true; shelfView.expanded = true; shelfView.notice = text
        let width = min(520, screenFrame.width-32)
        setFrame(CGRect(x: screenFrame.midX-width/2,y: top-64,width: width,height: 64),display: true)
        if presenting { orderFrontRegardless() }
        let next = DispatchWorkItem { [weak self] in self?.dispose() }
        work = next; DispatchQueue.main.asyncAfter(deadline: .now()+2,execute: next)
    }
    func focusForInteraction() { if presenting { makeKeyAndOrderFront(nil) } }
    func beginKeyboardSelection() {
        guard !disposed else { return }
        if !expanded { expand() }; keyboardSession = true
        shelfView.keyboardPointer = NSEvent.mouseLocation
        if presenting { makeKeyAndOrderFront(nil); makeFirstResponder(shelfView) }
    }
    override func resignKey() {
        super.resignKey()
        if keyboardSession { keyboardSession = false; collapse() }
    }
    func pullRope(anchorX: CGFloat, offset: CGSize) {
        guard expanded, !disposed else { return }
        if !pullingRope { heldPose=shelfView.pose }
        pullingRope = true; work?.cancel(); work = nil
        motionTimer?.invalidate(); motionTimer = nil
        ropePull = ShelfRope.Pull(anchor:anchorX/max(1,screenFrame.width),offset:offset,baseline:heldPose)
        renderRope(at:ProcessInfo.processInfo.systemUptime)
    }
    func releaseRope(animated: Bool? = nil) {
        pullingRope = false; heldPose = nil
        guard var pull = ropePull else { return }
        guard animated ?? !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { stopRope(); return }
        pull.releasedAt = ProcessInfo.processInfo.systemUptime
        resumeRope(pull)
    }
    func resumeRope(_ pull: ShelfRope.Pull) {
        guard expanded, !disposed, pull.releasedAt != nil else { return }
        motionTimer?.invalidate(); ropePull = pull
        advanceRope(at:ProcessInfo.processInfo.systemUptime)
        guard ropePull != nil else { return }
        let timer = Timer(timeInterval:1.0/60,target:self,selector:#selector(animateRope),userInfo:nil,repeats:true)
        motionTimer = timer; RunLoop.main.add(timer,forMode:.common)
    }
    @objc private func animateRope() { advanceRope(at:ProcessInfo.processInfo.systemUptime) }
    func advanceRope(at time: Double) {
        guard expanded, !disposed, let started = ropePull?.releasedAt,
              time-started < ShelfRope.Pull.duration else { stopRope(); return }
        renderRope(at:time)
    }
    private func renderRope(at time: Double) {
        let rail = railPanel?.contentView as? ShelfRailView
        let pose=ShelfRope.Pose(pull:ropePull,time:time)
        rail?.pull = ropePull; rail?.motionTime = time; rail?.pose = pose; rail?.needsDisplay = true
        shelfView.pull = ropePull; shelfView.motionTime = time; shelfView.pose = pose; shelfView.needsDisplay = true
    }
    private func stopRope() {
        motionTimer?.invalidate(); motionTimer = nil; ropePull = nil; pullingRope = false; heldPose = nil
        (railPanel?.contentView as? ShelfRailView)?.cancelDrag()
        renderRope(at:ProcessInfo.processInfo.systemUptime)
    }
    func dispose() {
        guard !disposed else { return }; disposed = true; expanded = false; keyboardSession = false; shelfView.expanded = false
        work?.cancel(); work = nil; shelfView.onAction = nil
        stopRope(); shelfView.cancelDrag()
        shelfView.trackingAreas.forEach(shelfView.removeTrackingArea)
        if let view = railPanel?.contentView as? ShelfRailView {
            view.onEnter = nil; view.onExit = nil; view.trackingAreas.forEach(view.removeTrackingArea)
        }
        railPanel?.orderOut(nil); railPanel?.close(); railPanel = nil
        orderOut(nil); close()
    }
}

@MainActor private final class ShelfRailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// This separate six-point window is the only idle mouse target. Expanding
/// details never creates a transparent screen-wide window over other apps.
@MainActor final class ShelfRailView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    weak var shelf: ShelfPanel?
    private var dragOrigin: CGPoint?
    var showsRope = false { didSet { if showsRope != oldValue { needsDisplay = true } } }
    var pull: ShelfRope.Pull?
    var motionTime: Double = 0
    var pose = ShelfRope.Pose()
    override var isFlipped: Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,options: [.inVisibleRect,.mouseEnteredAndExited,.activeAlways],owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { if dragOrigin == nil { onExit?() } }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func mouseDown(with event:NSEvent) {
        let point=convert(event.locationInWindow,from:nil)
        guard showsRope, abs(point.y-pose.point(point.x,width:bounds.width).y)<10 else { return }
        dragOrigin=point; NSCursor.closedHand.set()
        shelf?.pullRope(anchorX:point.x,offset:.zero)
    }
    override func mouseDragged(with event:NSEvent) {
        guard let origin=dragOrigin else { return }
        let point=convert(event.locationInWindow,from:nil)
        shelf?.pullRope(anchorX:origin.x,offset:CGSize(width:point.x-origin.x,height:point.y-origin.y))
    }
    override func mouseUp(with event:NSEvent) {
        guard dragOrigin != nil else { return }
        dragOrigin=nil; NSCursor.arrow.set(); shelf?.releaseRope(); shelf?.scheduleCollapse()
    }
    func cancelDrag() { if dragOrigin != nil { NSCursor.arrow.set() }; dragOrigin=nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        guard showsRope else { return }
        let width = bounds.width
        let rail = NSBezierPath(); rail.move(to:CGPoint(x:0,y:3))
        // Smooth cubic spans avoid hundreds of tiny dashed segments per frame.
        var x:CGFloat=0
        while x < width {
            let end=min(width,x+24)
            let a=pose.point(x,width:width), b=pose.point(end,width:width)
            func tangent(_ value:CGFloat) -> CGPoint {
                let left=max(0,value-1), right=min(width,value+1)
                let p=pose.point(left,width:width), q=pose.point(right,width:width)
                return CGPoint(x:(q.x-p.x)/max(1,right-left),y:(q.y-p.y)/max(1,right-left))
            }
            let ta=tangent(x), tb=tangent(end), step=(end-x)/3
            rail.curve(to:b,controlPoint1:CGPoint(x:a.x+ta.x*step,y:a.y+ta.y*step),
                       controlPoint2:CGPoint(x:b.x-tb.x*step,y:b.y-tb.y*step))
            x=end
        }
        NSColor(calibratedRed:0.52,green:0.39,blue:0.24,alpha:1).setStroke()
        rail.lineWidth=3.8; rail.lineCapStyle = .round; rail.stroke()
        let highlight = rail.copy() as! NSBezierPath
        highlight.transform(using: AffineTransform(translationByX: 0,byY: -0.65))
        NSColor(calibratedRed: 0.91,green: 0.81,blue: 0.62,alpha: 0.9).setStroke()
        highlight.lineWidth = 1; highlight.stroke()
        let twists = NSBezierPath()
        for x in stride(from: CGFloat(2),to: width-2,by: 8) {
            let a=pose.point(x,width:width)
            let b=pose.point(x+3.4,width:width)
            twists.move(to:CGPoint(x:a.x,y:a.y-1.3)); twists.line(to:CGPoint(x:b.x,y:b.y+1.3))
        }
        NSColor(calibratedRed: 0.38,green: 0.28,blue: 0.17,alpha: 0.55).setStroke()
        twists.lineWidth = 0.65; twists.stroke()
    }
}

@MainActor final class ShelfView: NSView {
    enum Action { case preview(UUID), pin(UUID, CGPoint?), copy(UUID), move(UUID, Int), place(UUID,String,[UUID],[UUID:Double]), remove(UUID), undo }
    private(set) var records: [CaptureShelfStore.Item]
    let thumbnails: [UUID: NSImage]
    var onAction: ((Action) -> Void)?
    var canEdit: () -> Bool = { true }
    var displayKey = "default"
    private var layout: CaptureShelfLayout?
    private var dragBaseline: (records:[CaptureShelfStore.Item],layout:CaptureShelfLayout)?
    private var layoutCommitting = false
    private var reflowFrom: [UUID:Double] = [:]
    private var reflowStart: Double = 0
    private var reflowTimer: Timer?
    var hasReflowAnimation: Bool { reflowTimer != nil }
    var expanded = false
    var notice: String?
    var selected: UUID?
    var hovered: UUID?
    var preview: NSImage? { didSet { needsDisplay = true } }
    var ropeWidth: CGFloat = 1
    var ropeOriginX: CGFloat = 0
    var pull: ShelfRope.Pull?
    var motionTime: Double = 0
    var pose = ShelfRope.Pose()
    var keyboardPointer: CGPoint?
    private var scrollRemainder: CGFloat = 0
    private var offset = 0
    private var dragging: (id: UUID, start: CGPoint)?
    private var moved = false
    private var dragPoint: CGPoint?
    private var grab: (point: CGPoint, anchor: CGFloat)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    init(records: [CaptureShelfStore.Item], thumbnails: [UUID: NSImage]) {
        self.records = records; self.thumbnails = thumbnails; selected = records.first?.id
        super.init(frame: .zero)
        toolTip = "单击选中 · 双击贴出 · 横向拖动排序 · 向下拖出贴图 · 左右键选择 · Esc 收起 · Option＋方向键排序 · ⌘C 复制 · Delete 删除 · ⌘Z 撤销"
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("截图晾衣杆，左右选择，回车贴图，Command C 复制，Delete 删除，Command Z 撤销")
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityChildren() -> [Any]? {
        guard expanded else { return [] }
        prepareLayout()
        var children: [Any] = records.indices.filter { $0 >= offset && $0 < offset+capacity }.map { index in
            let item = records[index]
            return ShelfAccessibleItem(view: self, rect: swungBounds(cardRect(index),index:index), title: "贴出图片 \(index+1)，\(item.width) × \(item.height)") { [weak self] in
                self?.onAction?(.pin(item.id,nil))
            }
        }
        if let selected, let index = records.firstIndex(where: { $0.id == selected }), index >= offset, index < offset+capacity {
            children.append(ShelfAccessibleItem(view: self,rect: swungBounds(closeRect(index),index:index),title: "删除选中的图片，可撤销") { [weak self] in self?.onAction?(.remove(selected)) })
        }
        children.append(ShelfAccessibleItem(view: self,rect: CGRect(x: 16,y: ShelfRope.footerY,width: 52,height: 24),title: "撤销删除") { [weak self] in self?.onAction?(.undo) })
        return children
    }
    private var capacity: Int { ShelfRope.capacity(bounds.width) }
    private var cardWidth: CGFloat { min(132, bounds.width-32) }
    func prepareLayout() {
        guard layout == nil, bounds.width > 0 else { return }
        let end=min(records.count,offset+capacity)
        layout=CaptureShelfLayout(items:Array(records[offset..<end]),display:displayKey,width:bounds.width,cardWidth:cardWidth)
        applyOrder()
    }
    private func applyOrder() {
        guard let layout else { return }
        let indexed=Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0) })
        records.replaceSubrange(offset..<min(records.count,offset+capacity),with:layout.order.compactMap { indexed[$0] })
    }
    private func center(_ id:UUID, animated:Bool = true) -> Double {
        let target=layout?.centers[id] ?? 0.5
        guard animated, reflowTimer != nil, let from=reflowFrom[id] else { return target }
        let t=min(1,max(0,(ProcessInfo.processInfo.systemUptime-reflowStart)/0.16))
        let eased=1-pow(1-t,3)
        return from+(target-from)*eased
    }
    private func startReflow(from:[UUID:Double]) {
        reflowTimer?.invalidate(); reflowFrom=from; reflowStart=ProcessInfo.processInfo.systemUptime
        let timer=Timer(timeInterval:1.0/60,target:self,selector:#selector(reflowTick),userInfo:nil,repeats:true)
        reflowTimer=timer; RunLoop.main.add(timer,forMode:.common)
        needsDisplay=true
    }
    @objc private func reflowTick() {
        if ProcessInfo.processInfo.systemUptime-reflowStart >= 0.16 { finishReflow() }
        else { needsDisplay=true }
    }
    func finishReflow() { reflowTimer?.invalidate(); reflowTimer=nil; reflowFrom.removeAll(); needsDisplay=true }
    func completeLayoutCommit() { layoutCommitting=false }
    func applySavedItems(_ items:[CaptureShelfStore.Item],preserveLayout:Bool) {
        records=items; layoutCommitting=false; dragBaseline=nil
        if preserveLayout { applyOrder() }
        else { finishReflow(); layout=nil; prepareLayout() }
        needsDisplay=true
    }
    func cardRect(_ index: Int) -> CGRect {
        prepareLayout()
        let x=CGFloat(center(records[index].id))*bounds.width
        let point=ropePoint(x)
        return CGRect(x:point.x-cardWidth/2,y:point.y+12,width:cardWidth,height:100)
    }
    private func ropePoint(_ x:CGFloat) -> CGPoint {
        let point=pose.point(ropeOriginX+x,width:ropeWidth)
        return CGPoint(x:point.x-ropeOriginX,y:point.y)
    }
    func cancelDrag() {
        if let baseline=dragBaseline { records=baseline.records; layout=baseline.layout }
        dragging=nil; moved=false; dragPoint=nil; grab=nil; dragBaseline=nil
        finishReflow()
    }
    private func closeRect(_ index: Int) -> CGRect {
        let card = cardRect(index)
        let picture = thumbnails[records[index].id].map { hangingPicture($0.size,in:card) } ?? card
        return CGRect(x: picture.maxX-16,y: picture.minY-4,width: 20,height: 20)
    }
    func select(_ id: UUID) {
        prepareLayout(); selected = id
        if let index = records.firstIndex(where: { $0.id == id }) {
            let oldOffset=offset
            if index < offset { offset = index }
            if index >= offset+capacity { offset = index-capacity+1 }
            if offset != oldOffset { finishReflow(); layout=nil; prepareLayout() }
        }
        needsDisplay = true
    }
    private func item(at point: CGPoint) -> Int? {
        prepareLayout()
        let visible=records.indices.filter { $0 >= offset && $0 < offset+capacity }
        let front=visible.filter { records[$0].id == selected }+visible.reversed().filter { records[$0].id != selected }
        return front.first { cardRect($0).contains(unrotated(point,index:$0)) }
    }
    private func hangingPicture(_ size:CGSize,in rect:CGRect) -> CGRect {
        var picture=fit(size,in:rect.insetBy(dx:4,dy:4)); picture.origin.y=rect.minY+4; return picture
    }
    private func hangingPivot(_ index:Int) -> CGPoint {
        let card=cardRect(index); return CGPoint(x:card.midX,y:card.minY+1)
    }
    private func swingAngle(_ index:Int) -> CGFloat {
        pose.angle(ropeOriginX+CGFloat(center(records[index].id))*bounds.width,width:ropeWidth)
    }
    private func unrotated(_ point:CGPoint,index:Int) -> CGPoint {
        ShelfRope.rotate(point,around:hangingPivot(index),angle:-swingAngle(index))
    }
    private func swungBounds(_ rect:CGRect,index:Int) -> CGRect {
        let corners=[CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.minY),
                     CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.maxY)]
            .map { ShelfRope.rotate($0,around:hangingPivot(index),angle:swingAngle(index)) }
        let xs=corners.map(\.x), ys=corners.map(\.y)
        return CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
    }
    private func withSwing(_ index:Int,draw:() -> Void) {
        let pivot=hangingPivot(index)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let transform=NSAffineTransform()
        transform.translateX(by:pivot.x,yBy:pivot.y)
        transform.rotate(byRadians:swingAngle(index)); transform.translateX(by:-pivot.x,yBy:-pivot.y); transform.concat()
        draw()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.inVisibleRect,.mouseEnteredAndExited,.mouseMoved,.activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { (window as? ShelfPanel)?.hoverEntered() }
    override func mouseExited(with event: NSEvent) {
        guard dragging == nil, let panel = window as? ShelfPanel, !panel.keyboardSession else { return }
        let pointer = panel.convertPoint(toScreen: event.locationInWindow)
        guard !panel.frame.contains(pointer) else { return }
        // An in-flight hover preview must not reopen the shelf after exit.
        hovered = nil; panel.scheduleCollapse()
    }
    override func mouseMoved(with event: NSEvent) {
        guard expanded, dragging == nil else { return }
        let pointer = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if let origin = keyboardPointer, hypot(pointer.x-origin.x,pointer.y-origin.y) < 3 { return }
        keyboardPointer = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let index = item(at: point) else { return }
        let id = records[index].id
        if hovered != id { hovered = id; selected = id; preview = nil; onAction?(.preview(id)); needsDisplay = true }
    }
    override func resetCursorRects() {
        if expanded { addCursorRect(CGRect(x: 12,y: 10,width: bounds.width-24,height: ShelfRope.footerY-12), cursor: .openHand) }
    }
    override func mouseDown(with event: NSEvent) {
        guard expanded, !layoutCommitting, canEdit() else { return }; if let panel = window as? ShelfPanel { panel.focusForInteraction() }; window?.makeFirstResponder(self)
        keyboardPointer = nil
        let point = convert(event.locationInWindow, from: nil)
        if point.y > ShelfRope.footerY && point.y < ShelfRope.footerY+28 {
            if point.x < 70 { onAction?(.undo) }
            return
        }
        guard let index = item(at: point) else { return }
        let id = records[index].id; selected = id
        if closeRect(index).contains(unrotated(point,index:index)) { onAction?(.remove(id)); return }
        finishReflow(); prepareLayout()
        if let layout { dragBaseline=(records,layout) }
        grab=(point,ropeOriginX+CGFloat(center(id,animated:false))*bounds.width)
        dragging = (id, window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow); moved = false; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        let point = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        if hypot(point.x-dragging.start.x,point.y-dragging.start.y) > 4 { moved = true; NSCursor.closedHand.set() }
        guard moved else { return }
        let local = convert(event.locationInWindow, from: nil)
        dragPoint = local
        if let grab {
            let fraction=layout?.clamped(Double((grab.anchor-ropeOriginX+local.x-grab.point.x)/max(1,bounds.width))) ?? 0.5
            (window as? ShelfPanel)?.pullRope(anchorX:CGFloat(fraction)*bounds.width+ropeOriginX,
                offset:CGSize(width:local.x-grab.point.x,height:local.y-grab.point.y))
        }
        if let grab, var next=layout {
            let target=Double((grab.anchor-ropeOriginX+local.x-grab.point.x)/max(1,bounds.width))
            let current=Dictionary(uniqueKeysWithValues:next.order.map { ($0,center($0)) })
            if next.drag(dragging.id,to:target) {
                layout=next; applyOrder(); startReflow(from:current)
            }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let drag=dragging else { return }
        let point=convert(event.locationInWindow,from:nil)
        var action:Action?
        if moved {
            (window as? ShelfPanel)?.releaseRope()
            if point.y > ShelfRope.detailHeight {
                let location=window?.convertPoint(toScreen:event.locationInWindow)
                cancelDrag(); action = .pin(drag.id,location)
            } else if let grab, var next=layout {
                next.drop(drag.id,at:Double((grab.anchor-ropeOriginX+point.x-grab.point.x)/max(1,bounds.width)))
                layout=next; applyOrder(); reflowFrom.removeValue(forKey:drag.id)
                dragBaseline=nil; layoutCommitting=true
                action = .place(drag.id,displayKey,records.map(\.id),next.centers)
            }
        } else if event.clickCount >= 2 { action = .pin(drag.id,nil) }
        else { hovered=drag.id; preview=nil; action = .preview(drag.id) }
        dragging=nil; moved=false; dragPoint=nil; grab=nil; dragBaseline=nil; NSCursor.openHand.set()
        needsDisplay=true
        if let action { onAction?(action) }
        if let panel=window as? ShelfPanel, !panel.frame.contains(NSEvent.mouseLocation) { panel.scheduleCollapse() }
    }

    private func scrollItems(_ steps: Int) {
        finishReflow(); layout=nil
        offset = max(0,min(max(0,records.count-capacity),offset+steps))
        prepareLayout()
        hovered = nil; preview = nil; needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        guard expanded, !layoutCommitting, dragging == nil, event.momentumPhase.isEmpty else { return }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        guard records.count > capacity else { return }
        if event.hasPreciseScrollingDeltas {
            if event.phase.contains(.began) { scrollRemainder = 0 }
            scrollRemainder = max(-128,min(128,scrollRemainder-delta))
            let steps = Int(scrollRemainder/32)
            if steps != 0 { scrollRemainder -= CGFloat(steps)*32; scrollItems(steps) }
        } else if delta != 0 { scrollItems(delta < 0 ? 1 : -1) }
    }
    @objc func copy(_ sender: Any?) {
        guard expanded, let selected else { return }; onAction?(.copy(selected))
    }
    @objc func undo(_ sender: Any?) { if expanded { onAction?(.undo) } }
    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        if event.keyCode == 53 { (window as? ShelfPanel)?.dismissFromKeyboard(); return }
        if command && event.charactersIgnoringModifiers?.lowercased() == "z" { undo(nil); return }
        guard !layoutCommitting, canEdit(), let selected else { return }
        if command && event.charactersIgnoringModifiers?.lowercased() == "c" { copy(nil); return }
        if event.keyCode == 36 { onAction?(.pin(selected,nil)); return }
        if event.keyCode == 51 || event.keyCode == 117 { onAction?(.remove(selected)); return }
        if event.keyCode == 123 || event.keyCode == 124 {
            let index = max(0,min(records.count-1,(records.firstIndex { $0.id == selected } ?? 0)+(event.keyCode == 124 ? 1 : -1)))
            if event.modifierFlags.contains(.option) {
                prepareLayout()
                let other=records[index].id
                if var next=layout, next.centers[other] != nil {
                    let from=Dictionary(uniqueKeysWithValues:next.order.map { ($0,center($0)) })
                    next.swap(selected,other); layout=next; applyOrder(); startReflow(from:from)
                    layoutCommitting=true; onAction?(.place(selected,displayKey,records.map(\.id),next.centers))
                } else { onAction?(.move(selected,index)) }
                return
            }
            keyboardPointer = NSEvent.mouseLocation
            select(records[index].id)
            hovered = self.selected; if let hovered { onAction?(.preview(hovered)) }; needsDisplay = true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using:.copy)
        guard expanded else { return }
        if let notice {
            pill(notice,in: bounds.insetBy(dx: 1,dy: 1),size: 12); return
        }
        prepareLayout()
        // Individual pencil frames identify attached images without bringing
        // back a paper container around the whole shelf.
        let visible=records.indices.filter { $0 >= offset && $0 < offset+capacity }
        let paintOrder=visible.filter { records[$0].id != selected }+visible.filter { records[$0].id == selected }
        for index in paintOrder {
            let item = records[index], rect = cardRect(index)
            let anchor=ropePoint(CGFloat(center(item.id))*bounds.width)
            if !(moved && dragging?.id == item.id) {
                if let image = thumbnails[item.id] {
                    withSwing(index) { drawFramedImage(image,in:rect,attachment:CGPoint(x:anchor.x,y:anchor.y+13)) }
                }
                drawClip(at:anchor,selected:selected == item.id)
            }
            if !moved && (hovered == item.id || selected == item.id) {
                withSwing(index) {
                    let close = closeRect(index)
                    NSColor.white.withAlphaComponent(0.95).setFill()
                    NSBezierPath(ovalIn: close).fill()
                    label("×",at: CGPoint(x: close.minX+4,y: close.minY),size: 16)
                }
            }
        }
        if moved, let dragPoint, let dragging, let grab, let image = thumbnails[dragging.id] {
            let ropeX=CGFloat(layout?.clamped(Double((grab.anchor-ropeOriginX+dragPoint.x-grab.point.x)/max(1,bounds.width))) ?? 0.5)*bounds.width+ropeOriginX
            let anchor=ropePoint(ropeX-ropeOriginX)
            let ghost=CGRect(x:anchor.x-cardWidth/2,y:anchor.y+12,width:cardWidth,height:100)
            drawFramedImage(image,in:ghost,opacity:0.95,attachment:CGPoint(x:anchor.x,y:anchor.y+13))
            drawClip(at:anchor,selected:true)
        }
        pill("撤销",in: CGRect(x: 16,y: ShelfRope.footerY,width: 52,height: 24),size: 11)
        if bounds.width > 430 { pill("← → 选择 · ⌘C 复制 · Esc 收起",in: CGRect(x: 82,y: ShelfRope.footerY,width: 225,height: 24),size: 11) }
        if records.count > capacity {
            pill("\(offset+1)–\(min(records.count,offset+capacity))/\(records.count) · 横向滚动",in: CGRect(x: bounds.width-155,y: ShelfRope.footerY,width: 139,height: 24),size: 11)
        } else { pill("\(records.count) 张",in: CGRect(x: bounds.width-63,y: ShelfRope.footerY,width: 47,height: 24),size: 11) }
        if let preview, bounds.height > ShelfRope.detailHeight {
            let area = CGRect(x:16,y:ShelfRope.detailHeight+8,width:bounds.width-32,height:bounds.height-ShelfRope.detailHeight-24)
            drawFramedImage(preview,in: area)
        }
    }
    private func drawClip(at point:CGPoint, selected:Bool) {
        let clip=CGRect(x:point.x-5,y:point.y-5,width:10,height:18)
        (selected ? SketchPalette.blue : SketchPalette.yellow).setFill()
        NSBezierPath(roundedRect:clip,xRadius:2,yRadius:2).fill()
        SketchPencil.stroke(NSBezierPath(roundedRect:clip,xRadius:2,yRadius:2),color:SketchPalette.line,width:0.6)
    }
    private func drawFramedImage(_ image: NSImage, in rect: CGRect, opacity: CGFloat = 1, attachment: CGPoint? = nil) {
        let picture = attachment == nil ? fit(image.size,in:rect.insetBy(dx:4,dy:4)) : hangingPicture(image.size,in:rect)
        if let attachment, picture.minY > attachment.y {
            let tie = NSBezierPath(); tie.move(to: attachment)
            tie.line(to: CGPoint(x: picture.midX,y: picture.minY))
            SketchPencil.stroke(tie,color: SketchPalette.line,width: 1.6)
        }
        image.draw(in: picture,from: .zero,operation: .sourceOver,fraction: opacity,
                   respectFlipped: true,hints: [.interpolation:NSImageInterpolation.high])
        let frame = SketchPencil.outline(in: picture.insetBy(dx: -2,dy: -2),radius: 3)
        SketchPencil.stroke(frame,color: SketchPalette.ink.withAlphaComponent(opacity),width: 3.8)
    }
    private func pill(_ text: String, in rect: CGRect, size: CGFloat) {
        SketchPalette.paper.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: rect,xRadius: 5,yRadius: 5).fill()
        let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize: size),.foregroundColor:SketchPalette.ink]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX-measured.width/2,y: rect.midY-measured.height/2),withAttributes: attributes)
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
