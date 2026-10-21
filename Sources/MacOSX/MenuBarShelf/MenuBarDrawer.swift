import AppKit
import ApplicationServices

@MainActor private final class MenuDrawerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A bounded, event-driven drawer. Its entries are app identities backed by
/// freshly read AX extras; menus are always opened by their owning process.
@MainActor final class MenuBarDrawer {
    var onChange: (() -> Void)?
    var anchorProvider: (() -> CGRect?)?
    private(set) var active = false
    private(set) var issue: String?
    private(set) var busy = false
    private(set) var hidden = false
    private(set) var order: [String]
    private(set) var entries: [MenuBarEntry] = []
    let view = MenuBarDrawerView(frame: .zero)
    let input = MenuBarDrawerInput()
    private let defaults: UserDefaults
    private let visibility: MenuVisibilityProviding
    private let inventory = MenuBarInventory()
    private var restriction: MenuVisibilityHandle?
    private var readToken: MenuBarReadToken?
    private var actionToken: MenuBarReadToken?
    private var reading = false
    private var readDate: TimeInterval = 0
    private var generation = 0
    private var restrictionGeneration = 0
    private var menuGeneration = 0
    private var dismissWork: DispatchWorkItem?
    private var watchdog: DispatchWorkItem?
    private var menuWatch: MenuBarMenuWatch?
    private var reapplyOnHover = false
    private var panel: MenuDrawerPanel?
    private var ghost: NSPanel?
    private var dragSource: MenuBarEntry?
    private var dragOrigin = CGPoint.zero
    private var dragMoved = false
    private var anchor: CGRect?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?
    private var localMonitor: Any?
    private var pendingAfterRead: (() -> Void)?
    private var appIcons: [String: MenuDrawerItem] = [:]
    var permissionOverride: Bool?
    var readOverride: ((MenuBarReadToken, @escaping ([MenuBarEntry]) -> Void) -> Void)?
    var pressOverride: ((MenuBarEntry, MenuBarReadToken, @escaping (Bool) -> Void) -> Void)?
    var testNoPresentation = false
    var testSkipInput = false
    var activationTimeout: TimeInterval = 4
    var dismissDelay: TimeInterval = 1.2
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    var isOpen: Bool { panel?.isVisible == true || (testNoPresentation && openForTest) }
    private var openForTest = false
    private var selectionKey = "menuBarShelf.drawerBundles.v1"
    var permitted: Bool { permissionOverride ?? AXIsProcessTrusted() }
    init(defaults: UserDefaults, visibility: MenuVisibilityProviding) {
        self.defaults = defaults; self.visibility = visibility
        var seen = Set<String>()
        order = (defaults.stringArray(forKey: "menuBarShelf.drawerBundles.v1") ?? []).prefix(64).filter {
            !$0.isEmpty && $0.count < 256 && !MenuBarSections.systemOwners.contains($0) && seen.insert($0).inserted
        }
        order = Array(order.prefix(40)); order.removeAll { $0 == Bundle.main.bundleIdentifier }
        view.onClose = { [weak self] in self?.close() }
        view.onPresence = { [weak self] inside in self?.presence(inside) }
        view.onInteraction = { [weak self] in self?.dismissWork?.cancel(); self?.dismissWork = nil }
        view.onMove = { [weak self] bundle, index in self?.move(bundle, to: index) }
        view.onRestore = { [weak self] bundle, point in self?.restore(bundle, at: point) }
        view.onOpen = { [weak self] bundle in self?.openMenu(bundle) }
        input.canBegin = { [weak self] in self?.active == true && self?.busy == false }
        input.onCancel = { [weak self] in self?.cancelDrag(); self?.presence(false) }
        input.onPrepare = { [weak self] in self?.prepareDrag() }
        input.onBegin = { [weak self] entry, point in self?.beginDrag(entry, at: point) }
        input.onDrag = { [weak self] point in self?.drag(to: point) }
        input.onEnd = { [weak self] point in self?.finishDrag(at: point) }
    }
    func start() {
        guard !active else { return }; active = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.environmentChanged() }
        })
        installInput()
        // Persisted choices may be reapplied, but an empty new module does no
        // launch-time cross-app scan, hiding, permission prompt or screen capture.
        if !order.isEmpty, permitted { readEntries(force: true) { [weak self] in self?.apply() } }
        changed()
    }
    func stop() {
        guard active else { return }; active = false; generation += 1; restrictionGeneration += 1
        readToken?.cancel(); readToken = nil; actionToken?.cancel(); actionToken = nil
        reading = false; busy = false; pendingAfterRead = nil
        dismissWork?.cancel(); dismissWork = nil; watchdog?.cancel(); watchdog = nil
        menuWatch?.cancel(); menuWatch = nil; reapplyOnHover = false
        restriction?.invalidate(); restriction = nil; hidden = false
        input.stop(); removeMonitors(); close(); cancelDrag()
        panel?.contentView = nil; panel?.close(); panel = nil
        view.items = []; view.selected = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer); NotificationCenter.default.removeObserver(observer) }
        observers.removeAll(); entries.removeAll(); appIcons.removeAll(); issue = nil; changed()
    }
    private func installInput() {
        guard active, permitted else { input.stop(); return }
        guard visibility.available else {
            input.stop(); issue = "当前系统的隐藏接口暂不可用，已保留全部图标。"; return
        }
        input.enabled = true
        if !testSkipInput, !input.start() { input.enabled = false; issue = "拖动监听暂不可用；可在下面点击图标收纳。" }
    }
    func hover(_ frame: CGRect, inside: Bool) {
        anchor = frame
        guard active else { return }
        if inside {
            show(); prepareDrag()
            if reapplyOnHover { reapplyOnHover = false; apply() }
        } else { presence(false) }
    }
    func toggle() {
        guard active else { return }
        if isOpen { close() } else { show(); prepareDrag() }
    }
    func show() {
        guard active, let anchor = anchorProvider?() ?? anchor else { return }
        self.anchor = anchor; dismissWork?.cancel(); dismissWork = nil
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        guard let screen else { return }
        let width = min(max(280, CGFloat(min(8, max(4, order.count))) * 64 + 24), max(220, screen.visibleFrame.width - 24))
        let height = min(MenuBarDrawerView.height(count: order.count, width: width), screen.visibleFrame.height - 24)
        let origin = CGPoint(x: max(screen.visibleFrame.minX + 8, min(anchor.midX - width / 2, screen.visibleFrame.maxX - width - 8)), y: min(anchor.minY, screen.visibleFrame.maxY) - height - 4)
        if panel == nil {
            let panel = MenuDrawerPanel(contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentView = view; self.panel = panel
        }
        panel?.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        view.frame.size = CGSize(width: width, height: height)
        updateView()
        if testNoPresentation { openForTest = true } else { panel?.orderFrontRegardless() }
        installMonitors()
    }
    func close() {
        dismissWork?.cancel(); dismissWork = nil; panel?.orderOut(nil); openForTest = false
        removeMonitors(); view.accepting = false
    }
    func contains(_ point: CGPoint) -> Bool {
        if let anchor = anchorProvider?() ?? anchor, anchor.insetBy(dx: -5, dy: -7).contains(point) { return true }
        if isOpen, let frame = panel?.frame {
            // The connector corridor prevents a 4-point menu/panel gap from
            // generating an exit while crossing into the drawer.
            let bridge = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: 12)
            return frame.insetBy(dx: -5, dy: -5).contains(point) || bridge.contains(point)
        }
        return false
    }
    func presence(_ inside: Bool) {
        if inside || contains(pointer()) {
            dismissWork?.cancel(); dismissWork = nil; return
        }
        guard active, isOpen, dismissWork == nil, dragSource == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }; self.dismissWork = nil
            guard self.active, !self.contains(self.pointer()), self.dragSource == nil, !self.busy, !self.reading,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.close()
        }
        dismissWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }
    private func installMonitors() {
        guard monitor == nil, !testNoPresentation else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseUp]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.presence(self.contains(self.pointer())) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }; self.presence(self.contains(self.pointer())); return event
        }
    }
    private func removeMonitors() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    func prepareDrag() {
        guard active else { return }
        guard permitted else { issue = "需要辅助功能权限来读取和操作真实菜单栏图标。"; changed(); return }
        installInput()
        readEntries(force: false)
    }
    func readEntries(force: Bool, after: (() -> Void)? = nil) {
        guard active, permitted else { after?(); return }
        if reading { if let after { pendingAfterRead = after }; return }
        if !force, ProcessInfo.processInfo.systemUptime - readDate < 2 { after?(); return }
        reading = true; generation += 1; let expected = generation
        let token = MenuBarReadToken(); readToken?.cancel(); readToken = token
        let receive: ([MenuBarEntry]) -> Void = { [weak self] entries in
            guard let self, self.active, self.generation == expected, !token.isCancelled else { return }
            self.reading = false; self.readToken = nil; self.readDate = ProcessInfo.processInfo.systemUptime
            let own = Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"
            self.entries = Array(entries.filter { !MenuBarSections.systemOwners.contains($0.bundle) && $0.bundle != own }.prefix(512))
            self.input.entries = self.entries.filter { !self.order.contains($0.bundle) }
            self.appIcons.removeAll(); self.changed()
            after?(); let pending = self.pendingAfterRead; self.pendingAfterRead = nil; pending?()
            self.presence(self.contains(self.pointer()))
        }
        if let readOverride { readOverride(token, receive) }
        else {
            let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.pathExtension == "app" }
                .compactMap { app -> (pid_t, String)? in guard let bundle = app.bundleIdentifier else { return nil }; return (app.processIdentifier, bundle) }
            inventory.read(apps, token: token, completion: receive)
        }
    }
    func item(_ bundle: String) -> MenuDrawerItem {
        if let item = appIcons[bundle] { return item }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        let name = running?.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? bundle.split(separator: ".").last.map(String.init) ?? bundle
        let icon = running?.icon ?? url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        icon?.size = CGSize(width: 32, height: 32)
        let item = MenuDrawerItem(bundle: bundle, name: name, icon: icon, available: running != nil || entries.contains { $0.bundle == bundle })
        if appIcons.count < 128 { appIcons[bundle] = item }; return item
    }
    var drawerItems: [MenuDrawerItem] { order.map { item($0) } }
    var visibleItems: [MenuDrawerItem] {
        var seen = Set(order)
        return entries.filter { seen.insert($0.bundle).inserted }.prefix(64).map { item($0.bundle) }
    }
    func add(_ bundle: String, at index: Int? = nil) {
        guard active, permitted, visibility.available, !busy, !order.contains(bundle), order.count < 40,
              bundle != Bundle.main.bundleIdentifier, !MenuBarSections.systemOwners.contains(bundle),
              entries.contains(where: { $0.bundle == bundle }) else { return }
        var next = order; next.insert(bundle, at: min(max(0, index ?? order.count), order.count))
        apply(next: next)
    }
    func move(_ bundle: String, to index: Int) {
        guard !busy, let old = order.firstIndex(of: bundle) else { updateView(); return }
        var next = order; next.remove(at: old); next.insert(bundle, at: max(0, min(index, next.count)))
        order = next; persist(); changed()
    }
    func restore(_ bundle: String, at point: CGPoint? = nil) {
        guard active, !busy, order.contains(bundle) else { return }
        let next = order.filter { $0 != bundle }
        apply(next: next) { [weak self] success in
            guard let self, success else { return }
            guard let point, self.inMenuBand(point) else { return }
            self.readEntries(force: true) { [weak self] in
                guard let self, let source = self.entries.first(where: { $0.bundle == bundle }) else { return }
                let top = NSScreen.screens.first?.frame.maxY ?? 0
                self.busy = true
                MenuBarDrawerInput.move(from: CGPoint(x: source.frame.midX, y: source.frame.midY), to: CGPoint(x: point.x, y: top - point.y)) { [weak self] in self?.busy = false; self?.changed() }
            }
        }
    }
    /// Transactional membership: persist and report hidden only after native
    /// activation succeeds; failures keep the last confirmed order visible.
    func apply(next: [String]? = nil, completion: ((Bool) -> Void)? = nil) {
        guard active, !busy else { completion?(false); return }
        let proposed = next ?? order
        guard permitted, visibility.available else {
            showAll(); issue = permitted ? "当前系统暂不支持抽屉隐藏，图标已全部恢复。" : "请先授予辅助功能权限。"; changed(); completion?(false); return
        }
        menuWatch?.cancel(); menuWatch = nil; reapplyOnHover = false
        menuGeneration += 1; actionToken?.cancel(); actionToken = nil
        restrictionGeneration += 1; let expected = restrictionGeneration
        restriction?.invalidate(); restriction = nil; hidden = false
        if proposed.isEmpty { order = []; persist(); issue = nil; changed(); completion?(true); return }
        let confirmed = Set(entries.map(\.bundle)).intersection(proposed)
        guard !confirmed.isEmpty else {
            issue = "未读到已收纳应用的菜单栏入口，图标保持显示。"; changed(); completion?(false); return
        }
        busy = true; changed()
        let all = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .union(MenuBarSections.systemOwners).union([Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"])
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.restrictionGeneration == expected else { return }
            self.restrictionGeneration += 1; self.watchdog = nil; self.busy = false
            self.issue = "系统隐藏响应超时，图标已恢复；可重试。"; self.changed(); completion?(false)
        }
        watchdog = work; DispatchQueue.main.asyncAfter(deadline: .now() + activationTimeout, execute: work)
        visibility.activate(allowing: Array(all.subtracting(confirmed)).sorted()) { [weak self] handle in
            guard let self, self.active, self.restrictionGeneration == expected else { handle?.invalidate(); return }
            self.watchdog?.cancel(); self.watchdog = nil; self.busy = false
            self.restriction = handle; self.hidden = handle != nil
            if handle != nil { self.order = proposed; self.persist(); self.issue = nil }
            else { self.issue = "系统未能收纳，图标已恢复；请重试。" }
            self.changed(); completion?(handle != nil)
            self.presence(self.contains(self.pointer()))
        }
    }
    func showAll() {
        menuGeneration += 1; actionToken?.cancel(); actionToken = nil
        restrictionGeneration += 1; watchdog?.cancel(); watchdog = nil
        restriction?.invalidate(); restriction = nil; hidden = false; busy = false
        menuWatch?.cancel(); menuWatch = nil; reapplyOnHover = false; issue = nil; changed()
    }
    func openMenu(_ bundle: String) {
        guard active, !busy else { return }
        guard permitted else { issue = "请先授予辅助功能权限。"; changed(); return }
        showAll(); close(); let expectedMenu = menuGeneration
        readEntries(force: true) { [weak self] in
            guard let self, self.active, self.menuGeneration == expectedMenu else { return }
            guard let entry = self.entries.first(where: { $0.bundle == bundle }) else {
                self.issue = "这个应用的菜单栏入口暂不可读；已展开全部图标。"; self.changed(); return
            }
            let token = MenuBarReadToken(); self.actionToken?.cancel(); self.actionToken = token
            let receive: (Bool) -> Void = { [weak self] success in
                guard let self, self.active, !token.isCancelled else { return }
                self.actionToken = nil
                if !success { self.issue = "应用未响应菜单操作；已展开真实菜单栏，可直接点击。"; self.changed(); return }
                self.reapplyOnHover = true
            }
            if let pressOverride = self.pressOverride { pressOverride(entry, token, receive) }
            else {
                let expected = self.restrictionGeneration
                self.inventory.press(entry, token: token, onClosed: { [weak self] in
                    DispatchQueue.main.async {
                        guard let self, self.active, self.restrictionGeneration == expected else { return }
                        self.menuWatch?.cancel(); self.menuWatch = nil
                        // Let the owning process finish its menu command first.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            guard let self, self.active, self.restrictionGeneration == expected else { return }
                            self.apply()
                        }
                    }
                }) { [weak self] ok, watch in
                    guard let self, self.active, !token.isCancelled else { watch?.cancel(); return }
                    self.menuWatch = watch; receive(ok)
                }
            }
        }
    }
    func beginDrag(_ entry: MenuBarEntry, at point: CGPoint) {
        guard active, !busy else { return }
        dragSource = entry; dragOrigin = point; dragMoved = false; dismissWork?.cancel(); dismissWork = nil
        show(); view.accepting = true
    }
    func drag(to point: CGPoint) {
        guard let entry = dragSource else { return }
        dragMoved = dragMoved || hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) > 4
        guard dragMoved else { return }
        view.accepting = contains(point)
        if ghost == nil, !testNoPresentation {
            let panel = NSPanel(contentRect: CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false
            let image = NSImageView(frame: CGRect(x: 2, y: 2, width: 32, height: 32)); image.image = item(entry.bundle).icon
            panel.contentView?.addSubview(image); ghost = panel; panel.orderFrontRegardless()
        }
        ghost?.setFrameOrigin(CGPoint(x: point.x - 18, y: point.y - 18))
    }
    func finishDrag(at point: CGPoint) {
        guard let source = dragSource else { return }
        let moved = dragMoved; cancelDrag()
        guard moved else { return }
        if contains(point) { add(source.bundle); show() }
        else if inMenuBand(point) {
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            busy = true
            MenuBarDrawerInput.move(from: CGPoint(x: source.frame.midX, y: source.frame.midY), to: CGPoint(x: point.x, y: top - point.y)) { [weak self] in
                self?.busy = false; self?.readDate = 0; self?.prepareDrag(); self?.presence(false)
            }
        } else { presence(false) }
    }
    private func cancelDrag() { dragSource = nil; dragMoved = false; ghost?.close(); ghost = nil; view.accepting = false }
    private func inMenuBand(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }
    }
    private func persist() { defaults.set(order, forKey: selectionKey); input.entries = entries.filter { !order.contains($0.bundle) } }
    private func changed() { if isOpen { show() } else { updateView() }; onChange?() }
    private func updateView() {
        view.items = drawerItems
        view.message = issue ?? (order.isEmpty ? "⌘ 拖入图标，收纳在这里" : "点击打开 · ⌘ 拖动排序，拖出恢复")
    }
    private func environmentChanged() {
        generation += 1; readToken?.cancel(); readToken = nil; reading = false; pendingAfterRead = nil
        actionToken?.cancel(); actionToken = nil; entries.removeAll(); input.entries.removeAll(); appIcons.removeAll(); readDate = 0
        cancelDrag(); close(); showAll(); reapplyOnHover = !order.isEmpty
    }
    var hasDismissWork: Bool { dismissWork != nil }
}
