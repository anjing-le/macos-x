import AppKit
import ApplicationServices
import MenuBarVisibilityBridge

@MainActor protocol MenuVisibilityHandle: AnyObject { func invalidate() }
@MainActor protocol MenuVisibilityProviding {
    var available: Bool { get }
    func activate(allowing: [String], completion: @escaping (MenuVisibilityHandle?) -> Void)
}
@MainActor final class NativeMenuVisibility: MenuVisibilityProviding {
    var available: Bool { MXMenuVisibilityAvailable() }
    func activate(allowing: [String], completion: @escaping (MenuVisibilityHandle?) -> Void) {
        MXMenuVisibilityActivate((0..<64).map { NSNumber(value: $0) }, allowing) { raw, _ in
            MainActor.assumeIsolated { completion(raw.map { Handle($0) }) }
        }
    }
    private final class Handle: MenuVisibilityHandle {
        private var raw: AnyObject?
        init(_ raw: Any) { self.raw = raw as AnyObject }
        func invalidate() { guard let raw else { return }; self.raw = nil; MXMenuVisibilityInvalidate(raw) }
        deinit { if let raw { MXMenuVisibilityInvalidate(raw) } }
    }
}

/// Independent opt-in module. Enabling creates only its own status items;
/// hiding/AX reads require an explicit click. Stop always releases restrictions.
@MainActor final class MenuBarShelfModule: NSObject {
    enum State { case expanded, reading, collapsed }
    var onStatusChange: (() -> Void)?
    private(set) var active = false
    private(set) var state: State = .expanded
    private(set) var issue: String?
    private(set) var hiddenCount = 0
    private let defaults: UserDefaults
    private let native: Bool
    private let visibility: MenuVisibilityProviding
    private let inventory = MenuBarInventory()
    private var boundary: NSStatusItem?
    private var spacer: NSStatusItem?
    private var assertion: MenuVisibilityHandle?
    private var token: MenuBarReadToken?
    private var generation = 0
    private var timer: Timer?
    private var activationWatchdog: DispatchWorkItem?
    var activationTimeout: TimeInterval = 4
    private var observers: [NSObjectProtocol] = []
    private weak var dashboard: MenuBarShelfDashboard?
    // Injectable inventory keeps lifecycle tests away from other applications.
    var readOverride: (([(pid_t, String)], MenuBarReadToken, @escaping ([MenuBarEntry]) -> Void) -> Void)?
    var boundaryOverride: CGRect?
    var permissionOverride: Bool?
    var autoCollapse: Bool {
        get { defaults.bool(forKey: "menuBarShelf.autoCollapse") }
        set {
            defaults.set(newValue, forKey: "menuBarShelf.autoCollapse"); cancelTimer()
            if newValue, active, state == .expanded { scheduleCollapse(after: 10) }
            refresh()
        }
    }
    init(defaults: UserDefaults = .standard, visibility: MenuVisibilityProviding? = nil, native: Bool? = nil) {
        self.defaults = defaults; self.visibility = visibility ?? NativeMenuVisibility()
        self.native = native ?? (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
        super.init()
    }
    func start() {
        guard !active else { return }
        active = true; state = .expanded; issue = nil
        // The arrow itself is the native boundary. Legacy systems need a spacer.
        let item = NSStatusBar.system.statusItem(withLength: 28)
        item.autosaveName = "macos-x.menu-bar-boundary"; item.isVisible = true
        item.button?.target = self; item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp]); boundary = item
        if !native {
            let item = NSStatusBar.system.statusItem(withLength: 8)
            item.autosaveName = "macos-x.menu-bar-spacer"
            item.button?.title = "│"; spacer = item
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expand(allowAutoCollapse: false) }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didLaunchApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.expand(allowAutoCollapse: false) }
            })
        }
        refresh()
    }
    func stop() {
        guard active else { return }
        active = false; expand(allowAutoCollapse: false)
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let boundary { NSStatusBar.system.removeStatusItem(boundary) }; boundary = nil
        if let spacer { NSStatusBar.system.removeStatusItem(spacer) }; spacer = nil
        issue = nil; refresh()
    }
    func makeDashboard() -> MenuBarShelfDashboard {
        let view = MenuBarShelfDashboard()
        dashboard = view
        view.onExpand = { [weak self] in self?.expand() }
        view.onCollapse = { [weak self] in self?.collapse() }
        view.onAutoCollapse = { [weak self] in self?.autoCollapse = $0 }
        refresh(); return view
    }
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Don't let a previously scheduled auto-collapse interrupt this menu.
            cancelTimer()
            let menu = NSMenu()
            for (title, action) in [("展开全部图标", #selector(showAll)), ("收起左侧图标", #selector(hideLeft))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: ""); entry.target = self
            }
            menu.addItem(.separator())
            let hint = menu.addItem(withTitle: "按住 ⌘ 拖动图标到箭头左侧", action: nil, keyEquivalent: ""); hint.isEnabled = false
            if let button = boundary?.button { menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.minY), in: button) }
        } else if state == .expanded { collapse() } else { expand() }
    }
    @objc private func showAll() { expand() }
    @objc private func hideLeft() { collapse() }
    func expand(allowAutoCollapse: Bool = true) {
        generation += 1; token?.cancel(); token = nil; cancelTimer()
        activationWatchdog?.cancel(); activationWatchdog = nil
        assertion?.invalidate(); assertion = nil
        spacer?.length = 8; state = .expanded; hiddenCount = 0; issue = nil
        if active, allowAutoCollapse, autoCollapse { scheduleCollapse(after: 10) }
        refresh()
    }
    func collapse() {
        guard active, state == .expanded else { return }
        cancelTimer(); issue = nil
        if !native {
            if let left = spacer?.button?.window?.frame, let right = boundary?.button?.window?.frame, left.midX >= right.midX {
                issue = "按住 ⌘，把竖线放在收纳箭头左侧，再试一次。"; refresh(); return
            }
            spacer?.length = min(10_000, max(500, (NSScreen.screens.map { $0.frame.width }.max() ?? 1440) * 2))
            state = .collapsed; refresh(); return
        }
        guard visibility.available else { issue = "当前系统的菜单栏隐藏接口不可用，已保留全部图标。"; refresh(); return }
        guard permissionOverride ?? AXIsProcessTrusted() else {
            issue = "收起前需要辅助功能权限，用于读取图标的位置。"; refresh(); return
        }
        let quartzTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = boundaryOverride ?? boundary?.button?.window?.frame
        guard let frame, frame.width > 0 else { issue = "还未读取到收纳箭头的位置，请稍后重试。"; refresh(); return }
        let cgFrame = boundaryOverride ?? CGRect(x: frame.minX, y: quartzTop - frame.maxY, width: frame.width, height: frame.height)
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleURL?.pathExtension == "app" }
            .compactMap { app -> (pid_t, String)? in guard let bundle = app.bundleIdentifier else { return nil }; return (app.processIdentifier, bundle) }
        let own = Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"
        let allowedSeed = Set(apps.map { $0.1 }).union([own]).union(MenuBarSections.systemOwners)
        let ltr = NSApp.userInterfaceLayoutDirection != .rightToLeft
        state = .reading; generation += 1; let expected = generation
        let readToken = MenuBarReadToken(); token = readToken; refresh()
        let receive: ([MenuBarEntry]) -> Void = { [weak self] entries in
            guard let self, self.active, self.generation == expected, !readToken.isCancelled else { return }
            self.token = nil
            let hidden = MenuBarSections.hidden(entries, boundary: cgFrame, leftToRight: ltr).subtracting([own])
            guard !hidden.isEmpty else {
                self.state = .expanded; self.issue = "左侧没有可收纳的应用图标。按住 ⌘ 将图标拖到箭头左侧，再试一次。"; self.refresh(); return
            }
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.active, self.generation == expected, self.state == .reading else { return }
                self.generation += 1; self.activationWatchdog = nil
                self.state = .expanded; self.issue = "系统响应超时，已保留全部图标。"; self.refresh()
            }
            self.activationWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + self.activationTimeout, execute: watchdog)
            self.visibility.activate(allowing: Array(allowedSeed.subtracting(hidden)).sorted()) { [weak self] handle in
                guard let self, self.active, self.generation == expected else { handle?.invalidate(); return }
                self.activationWatchdog?.cancel(); self.activationWatchdog = nil
                self.assertion = handle
                self.state = handle == nil ? .expanded : .collapsed
                self.hiddenCount = handle == nil ? 0 : hidden.count
                self.issue = handle == nil ? "系统未能收起图标，已保留全部图标。" : nil
                self.refresh()
            }
        }
        if let readOverride { readOverride(apps, readToken, receive) }
        else { inventory.read(apps, token: readToken, completion: receive) }
    }
    private func cancelTimer() { timer?.invalidate(); timer = nil }
    private func scheduleCollapse(after seconds: TimeInterval) {
        cancelTimer()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.timer = nil
                guard self.active, self.autoCollapse, self.state == .expanded else { return }
                let pointer = NSEvent.mouseLocation
                let inBar = NSScreen.screens.contains { $0.frame.contains(pointer) && pointer.y >= $0.visibleFrame.maxY }
                if inBar || NSEvent.pressedMouseButtons != 0 { self.scheduleCollapse(after: 2) }
                else { self.collapse() }
            }
        }
    }
    private func refresh() {
        boundary?.button?.image = NSImage(systemSymbolName: state == .collapsed ? "chevron.right" : "chevron.left", accessibilityDescription: "菜单栏收纳")
        boundary?.button?.image?.isTemplate = true
        let title = state == .collapsed ? "展开已收纳的图标" : state == .reading ? "读取位置中，点击取消" : "收起箭头左侧的图标"
        boundary?.button?.toolTip = title + " · 按住 ⌘ 拖动图标分组"
        boundary?.button?.setAccessibilityLabel(title)
        dashboard?.update(active: active, state: state, auto: autoCollapse, issue: issue, count: hiddenCount, native: native)
        onStatusChange?()
    }
    var hasAutoCollapseTimer: Bool { timer != nil }
}
