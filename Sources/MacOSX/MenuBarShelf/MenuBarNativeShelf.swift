import AppKit
import ApplicationServices

struct NativeMenuBarApplication {
    let bundle: String
    let name: String
    let pid: pid_t
}

struct NativeMenuBarChoice {
    let bundle: String
    let name: String
    let collected: Bool
    let running: Bool
}

/// Manages visibility only. There is no proxy window, event tap, capture,
/// synthetic input, cursor warping, or interpretation of click counts here.
@MainActor final class MenuBarNativeShelf {
    var onChange: (() -> Void)?
    private(set) var active = false
    private(set) var hidden = false
    private(set) var busy = false
    private(set) var reading = false
    private(set) var issue: String?
    private(set) var order: [String]
    private(set) var interactionHeld = false
    private(set) var wantsCollapsed = false
    private let defaults: UserDefaults
    private let visibility: MenuVisibilityProviding
    private let inventory = MenuBarInventory()
    private let probe = NativeMenuBarActivityProbe()
    private let boundaryReader = MenuBarBoundaryReader()
    private var commandDragStart: CGPoint?
    private var commandDragMoved = false
    private var postDropPoint: CGPoint?
    private var restriction: MenuVisibilityHandle?
    private var transition: UInt64 = 0
    private var readGeneration: UInt64 = 0
    private var interactionGeneration: UInt64 = 0
    private var dismissGeneration: UInt64 = 0
    private var transitionTimeout: DispatchWorkItem?
    private var readTimeout: DispatchWorkItem?
    private var dismissal: DispatchWorkItem?
    private var readToken: MenuBarReadToken?
    private var interactionToken: MenuBarReadToken?
    private var menuWatch: MenuBarMenuWatch?
    private var interactionOwner: pid_t?
    private var outsideReading = false
    private var ownMenuDepth = 0
    private var applications: [NativeMenuBarApplication] = []
    private var entries: [MenuBarEntry] = []
    private var observers: [NSObjectProtocol] = []
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var inputGeneration: UInt64 = 0
    private var pendingMove: CGPoint?
    private var moveQueued = false
    private var screenTop: CGFloat = 0
    private var cachedBands: [CGRect]?
    var permission: () -> Bool = { AXIsProcessTrusted() }
    var requestPermission: () -> Bool = {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    var runningApplications: () -> [NativeMenuBarApplication] = {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let bundle = app.bundleIdentifier else { return nil }
            return .init(bundle: bundle, name: app.localizedName ?? bundle, pid: app.processIdentifier)
        }
    }
    var pointer: () -> CGPoint = { NSEvent.mouseLocation }
    var pressedButtons: () -> Int = { Int(NSEvent.pressedMouseButtons) }
    var appleFrame: () -> CGRect? = { nil }
    // Release concealment before the pointer reaches a native status item.
    // Every menu-bar region is included, so unrelated system controls can be
    // operated without a click bridge while our module is running.
    var menuBands: () -> [CGRect] = {
        NSScreen.screens.map { screen in
            let height = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            return CGRect(x: screen.frame.minX, y: screen.frame.maxY - height - 16,
                          width: screen.frame.width, height: height + 16)
        }
    }
    var inputEnabled = true
    var environmentEnabled = true
    var collapseDelay: TimeInterval = 1.5
    var activationTimeout: TimeInterval = 3
    var readOverride: ((MenuBarReadToken, @escaping ([MenuBarEntry]) -> Void) -> Void)?
    var beginInteractionOverride: ((MenuBarReadToken, @escaping (pid_t?) -> Void) -> Void)?
    var outsideInteractionOverride: ((MenuBarReadToken, @escaping (pid_t?) -> Void) -> Void)?
    var boundaryReadOverride: ((MenuBarReadToken, @escaping (MenuBarBoundaryLayout?) -> Void) -> Void)?
    var hasInputMonitor: Bool { globalMonitor != nil || localMonitor != nil }
    var hasDismissal: Bool { dismissal != nil }
    func requestAccess() {
        guard active else { return }
        if requestPermission() { issue = nil; readChoices() }
        else { issue = "请在系统设置中授权辅助功能，返回后重试。"; changed() }
    }

    init(defaults: UserDefaults, visibility: MenuVisibilityProviding) {
        self.defaults = defaults; self.visibility = visibility
        var seen = Set<String>()
        order = Array((defaults.stringArray(forKey: "menuBarShelf.drawerBundles.v1") ?? []).prefix(64).filter {
            !$0.isEmpty && $0.count < 256 && $0 != Bundle.main.bundleIdentifier
                && !MenuBarSections.systemOwners.contains($0) && seen.insert($0).inserted
        }.prefix(40))
    }

    func start() {
        guard !active else { return }
        active = true; issue = nil; applications = runningApplications()
        if environmentEnabled {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.environmentChanged() }
                })
            }
            observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged(reset: true) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.environmentChanged(reset: true) }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    self.ownMenuDepth += 1
                    self.expandTemporarily(); self.cancelInteraction(); self.interactionHeld = true
                    self.interactionOwner = ProcessInfo.processInfo.processIdentifier
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active else { return }
                    self.ownMenuDepth = max(0, self.ownMenuDepth - 1)
                    guard self.ownMenuDepth == 0 else { return }
                    if self.interactionOwner == ProcessInfo.processInfo.processIdentifier { self.cancelInteraction() }
                    self.scheduleCollapse()
                }
            })
        }
        wantsCollapsed = !order.isEmpty
        updateMonitors()
        if wantsCollapsed { collapseWhenSafe() }
        changed()
    }

    func stop() {
        guard active else { return }
        active = false; wantsCollapsed = false; ownMenuDepth = 0; commandDragStart = nil; postDropPoint = nil
        expose(); cancelReading(); cancelInteraction(); removeMonitors()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll(); entries.removeAll(); applications.removeAll(); issue = nil; changed()
    }

    /// Pinned expansion is an explicit user choice; hovering must not undo it.
    func showAll() {
        guard active else { return }
        wantsCollapsed = false; postDropPoint = nil; commandDragStart = nil; commandDragMoved = false
        inputGeneration &+= 1; pendingMove = nil; moveQueued = false
        cancelReading(); expose(); changed()
    }
    func collapse() {
        guard active else { return }
        wantsCollapsed = !order.isEmpty; cancelInteraction(); collapseWhenSafe()
    }
    func toggle() {
        guard active else { return }
        if hidden || busy { expandTemporarily() }
        else { collapse() }
    }
    func hover(inside: Bool) {
        guard active else { return }
        if inside, suppressPostDropReveal(at: pointer()) { return }
        if inside { expandTemporarily() } else { scheduleCollapse() }
    }
    func expandTemporarily() {
        guard active else { return }
        postDropPoint = nil
        let wasConcealed = hidden || busy
        expose()
        if wasConcealed { changed() }
    }
    private func expose() {
        cancelDismissal(); transition &+= 1
        transitionTimeout?.cancel(); transitionTimeout = nil
        let previous = restriction; restriction = nil; hidden = false; busy = false
        previous?.invalidate()
    }
    private func inBar(_ point: CGPoint) -> Bool { (cachedBands ?? menuBands()).contains { $0.contains(point) } }
    private var overBar: Bool { inBar(pointer()) }
    private var mayCollapseAtDrop: Bool {
        postDropPoint.map { hypot(pointer().x - $0.x, pointer().y - $0.y) <= 6 } ?? false
    }
    private func suppressPostDropReveal(at point: CGPoint) -> Bool {
        postDropPoint.map { hypot(point.x - $0.x, point.y - $0.y) <= 6 } ?? false
    }
    private func cancelDismissal() {
        dismissGeneration &+= 1; dismissal?.cancel(); dismissal = nil
    }
    private func scheduleCollapse() {
        guard active, wantsCollapsed, !order.isEmpty, !hidden, !busy, !interactionHeld, ownMenuDepth == 0,
              !overBar, pressedButtons() == 0, dismissal == nil else { return }
        let expected = dismissGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dismissGeneration == expected else { return }
            self.dismissal = nil; self.collapseWhenSafe()
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }
    private func collapseWhenSafe() {
        guard active, wantsCollapsed, !order.isEmpty else { return }
        guard !reading, !interactionHeld, ownMenuDepth == 0, (!overBar || mayCollapseAtDrop), pressedButtons() == 0 else { cancelDismissal(); return }
        guard permission(), visibility.available else {
            expose(); issue = permission() ? "当前系统暂不能收纳，已保留原生图标。" : "需要辅助功能权限，原生图标保持显示。"
            changed(); return
        }
        cancelDismissal(); transition &+= 1; let expected = transition
        transitionTimeout?.cancel(); busy = true; issue = nil; changed()
        let own = Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"
        let allowed = Set(applications.map(\.bundle)).union(MenuBarSections.systemOwners).union([own]).subtracting(order)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.transition == expected else { return }
            self.expose(); self.issue = "收纳响应超时，原生图标保持显示。"; self.changed()
        }
        transitionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + activationTimeout, execute: timeout)
        visibility.activate(allowing: Array(allowed).sorted()) { [weak self] handle in
            guard let self, self.active, self.transition == expected, self.busy else { handle?.invalidate(); return }
            self.transitionTimeout?.cancel(); self.transitionTimeout = nil
            // A hover/gesture may have arrived while the system was applying
            // the restriction. Never hide native controls under the pointer.
            guard !self.interactionHeld, self.ownMenuDepth == 0, (!self.overBar || self.mayCollapseAtDrop), self.pressedButtons() == 0 else {
                handle?.invalidate(); self.expose(); self.changed(); self.scheduleCollapse(); return
            }
            let previous = self.restriction; self.restriction = handle
            self.busy = false; self.hidden = handle != nil; previous?.invalidate()
            self.issue = handle == nil ? "系统未能收纳，原生图标保持显示。" : nil
            self.changed()
        }
    }

    /// Passive observations only. Local monitors ALWAYS return the same event.
    enum Activity { case moved, down, up, escape }
    func observe(_ activity: Activity, at eventPoint: CGPoint? = nil) {
        guard active else { return }
        let point = eventPoint ?? pointer()
        if !inBar(point) { postDropPoint = nil }
        if activity == .escape {
            commandDragStart = nil; postDropPoint = nil; cancelReading(); cancelInteraction(); scheduleCollapse(); return
        }
        guard !order.isEmpty else { return }
        if activity == .moved, suppressPostDropReveal(at: point) { return }
        if activity == .down { postDropPoint = nil }
        if inBar(point) {
            expandTemporarily()
            if activity == .down, !(appleFrame()?.contains(point) ?? false) { beginInteraction(at: point) }
            return
        }
        switch activity {
        case .down: cancelDismissal()
        case .up:
            if interactionHeld { checkOutsideInteraction(at: point) }
            else { scheduleCollapse() }
        case .escape:
            cancelInteraction(); scheduleCollapse()
        case .moved: scheduleCollapse()
        }
    }
    private func beginInteraction(at clickedPoint: CGPoint) {
        cancelInteraction(); interactionHeld = true; cancelDismissal()
        let token = MenuBarReadToken(); interactionToken = token
        let expected = interactionGeneration
        let receive: (pid_t?) -> Void = { [weak self] pid in
            guard let self, self.active, self.interactionGeneration == expected, !token.isCancelled else { return }
            self.interactionOwner = pid
        }
        if let beginInteractionOverride { beginInteractionOverride(token, receive); return }
        let point = quartzPoint(clickedPoint)
        probe.begin(at: point, token: token, onClosed: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.active, self.interactionGeneration == expected, !token.isCancelled else { return }
                self.cancelInteraction(); self.scheduleCollapse()
            }
        }) { [weak self] pid, watch in
            guard let self, self.active, self.interactionGeneration == expected, !token.isCancelled else { watch?.cancel(); return }
            receive(pid); self.menuWatch = watch; watch?.attach()
        }
    }
    private func checkOutsideInteraction(at clickedPoint: CGPoint) {
        guard !outsideReading, let token = interactionToken, let owner = interactionOwner else { return }
        outsideReading = true
        let expected = interactionGeneration
        let receive: (pid_t?) -> Void = { [weak self] pid in
            guard let self, self.active, self.interactionGeneration == expected, !token.isCancelled else { return }
            self.outsideReading = false
            guard let pid, pid != owner, !self.applications.contains(where: {
                      $0.pid == pid && MenuBarSections.systemOwners.contains($0.bundle)
                  }) else { return }
            self.cancelInteraction(); self.scheduleCollapse()
        }
        if let outsideInteractionOverride { outsideInteractionOverride(token, receive) }
        else { probe.standardWindowOwner(at: quartzPoint(clickedPoint), token: token, completion: receive) }
    }
    private func quartzPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: screenTop - point.y)
    }
    private func cancelInteraction() {
        interactionGeneration &+= 1; interactionHeld = false; interactionOwner = nil; outsideReading = false
        interactionToken?.cancel(); interactionToken = nil; menuWatch?.cancel(); menuWatch = nil
    }
    private func updateMonitors() {
        guard active, inputEnabled, permission() else { removeMonitors(); return }
        guard globalMonitor == nil, localMonitor == nil else { return }
        cachedBands = menuBands(); screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.observe(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.observe(event); return event
        }
    }
    private func observe(_ event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        let type = event.type
        let activity: Activity
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: activity = .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: activity = .up
        case .keyDown: guard event.keyCode == 53 else { return }; activity = .escape
        case .flagsChanged:
            if command { activity = .moved }
            else {
                guard commandDragStart != nil, pressedButtons() == 0 else { return }
                let expected = inputGeneration, releasePoint = pointer()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.active, self.inputGeneration == expected else { return }
                    self.observeCommandDrag(.ended, at: releasePoint, command: false)
                }
                return
            }
        default: activity = .moved
        }
        let point = event.cgEvent.map { CGPoint(x: $0.location.x, y: screenTop - $0.location.y) } ?? pointer()
        if activity == .moved, type != .leftMouseDragged, order.isEmpty,
           commandDragStart == nil, !(command && inBar(point)) { return }
        let ownWindow = activity == .up && event.window.map { $0.styleMask.contains(.titled) && $0.level == .normal } == true
        let expected = inputGeneration
        if activity == .moved, type != .leftMouseDragged {
            pendingMove = point
            guard !moveQueued else { return }; moveQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.inputGeneration == expected else { return }
                let latest = self.pendingMove; self.pendingMove = nil; self.moveQueued = false
                if let latest { self.observe(.moved, at: latest) }
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.inputGeneration == expected else { return }
                let phase: CommandDragPhase? = type == .leftMouseDown ? .began : type == .leftMouseDragged ? .moved : type == .leftMouseUp ? .ended : nil
                if let phase, self.observeCommandDrag(phase, at: point, command: command) { return }
                // AppKit owns our windows; never query them through remote AX.
                if ownWindow, !self.inBar(point) { self.cancelInteraction() }
                self.observe(activity, at: point)
            }
        }
    }
    private func removeMonitors() {
        inputGeneration &+= 1; pendingMove = nil; moveQueued = false; cachedBands = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }
    func environmentChanged(reset: Bool = false) {
        guard active else { return }
        applications = runningApplications()
        if inputEnabled { cachedBands = menuBands(); screenTop = NSScreen.screens.first?.frame.maxY ?? 0 }
        cancelReading()
        if reset {
            inputGeneration &+= 1; pendingMove = nil; moveQueued = false
            ownMenuDepth = 0; commandDragStart = nil; postDropPoint = nil; cancelInteraction(); expose()
        }
        updateMonitors()
        if hidden || busy { collapseWhenSafe() }
        else { scheduleCollapse() }
        changed()
    }

    var choices: [NativeMenuBarChoice] {
        let names = Dictionary(applications.map { ($0.bundle, $0.name) }, uniquingKeysWith: { first, _ in first })
        let running = Set(applications.map(\.bundle))
        var seen = Set<String>()
        return (order + entries.map(\.bundle)).filter { seen.insert($0).inserted }.prefix(168).map { bundle in
            .init(bundle: bundle, name: names[bundle] ?? bundle, collected: order.contains(bundle), running: running.contains(bundle))
        }
    }
    func readChoices() {
        guard active, !reading else { return }
        guard permission() else { issue = "请先在系统设置中授予辅助功能权限。"; changed(); return }
        applications = runningApplications(); updateMonitors(); reading = true; readGeneration &+= 1
        let expected = readGeneration, token = MenuBarReadToken(); readToken = token
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.readGeneration == expected else { return }
            self.cancelReading(); self.issue = "读取应用超时，已保留收纳名单。"; self.changed()
        }
        readTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        let receive: ([MenuBarEntry]) -> Void = { [weak self] entries in
            guard let self, self.active, self.readGeneration == expected, !token.isCancelled else { return }
            self.cancelReading()
            self.entries = Array(entries.filter {
                !$0.bundle.isEmpty && $0.bundle != Bundle.main.bundleIdentifier && !MenuBarSections.systemOwners.contains($0.bundle)
            }.prefix(512))
            self.issue = nil; self.changed()
        }
        changed()
        if let readOverride { readOverride(token, receive) }
        else { inventory.read(applications.filter { $0.pid != ProcessInfo.processInfo.processIdentifier }.map { ($0.pid, $0.bundle) }, token: token, completion: receive) }
    }
    private func cancelReading() {
        readGeneration &+= 1; readToken?.cancel(); readToken = nil
        readTimeout?.cancel(); readTimeout = nil; reading = false
    }
    enum CommandDragPhase { case began, moved, ended }
    /// Observations only: the original Command-drag is delivered by macOS.
    /// Return value controls our bookkeeping, never native event delivery.
    @discardableResult func observeCommandDrag(_ phase: CommandDragPhase, at point: CGPoint, command: Bool) -> Bool {
        guard active else { return false }
        let actualBar = (cachedBands ?? menuBands()).contains { CGRect(x: $0.minX, y: $0.minY + 16, width: $0.width, height: max(1, $0.height - 16)).contains(point) }
        switch phase {
        case .began:
            guard command, actualBar else { return false }
            commandDragStart = point; commandDragMoved = false
            cancelReading(); expandTemporarily()
            return false
        case .moved:
            guard let start = commandDragStart else { return false }
            if hypot(start.x - point.x, start.y - point.y) > 4 {
                commandDragMoved = true; cancelInteraction(); interactionHeld = true; cancelDismissal()
            }
            return commandDragMoved
        case .ended:
            guard commandDragStart != nil else { return false }
            commandDragStart = nil
            guard commandDragMoved else { return false }
            commandDragMoved = false; cancelInteraction()
            if actualBar { collectLeftOfApple(dropPoint: point) }
            else { scheduleCollapse() }
            return true
        }
    }
    func collectLeftOfApple(dropPoint: CGPoint? = nil) {
        guard active else { return }
        // Once the user has rearranged native icons, the old membership is no
        // longer safe to reapply. Unconfirmed reads stay expanded until retry.
        cancelReading(); cancelInteraction(); wantsCollapsed = false; expandTemporarily()
        guard permission(), visibility.available else {
            issue = "请先授权辅助功能；原生图标保持显示。"; changed(); return
        }
        let apple = appleFrame()
        guard dropPoint != nil || apple.map({ $0.width > 0 && $0.height > 0 }) == true else {
            issue = "未确认苹果位置，原生图标保持显示；请重试。"; changed(); return
        }
        if let dropPoint, !inBar(dropPoint) {
            issue = "未确认当前屏幕的菜单栏，原生图标保持显示。"; changed(); return
        }
        screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        let top = screenTop
        applications = runningApplications(); reading = true; readGeneration &+= 1
        let expected = readGeneration, token = MenuBarReadToken(); readToken = token
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.readGeneration == expected else { return }
            self.cancelReading(); self.issue = "位置读取超时，原生图标保持显示；请重试。"; self.changed()
        }
        readTimeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: timeout)
        let receive: (MenuBarBoundaryLayout?) -> Void = { [weak self] layout in
            guard let self, self.active, self.readGeneration == expected, !token.isCancelled else { return }
            self.cancelReading()
            let running = Set(self.applications.map(\.bundle))
            guard let layout,
                  dropPoint.map({ point in
                      let anchor = CGPoint(x: layout.apple.midX, y: top - layout.apple.midY)
                      return (self.cachedBands ?? self.menuBands()).contains { $0.contains(point) && $0.contains(anchor) }
                  }) ?? true,
                  Set(self.order).intersection(running).isSubset(of: Set(layout.entries.map(\.bundle))),
                  let next = MenuBarBoundaryGrouping.order(layout, previous: self.order, running: running) else {
                self.issue = "未读到稳定位置，原生图标保持显示；请重试。"; self.changed(); return
            }
            self.order = next; self.defaults.set(next, forKey: "menuBarShelf.drawerBundles.v1")
            self.entries = layout.entries; self.wantsCollapsed = !next.isEmpty
            self.postDropPoint = dropPoint; self.issue = nil
            self.updateMonitors(); self.collapseWhenSafe(); self.changed()
        }
        changed()
        if let boundaryReadOverride { boundaryReadOverride(token, receive) }
        else {
            // Snapshot the own-app geometry on the main actor before querying
            // the MenuBarAgent containers on the background worker.
            let quartz = apple.map { CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height) }
            let location = dropPoint.map { CGPoint(x: $0.x, y: top - $0.y) }
            boundaryReader.read(apple: quartz, at: location, applications: applications, token: token, completion: receive)
        }
    }
    func setCollected(_ bundle: String, _ collected: Bool) {
        guard active, !bundle.isEmpty, bundle != Bundle.main.bundleIdentifier,
              !MenuBarSections.systemOwners.contains(bundle) else { return }
        if collected {
            guard !order.contains(bundle), order.count < 40, entries.contains(where: { $0.bundle == bundle }) else { return }
            order.append(bundle)
        } else { order.removeAll { $0 == bundle } }
        defaults.set(order, forKey: "menuBarShelf.drawerBundles.v1")
        wantsCollapsed = !order.isEmpty; updateMonitors()
        if order.isEmpty { expose(); cancelInteraction() }
        else { collapseWhenSafe() }
        changed()
    }
    private func changed() { onChange?() }
}

/// Read-only observations are bounded and never run inside an input callback.
/// If a popup does not expose reliable closure/ownership, keep it expanded
/// until Escape or explicit collapse instead of guessing a closing deadline.
private final class NativeMenuBarActivityProbe {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.native-bar-activity", qos: .userInitiated)
    private func element(at point: CGPoint, token: MenuBarReadToken) -> AXUIElement? {
        guard !token.isCancelled else { return nil }
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.08)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success else { return nil }
        return token.isCancelled ? nil : element
    }
    func begin(at point: CGPoint, token: MenuBarReadToken, onClosed: @escaping () -> Void,
               completion: @escaping (pid_t?, MenuBarMenuWatch?) -> Void) {
        queue.async {
            var pid: pid_t = 0
            let element = self.element(at: point, token: token)
            var owner = element.flatMap { AXUIElementGetPid($0, &pid) == .success && pid > 0 ? pid : nil }
            if let initial = owner, NSRunningApplication(processIdentifier: initial)?.bundleIdentifier == "com.apple.MenuBarAgent" {
                let containers = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.2)
                let owners = Set(containers.filter { $0.frame.contains(point) }.map(\.pid))
                owner = owners.count == 1 ? owners.first : nil
            }
            let watch = owner.flatMap { pid -> MenuBarMenuWatch? in
                guard pid != ProcessInfo.processInfo.processIdentifier, !token.isCancelled else { return nil }
                return element.flatMap { MenuBarMenuWatch(pid: pid, item: $0, requireConfirmedDeselection: true, onClosed: onClosed) }
            }
            DispatchQueue.main.async {
                guard !token.isCancelled else { watch?.cancel(); return }
                completion(owner, watch)
            }
        }
    }
    func standardWindowOwner(at point: CGPoint, token: MenuBarReadToken, completion: @escaping (pid_t?) -> Void) {
        queue.async {
            var current = self.element(at: point, token: token), owner: pid_t?
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            for _ in 0..<8 {
                guard let element = current, !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { break }
                var elementPID: pid_t = 0
                if AXUIElementGetPid(element, &elementPID) == .success,
                   elementPID == ProcessInfo.processInfo.processIdentifier { break }
                AXUIElementSetMessagingTimeout(element, 0.025)
                var subrole: CFTypeRef?, parent: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                   subrole as? String == kAXStandardWindowSubrole {
                    var pid: pid_t = 0
                    if AXUIElementGetPid(element, &pid) == .success, pid > 0 { owner = pid }
                    break
                }
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                current = unsafeBitCast(parent, to: AXUIElement.self)
            }
            let result = owner
            DispatchQueue.main.async { if !token.isCancelled { completion(result) } }
        }
    }
}
