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
    private let iconCapture = MenuBarIconCapture()
    let menuInteraction = MenuBarNativeInteraction()
    private var interactionRestriction: MenuVisibilityHandle?
    private var restoringInteraction = false
    private var interactionRequested = false
    private var originalIcons: [String: NSImage] = [:]
    private var iconCosts: [String: Int] = [:]
    private var restriction: MenuVisibilityHandle?
    private var readToken: MenuBarReadToken?
    private var actionToken: MenuBarReadToken?
    private var reading = false
    private var readWatchdog: DispatchWorkItem?
    var iconReadTimeout: TimeInterval = 4
    private var readDate: TimeInterval = 0
    private var generation = 0
    private var restrictionGeneration = 0
    private var menuGeneration = 0
    private var movementGeneration = 0
    private var dismissWork: DispatchWorkItem?
    private var dismissGeneration: UInt64 = 0
    private var watchdog: DispatchWorkItem?
    private var menuWatch: MenuBarMenuWatch?
    private var reapplyOnHover = false
    private var wantsCollapsed = false
    private var recoveryWork: DispatchWorkItem?
    private var recoveryGeneration: UInt64 = 0
    private var menuBundle: String?
    private var panel: MenuDrawerPanel?
    private var ghost: NSPanel?
    private var settlingGhost: NSPanel?
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
    var iconReadOverride: (([MenuBarEntry], MenuBarReadToken, @escaping ([String: MenuBarIconPixels]) -> Void) -> Void)?
    var pressOverride: ((MenuBarEntry, MenuBarReadToken, @escaping (Bool) -> Void) -> Void)?
    var testNoPresentation = false
    var testSkipInput = false
    var testSkipEnvironment = false
    var activationTimeout: TimeInterval = 4
    var menuInteractionTimeout: TimeInterval = 11
    var dismissDelay: TimeInterval = 1.2
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    var pressedButtons: () -> Int = { Int(NSEvent.pressedMouseButtons) }
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
        view.onInteraction = { [weak self] in self?.cancelDismissal(); self?.presence(false) }
        view.onMove = { [weak self] bundle, index in self?.move(bundle, to: index) }
        view.onRestore = { [weak self] bundle, point in self?.restore(bundle, at: point) }
        view.onOpen = { [weak self] bundle in self?.openMenu(bundle) }
        view.onActivate = { [weak self] bundle, samples in self?.openMenu(bundle, samples: samples) }
        view.onDragImage = { [weak self] item, point in self?.showDragImage(item, at: point) }
        view.onDragFinished = { [weak self] in self?.settleDragImage(); self?.presence(false) }
        input.canBegin = { [weak self] in self?.active == true && self?.busy == false }
        input.onCancel = { [weak self] in self?.cancelDrag(); self?.presence(false) }
        input.onPrepare = { [weak self] in self?.prepareDrag() }
        input.onBegin = { [weak self] entry, point in self?.beginDrag(entry, at: point) }
        input.onDrag = { [weak self] point in self?.drag(to: point) }
        input.onEnd = { [weak self] point in self?.finishDrag(at: point) }
    }
    func start() {
        guard !active else { return }; active = true
        if !testSkipEnvironment {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    MainActor.assumeIsolated {
                        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                        self?.environmentChanged(rebuild: false, application: app?.bundleIdentifier)
                    }
                })
            }
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged(rebuild: true) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged(rebuild: true) }
            })
        }
        installInput()
        // Persisted choices may be reapplied, but an empty new module does no
        // launch-time cross-app scan, hiding, permission prompt or screen capture.
        wantsCollapsed = !order.isEmpty
        if wantsCollapsed, permitted { readEntries(force: true) { [weak self] in self?.apply() } }
        changed()
    }
    func stop() {
        guard active else { return }; active = false; wantsCollapsed = false; cancelRecovery(); generation += 1; restrictionGeneration += 1; movementGeneration += 1
        cancelMenuInteraction()
        readToken?.cancel(); readToken = nil; readWatchdog?.cancel(); readWatchdog = nil; actionToken?.cancel(); actionToken = nil
        reading = false; busy = false; pendingAfterRead = nil
        iconCapture.clear(); originalIcons.removeAll(); iconCosts.removeAll()
        cancelDismissal(); watchdog?.cancel(); watchdog = nil
        menuWatch?.cancel(); menuWatch = nil; menuBundle = nil; reapplyOnHover = false
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
            // Tracking events can arrive after the pointer has already crossed
            // into another window; never reopen from an obsolete enter event.
            guard frame.insetBy(dx: -5, dy: -7).contains(pointer()) else { presence(false); return }
            cancelDismissal(); show()
            if reapplyOnHover, wantsCollapsed {
                reapplyOnHover = false; installInput()
                readEntries(force: true) { [weak self] in
                    guard let self, self.active, self.wantsCollapsed else { return }
                    self.apply()
                }
            } else { prepareDrag() }
        } else { presence(false) }
    }
    func toggle() {
        guard active else { return }
        if isOpen { close() } else { show(); prepareDrag() }
    }
    func show() {
        guard active, let anchor = anchorProvider?() ?? anchor else { return }
        self.anchor = anchor
        let wasOpen = isOpen
        if !wasOpen { cancelDismissal() }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
        guard let screen else { return }
        let icons = drawerItems
        var width = min(max(icons.isEmpty ? 144 : 48, min(620, MenuBarDrawerView.rowWidth(icons))), max(220, screen.visibleFrame.width - 24))
        var height = min(MenuBarDrawerView.height(items: icons, width: width), screen.visibleFrame.height - 24)
        var origin = CGPoint(x: max(screen.visibleFrame.minX + 8, min(anchor.midX - width / 2, screen.visibleFrame.maxX - width - 8)), y: min(anchor.minY, screen.visibleFrame.maxY) - height - 4)
        if wasOpen, let previous = panel?.frame, screen.frame.contains(CGPoint(x: previous.midX, y: previous.midY)) {
            // Membership and native menu-bar reflow must not move the drawer
            // out from under the pointer. Shrink only on the next opening.
            width = max(width, previous.width); height = max(height, previous.height)
            origin.x = max(screen.visibleFrame.minX + 8, min(previous.minX, screen.visibleFrame.maxX - width - 8))
            origin.y = previous.maxY - height
        }
        if panel == nil {
            let panel = MenuDrawerPanel(contentRect: CGRect(origin: origin, size: CGSize(width: width, height: height)), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentView = view; self.panel = panel
        }
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        if panel?.frame != frame { panel?.setFrame(frame, display: true) }
        if view.frame.size != frame.size { view.frame.size = frame.size }
        updateView()
        if testNoPresentation { openForTest = true } else if panel?.isVisible != true { panel?.orderFrontRegardless() }
        installMonitors()
    }
    func close() {
        cancelDismissal(); panel?.orderOut(nil); openForTest = false
        removeMonitors(); view.cancelDrag(); view.accepting = false
    }
    func contains(_ point: CGPoint) -> Bool {
        let anchor = anchorProvider?() ?? anchor
        if let anchor, anchor.insetBy(dx: -5, dy: -7).contains(point) { return true }
        if isOpen, let frame = panel?.frame {
            if frame.insetBy(dx: -5, dy: -5).contains(point) { return true }
            // Join the actual apple and the stable drawer even when native
            // icon hiding moves the apple horizontally in the menu bar.
            guard anchor.map({ abs($0.minY - frame.maxY) <= 40 }) ?? true else { return false }
            let left = min(frame.minX, anchor?.minX ?? frame.minX) - 5
            let right = max(frame.maxX, anchor?.maxX ?? frame.maxX) + 5
            let top = max(frame.maxY + 12, anchor?.minY ?? frame.maxY) + 7
            return CGRect(x: left, y: frame.maxY - 5, width: right - left, height: top - frame.maxY + 5).contains(point)
        }
        return false
    }
    private var gestureActive: Bool { dragSource != nil || input.dragging || view.isDragging }
    private func cancelDismissal() {
        dismissGeneration &+= 1; dismissWork?.cancel(); dismissWork = nil
    }
    func presence(_ inside: Bool) {
        if inside || contains(pointer()) { cancelDismissal(); return }
        guard active, isOpen, dismissWork == nil, !gestureActive, !busy, !reading else { return }
        let expected = dismissGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dismissGeneration == expected else { return }
            self.dismissWork = nil
            guard self.active, !self.contains(self.pointer()), !self.gestureActive, !self.busy, !self.reading,
                  self.pressedButtons() == 0 else { return }
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
        guard active, permitted, !busy else { after?(); return }
        if reading { if let after { pendingAfterRead = after }; return }
        if !force, ProcessInfo.processInfo.systemUptime - readDate < 2 { after?(); return }
        reading = true; generation += 1; let expected = generation
        let token = MenuBarReadToken(); readToken?.cancel(); readToken = token
        readWatchdog?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == expected, self.reading else { return }
            token.cancel(); self.generation += 1; self.readToken = nil; self.readWatchdog = nil
            self.reading = false; self.pendingAfterRead = nil
            // A failed refresh must not discard an already working restriction,
            // including the exception for the one menu being opened.
            self.menuBundle = nil; self.reapplyOnHover = self.wantsCollapsed
            self.issue = "原图标读取超时，已保留当前收纳状态；可点击读取图标重试。"; self.changed()
        }
        readWatchdog = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + iconReadTimeout, execute: timeout)
        let receive: ([MenuBarEntry]) -> Void = { [weak self] entries in
            guard let self, self.active, self.generation == expected, !token.isCancelled else { return }
            let own = Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"
            let filtered = Array(entries.filter { !MenuBarSections.systemOwners.contains($0.bundle) && $0.bundle != own }.prefix(512))
            let wanted = filtered.filter { $0.visible && (!self.hidden || !self.order.contains($0.bundle) || self.originalIcons[$0.bundle] == nil) }
            let finish: ([String: MenuBarIconPixels]) -> Void = { [weak self] pixels in
                guard let self, self.active, self.generation == expected, !token.isCancelled else { return }
                self.reading = false; self.readToken = nil; self.readWatchdog?.cancel(); self.readWatchdog = nil; self.readDate = ProcessInfo.processInfo.systemUptime
                // Missing/moved captures may keep a previously verified image,
                // but must not arm a drag at the pre-capture AX coordinates.
                let requested = Set(wanted.map(\.bundle))
                let currentEntries = filtered.map { entry -> MenuBarEntry in
                    guard requested.contains(entry.bundle), entry.visible else { return entry }
                    return MenuBarEntry(bundle: entry.bundle, frame: pixels[entry.bundle]?.sourceFrame ?? entry.frame,
                                        element: entry.element, pid: entry.pid, visible: pixels[entry.bundle] != nil)
                }
                self.entries = currentEntries
                for (bundle, pixel) in pixels {
                    self.originalIcons[bundle] = NSImage(cgImage: pixel.image, size: pixel.size)
                    self.iconCosts[bundle] = pixel.image.bytesPerRow * pixel.image.height
                }
                let retained = Set(filtered.map(\.bundle)).union(self.order)
                var keep = Set<String>(), bytes = 0
                for bundle in self.order + filtered.map(\.bundle) where retained.contains(bundle) && !keep.contains(bundle) {
                    guard let cost = self.iconCosts[bundle], keep.count < 64, bytes + cost <= 4_000_000 else { continue }
                    keep.insert(bundle); bytes += cost
                }
                self.originalIcons = self.originalIcons.filter { keep.contains($0.key) }
                self.iconCosts = self.iconCosts.filter { keep.contains($0.key) }
                // Only cached native pixels may be dragged. Unknown items stay native.
                self.input.entries = currentEntries.filter { $0.visible && !self.order.contains($0.bundle) && self.originalIcons[$0.bundle] != nil }
                self.appIcons.removeAll(); self.changed()
                after?(); let pending = self.pendingAfterRead; self.pendingAfterRead = nil; pending?()
                self.presence(self.contains(self.pointer()))
            }
            if let read = self.iconReadOverride { read(wanted, token, finish) }
            else { self.iconCapture.read(wanted, token: token, completion: finish) }
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
        let icon = originalIcons[bundle]
        let item = MenuDrawerItem(bundle: bundle, name: name, icon: icon, available: running != nil || entries.contains { $0.bundle == bundle })
        if appIcons.count < 128 { appIcons[bundle] = item }; return item
    }
    var drawerItems: [MenuDrawerItem] { order.map { item($0) } }
    var visibleItems: [MenuDrawerItem] {
        var seen = Set(order)
        return entries.filter { seen.insert($0.bundle).inserted }.prefix(64).map { item($0.bundle) }
    }
    func add(_ bundle: String, at index: Int? = nil, completion: ((Bool) -> Void)? = nil) {
        guard active, permitted, visibility.available, !busy, !order.contains(bundle), order.count < 40,
              bundle != Bundle.main.bundleIdentifier, !MenuBarSections.systemOwners.contains(bundle),
              entries.contains(where: { $0.bundle == bundle }) else { completion?(false); return }
        var next = order; next.insert(bundle, at: min(max(0, index ?? order.count), order.count))
        apply(next: next, completion: completion)
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
                self.replayMove(from: CGPoint(x: source.frame.midX, y: source.frame.midY), to: CGPoint(x: point.x, y: top - point.y))
            }
        }
    }
    /// Transactional membership: persist and report hidden only after native
    /// activation succeeds; failures keep the last confirmed order visible.
    func apply(next: [String]? = nil, completion: ((Bool) -> Void)? = nil) {
        guard active, !busy else { completion?(false); return }
        let proposed = next ?? order
        wantsCollapsed = !proposed.isEmpty; cancelRecovery(); menuBundle = nil
        guard permitted, visibility.available else {
            restoreNativeIcons(); reapplyOnHover = wantsCollapsed; issue = permitted ? "当前系统暂不支持抽屉隐藏，图标已全部恢复。" : "请先授予辅助功能权限。"; changed(); completion?(false); return
        }
        // A native layout change invalidates every in-flight position/image
        // pair. Never replace a verified glyph with a crop from an older layout.
        generation += 1; readToken?.cancel(); readToken = nil
        readWatchdog?.cancel(); readWatchdog = nil; reading = false; pendingAfterRead = nil; readDate = 0
        input.entries.removeAll()
        menuWatch?.cancel(); menuWatch = nil; reapplyOnHover = false
        menuGeneration += 1; actionToken?.cancel(); actionToken = nil
        restrictionGeneration += 1; let expected = restrictionGeneration
        // Keep the confirmed restriction alive until its replacement is active.
        // Releasing first briefly restores the entire native menu bar.
        if proposed.isEmpty {
            restriction?.invalidate(); restriction = nil; hidden = false
            order = []; persist(); input.entries.removeAll(); issue = nil; changed(); completion?(true)
            readEntries(force: true); return
        }
        let confirmed = Set(entries.map(\.bundle)).intersection(proposed)
        guard confirmed.allSatisfy({ originalIcons[$0] != nil }) else {
            restriction?.invalidate(); restriction = nil; hidden = false
            issue = CGPreflightScreenCaptureAccess() ? "原图标暂不可读取，已保留真实菜单栏；可点击读取图标重试。" : "需要屏幕录制权限读取原菜单栏图标；未读到的图标保持显示。"
            changed(); completion?(false); return
        }
        guard !confirmed.isEmpty else {
            // Offline/unreadable members stay configured but visible. Removing
            // another member must still succeed when no remaining app is running.
            restriction?.invalidate(); restriction = nil; hidden = false
            order = proposed; persist(); input.entries.removeAll(); issue = nil; changed(); completion?(true)
            readEntries(force: true); return
        }
        busy = true; changed()
        let all = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .union(MenuBarSections.systemOwners).union([Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"])
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.restrictionGeneration == expected else { return }
            self.restrictionGeneration += 1; self.watchdog = nil; self.busy = false
            self.restriction?.invalidate(); self.restriction = nil; self.hidden = false
            self.issue = "系统隐藏响应超时，图标已恢复；可重试。"; self.changed(); completion?(false)
        }
        watchdog = work; DispatchQueue.main.asyncAfter(deadline: .now() + activationTimeout, execute: work)
        visibility.activate(allowing: Array(all.subtracting(confirmed)).sorted()) { [weak self] handle in
            guard let self, self.active, self.restrictionGeneration == expected else { handle?.invalidate(); return }
            self.watchdog?.cancel(); self.watchdog = nil; self.busy = false
            let previous = self.restriction
            self.restriction = handle; self.hidden = handle != nil
            previous?.invalidate()
            if handle != nil { self.order = proposed; self.persist(); self.input.entries.removeAll(); self.issue = nil }
            else { self.issue = "系统未能收纳，图标已恢复；请重试。" }
            self.changed(); completion?(handle != nil)
            if handle != nil { self.readEntries(force: true) }
            self.presence(self.contains(self.pointer()))
        }
    }
    func showAll() {
        wantsCollapsed = false; cancelRecovery()
        restoreNativeIcons()
    }
    private func restoreNativeIcons() {
        cancelMenuInteraction()
        menuBundle = nil
        generation += 1; readToken?.cancel(); readToken = nil
        readWatchdog?.cancel(); readWatchdog = nil; reading = false; pendingAfterRead = nil; readDate = 0
        input.entries.removeAll()
        menuGeneration += 1; actionToken?.cancel(); actionToken = nil
        restrictionGeneration += 1; watchdog?.cancel(); watchdog = nil
        restriction?.invalidate(); restriction = nil; hidden = false; busy = false
        menuWatch?.cancel(); menuWatch = nil; reapplyOnHover = false; issue = nil; changed()
    }
    private func cancelMenuInteraction() {
        menuInteraction.cancel(); interactionRestriction?.invalidate(); interactionRestriction = nil
        restoringInteraction = false
        interactionRequested = false
    }
    func openMenu(_ bundle: String, samples: [MenuBarPointerSample] = MenuBarPointerSample.singleClick) {
        guard active, !busy, menuBundle != bundle, MenuBarPointerSample.valid(samples) else { return }
        guard permitted else { issue = "请先授予辅助功能权限。"; changed(); return }
        cancelRecovery(); cancelMenuInteraction()
        generation += 1; readToken?.cancel(); readToken = nil
        readWatchdog?.cancel(); readWatchdog = nil; reading = false; pendingAfterRead = nil; readDate = 0
        menuWatch?.cancel(); menuWatch = nil; input.entries.removeAll()
        menuGeneration += 1; actionToken?.cancel(); actionToken = nil
        restrictionGeneration += 1; watchdog?.cancel(); watchdog = nil
        reapplyOnHover = false; close(); menuBundle = bundle
        let expected = menuGeneration
        let point = anchorProvider?().map { CGPoint(x: $0.midX, y: $0.midY) } ?? pointer()
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let display = CGDisplayBounds(displayID)
        let perform = { [weak self] in
            guard let self, self.active, self.menuGeneration == expected else { return }
            guard let entry = self.entries.first(where: { $0.bundle == bundle }) else {
                self.menuBundle = nil; self.issue = "这个应用的菜单栏入口暂不可读，已保留收纳状态。"; self.changed(); return
            }
            let token = MenuBarReadToken(); self.actionToken = token
            self.busy = true; self.changed()
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.active, self.menuGeneration == expected else { return }
                self.restoreAfterGesture(success: false, expected: expected)
            }
            self.watchdog = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + self.menuInteractionTimeout, execute: timeout)
            self.menuInteraction.prepare(token: token) { [weak self] covered in
                guard let self, self.active, self.menuGeneration == expected, !token.isCancelled else { return }
                guard covered else {
                    self.watchdog?.cancel(); self.watchdog = nil; self.cancelMenuInteraction()
                    self.busy = false; self.actionToken = nil; self.menuBundle = nil
                    self.issue = "暂时无法保持菜单栏画面，已保留收纳状态；请检查屏幕录制权限后重试。"; self.changed(); return
                }
                let relay = { [weak self] in
                    guard let self, self.active, self.menuGeneration == expected, !token.isCancelled else { return }
                    let finish: (Bool) -> Void = { [weak self] ok in
                        guard let self, self.active, self.menuGeneration == expected, !token.isCancelled else { return }
                        // The owning app gets the mouse-up before its native
                        // anchor is hidden. Its real popup continues tracking.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            guard let self, self.active, self.menuGeneration == expected, !token.isCancelled else { return }
                            self.restoreAfterGesture(success: ok, expected: expected)
                        }
                    }
                    if let press = self.pressOverride { press(entry, token, finish) }
                    else { self.menuInteraction.replay(samples, entry: entry, display: display, token: token, completion: finish) }
                }
                guard self.wantsCollapsed, self.order.contains(bundle) else { relay(); return }
                let remaining = Set(self.order).subtracting([bundle])
                let all = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                    .union(MenuBarSections.systemOwners).union([Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x", bundle])
                // Keep the original restriction as a recovery handle. The
                // temporary input surface remains behind opaque bar stills.
                self.interactionRequested = true
                self.visibility.activate(allowing: Array(all.subtracting(remaining)).sorted()) { [weak self] handle in
                    guard let self, self.active, self.menuGeneration == expected, !token.isCancelled else { handle?.invalidate(); return }
                    guard let handle else { self.restoreAfterGesture(success: false, expected: expected); return }
                    self.interactionRestriction = handle; relay()
                }
            }
        }
        // Hover already retained the native owner. Resolve only its live
        // container during replay; do not rescan every app on each click.
        if entries.contains(where: { $0.bundle == bundle }) { perform() }
        else { readEntries(force: true, after: perform) }
    }
    private func restoreAfterGesture(success: Bool, expected: Int) {
        guard active, menuGeneration == expected, !restoringInteraction else { return }
        restoringInteraction = true; watchdog?.cancel(); watchdog = nil
        menuInteraction.cancelInput(); actionToken?.cancel()
        let finish = { [weak self] in
            guard let self, self.active, self.menuGeneration == expected else { return }
            self.watchdog?.cancel(); self.watchdog = nil
            self.cancelMenuInteraction(); self.actionToken?.cancel(); self.actionToken = nil
            self.busy = false; self.menuBundle = nil; self.reapplyOnHover = false
            self.issue = success ? nil : "应用未响应本次操作，已保留收纳状态；可重试。"
            self.readDate = 0; self.changed()
        }
        guard wantsCollapsed, !order.isEmpty, interactionRequested else { finish(); return }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.menuGeneration == expected else { return }
            self.menuGeneration += 1; self.watchdog = nil; self.cancelMenuInteraction()
            self.restriction?.invalidate(); self.restriction = nil; self.hidden = false; self.busy = false
            self.actionToken?.cancel(); self.actionToken = nil; self.menuBundle = nil
            self.issue = "系统恢复收纳超时，已恢复原生入口；请重新收纳。"; self.changed()
        }
        watchdog = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + activationTimeout, execute: timeout)
        let all = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
            .union(MenuBarSections.systemOwners).union([Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"])
        visibility.activate(allowing: Array(all.subtracting(Set(order))).sorted()) { [weak self] handle in
            guard let self, self.active, self.menuGeneration == expected else { handle?.invalidate(); return }
            guard let handle else { timeout.perform(); return }
            let previous = self.restriction; self.restriction = handle; self.hidden = true
            previous?.invalidate(); self.interactionRestriction?.invalidate(); self.interactionRestriction = nil
            // Keep the still until native reflow has reached the compositor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { finish() }
        }
    }
    func beginDrag(_ entry: MenuBarEntry, at point: CGPoint) {
        guard active, !busy else { return }
        dragSource = entry; dragOrigin = point; dragMoved = false; cancelDismissal()
        show(); view.accepting = contains(point)
    }
    func drag(to point: CGPoint) {
        guard let entry = dragSource else { return }
        dragMoved = dragMoved || hypot(point.x - dragOrigin.x, point.y - dragOrigin.y) > 4
        guard dragMoved else { return }
        view.accepting = contains(point)
        showDragImage(item(entry.bundle), at: point)
    }
    func finishDrag(at point: CGPoint) {
        guard let source = dragSource else { return }
        let moved = dragMoved; dragSource = nil; dragMoved = false; view.accepting = false
        guard moved else { finishDragImage(); return }
        if contains(point) {
            view.selected = source.bundle
            add(source.bundle) { [weak self] success in
                guard let self else { return }
                if success { self.show(); self.settleDragImage() }
                else { self.finishDragImage(at: self.dragOrigin, animated: true) }
            }
        } else if inMenuBand(point) {
            finishDragImage()
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            replayMove(from: CGPoint(x: source.frame.midX, y: source.frame.midY), to: CGPoint(x: point.x, y: top - point.y))
        } else { finishDragImage(at: dragOrigin, animated: true); presence(false) }
    }

    private func replayMove(from start: CGPoint, to end: CGPoint) {
        guard active else { return }
        let expected = movementGeneration; busy = true
        MenuBarDrawerInput.move(from: start, to: end, isCurrent: { [weak self] in
            self?.active == true && self?.movementGeneration == expected
        }) { [weak self] in
            guard let self, self.active, self.movementGeneration == expected else { return }
            self.busy = false; self.readDate = 0; self.prepareDrag(); self.changed(); self.presence(false)
        }
    }
    func showDragImage(_ item: MenuDrawerItem, at point: CGPoint) {
        guard !testNoPresentation, let icon = item.icon else { return }
        let size = icon.size
        if ghost == nil {
            settlingGhost?.close(); settlingGhost = nil
            let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.isReleasedWhenClosed = false; panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            let image = NSImageView(frame: CGRect(origin: .zero, size: size)); image.image = icon; image.imageScaling = .scaleNone
            panel.contentView = image; ghost = panel; panel.orderFrontRegardless()
        }
        ghost?.setFrameOrigin(CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
    func settleDragImage() {
        let target: CGPoint?
        if isOpen, let panel, let selected = view.selected, let index = view.items.firstIndex(where: { $0.bundle == selected }) {
            let rect = view.iconFrame(index)
            target = panel.convertPoint(toScreen: view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
        } else { target = nil }
        finishDragImage(at: target, animated: true)
    }
    func finishDragImage(at target: CGPoint? = nil, animated: Bool = false) {
        settlingGhost?.close(); settlingGhost = nil
        guard let ghost else { return }; self.ghost = nil
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { ghost.close(); return }
        settlingGhost = ghost
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            if let target { ghost.animator().setFrameOrigin(CGPoint(x: target.x - ghost.frame.width / 2, y: target.y - ghost.frame.height / 2)) }
            ghost.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            ghost.close()
            if self?.settlingGhost === ghost { self?.settlingGhost = nil }
        }
    }
    private func cancelDrag() { dragSource = nil; dragMoved = false; finishDragImage(); view.accepting = false }
    func requestIconAccess() {
        guard active else { return }
        // Only the explicit dashboard button may trigger the system prompt.
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        readDate = 0; prepareDrag()
    }
    private func inMenuBand(_ point: CGPoint) -> Bool {
        NSScreen.screens.contains { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }
    }
    private func persist() { defaults.set(order, forKey: selectionKey); input.entries = entries.filter { $0.visible && !order.contains($0.bundle) && originalIcons[$0.bundle] != nil } }
    private func changed() { if isOpen { show(); presence(false) } else { updateView() }; onChange?() }
    private func updateView() {
        view.isEnabled = active && !busy
        let items = drawerItems
        if !view.items.elementsEqual(items, by: { $0.bundle == $1.bundle && $0.name == $1.name && $0.icon === $1.icon && $0.available == $1.available }) {
            view.items = items
        }
        view.message = issue ?? (order.isEmpty ? "⌘ 拖入图标，收纳在这里" : "点击打开 · ⌘ 拖动排序，拖出恢复")
    }
    private func cancelRecovery() {
        recoveryGeneration &+= 1; recoveryWork?.cancel(); recoveryWork = nil
    }
    private func scheduleRecovery(readFresh: Bool) {
        cancelRecovery()
        guard active, wantsCollapsed, !order.isEmpty, permitted else { return }
        let expected = recoveryGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.wantsCollapsed, self.recoveryGeneration == expected else { return }
            self.recoveryWork = nil
            let recover = { [weak self] in
                guard let self, self.active, self.wantsCollapsed, self.recoveryGeneration == expected else { return }
                self.apply()
            }
            if readFresh { self.readEntries(force: true, after: recover) } else { recover() }
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    func environmentChanged(rebuild: Bool, application: String? = nil) {
        guard active else { return }
        // An unrelated launch must not interrupt a real menu still being used.
        if !rebuild, let menuBundle, application != menuBundle { return }
        let preserveRestriction = wantsCollapsed && hidden && !rebuild
            && application.map { !order.contains($0) } == true
        movementGeneration += 1; input.cancelPendingGesture(); cancelRecovery(); cancelMenuInteraction()
        generation += 1; readToken?.cancel(); readToken = nil; readWatchdog?.cancel(); readWatchdog = nil; reading = false; pendingAfterRead = nil
        actionToken?.cancel(); actionToken = nil; input.entries.removeAll(); appIcons.removeAll(); readDate = 0
        iconCapture.clear(); cancelDrag(); close()
        if preserveRestriction {
            restrictionGeneration += 1; watchdog?.cancel(); watchdog = nil; busy = false
            // apply replaces the allow-list before releasing its old handle.
            scheduleRecovery(readFresh: false)
        } else {
            entries.removeAll(); originalIcons.removeAll(); iconCosts.removeAll()
            restoreNativeIcons()
            if wantsCollapsed { scheduleRecovery(readFresh: true) }
        }
    }
    var hasDismissWork: Bool { dismissWork != nil }
}
