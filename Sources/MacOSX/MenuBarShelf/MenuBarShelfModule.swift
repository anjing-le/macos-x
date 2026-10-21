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

/// The apple owns the new drawer entry. Older systems retain the geometric
/// boundary implementation; stopping either path restores all real icons.
@MainActor final class MenuBarShelfModule: NSObject {
    enum State { case expanded, reading, collapsed }
    var onStatusChange: (() -> Void)?
    var anchorProvider: (() -> CGRect?)?
    private(set) var active = false
    private(set) var state: State = .expanded
    private(set) var issue: String?
    private(set) var hiddenCount = 0
    private(set) var drawer: MenuBarDrawer?
    private let defaults: UserDefaults
    private let native: Bool
    private let visibility: MenuVisibilityProviding
    private var boundary: NSStatusItem?
    private var spacer: NSStatusItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var dashboard: MenuBarShelfDashboard?
    var configureDrawer: ((MenuBarDrawer) -> Void)?
    var autoCollapse: Bool {
        get { defaults.bool(forKey: "menuBarShelf.autoCollapse") }
        set {
            defaults.set(newValue, forKey: "menuBarShelf.autoCollapse"); cancelTimer()
            if !native, newValue, active, state == .expanded { scheduleCollapse(after: 10) }
            refresh()
        }
    }
    init(defaults: UserDefaults = .standard, visibility: MenuVisibilityProviding? = nil, native: Bool? = nil) {
        self.defaults = defaults; self.visibility = visibility ?? NativeMenuVisibility()
        self.native = native ?? (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27)
        super.init()
    }
    func start() {
        guard !active else { return }; active = true; issue = nil; state = .expanded
        if native {
            let drawer = MenuBarDrawer(defaults: defaults, visibility: visibility); self.drawer = drawer
            drawer.anchorProvider = { [weak self] in self?.anchorProvider?() }
            configureDrawer?(drawer)
            drawer.onChange = { [weak self, weak drawer] in
                guard let self, let drawer else { return }
                self.state = drawer.busy ? .reading : drawer.hidden ? .collapsed : .expanded
                self.hiddenCount = drawer.hidden ? drawer.order.count : 0; self.issue = drawer.issue; self.refresh()
            }
            drawer.start(); refresh(); return
        }
        let boundary = NSStatusBar.system.statusItem(withLength: 28)
        boundary.autosaveName = "macos-x.menu-bar-boundary"; boundary.button?.target = self
        boundary.button?.action = #selector(clicked); self.boundary = boundary
        let spacer = NSStatusBar.system.statusItem(withLength: 8)
        spacer.autosaveName = "macos-x.menu-bar-spacer"; spacer.button?.title = "│"; self.spacer = spacer
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expand(allowAutoCollapse: false) }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.expand(allowAutoCollapse: false) }
        })
        refresh()
    }
    func stop() {
        guard active else { return }; active = false
        drawer?.stop(); drawer = nil; expand(allowAutoCollapse: false)
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let boundary { NSStatusBar.system.removeStatusItem(boundary) }; boundary = nil
        if let spacer { NSStatusBar.system.removeStatusItem(spacer) }; spacer = nil
        issue = nil; refresh()
    }
    func appleHover(_ frame: CGRect, inside: Bool) { drawer?.hover(frame, inside: inside) }
    func appleClick() { drawer?.toggle() }
    func makeDashboard() -> MenuBarShelfDashboard {
        let view = MenuBarShelfDashboard(); dashboard = view
        view.onExpand = { [weak self] in self?.expand() }
        view.onCollapse = { [weak self] in self?.collapse() }
        view.onAutoCollapse = { [weak self] in self?.autoCollapse = $0 }
        view.onRefresh = { [weak self] in self?.drawer?.prepareDrag() }
        view.onAdd = { [weak self] in self?.drawer?.add($0) }
        view.onMove = { [weak self] in self?.drawer?.move($0, to: $1) }
        view.onRestore = { [weak self] in self?.drawer?.restore($0, at: $1) }
        view.onOpen = { [weak self] in self?.drawer?.openMenu($0) }
        view.onPreview = { [weak self] in self?.drawer?.toggle() }
        refresh(); return view
    }
    @objc private func clicked() { if state == .expanded { collapse() } else { expand() } }
    func expand(allowAutoCollapse: Bool = true) {
        if let drawer { drawer.showAll(); return }
        cancelTimer(); spacer?.length = 8; state = .expanded; issue = nil
        if active, allowAutoCollapse, autoCollapse { scheduleCollapse(after: 10) }; refresh()
    }
    func collapse() {
        if let drawer { drawer.apply(); return }
        guard active, state == .expanded else { return }; cancelTimer()
        if let left = spacer?.button?.window?.frame, let right = boundary?.button?.window?.frame, left.midX >= right.midX {
            issue = "按住 ⌘，把竖线放在收纳箭头左侧，再试一次。"; refresh(); return
        }
        spacer?.length = min(10_000, max(500, (NSScreen.screens.map { $0.frame.width }.max() ?? 1440) * 2))
        state = .collapsed; refresh()
    }
    private func cancelTimer() { timer?.invalidate(); timer = nil }
    private func scheduleCollapse(after seconds: TimeInterval) {
        cancelTimer()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.timer = nil
                guard self.active, self.autoCollapse, self.state == .expanded else { return }
                let point = NSEvent.mouseLocation
                if NSScreen.screens.contains(where: { $0.frame.contains(point) && point.y >= $0.visibleFrame.maxY }) || NSEvent.pressedMouseButtons != 0 { self.scheduleCollapse(after: 2) }
                else { self.collapse() }
            }
        }
    }
    private func refresh() {
        boundary?.button?.image = NSImage(systemSymbolName: state == .collapsed ? "chevron.right" : "chevron.left", accessibilityDescription: "菜单栏收纳")
        boundary?.button?.image?.isTemplate = true
        boundary?.button?.toolTip = "点击收起／展开 · 按住 ⌘ 拖动图标分组"
        dashboard?.setItems(drawer: drawer?.drawerItems ?? [], visible: drawer?.visibleItems ?? [])
        dashboard?.update(active: active, state: state, auto: autoCollapse, issue: issue, count: hiddenCount, native: native)
        onStatusChange?()
    }
    var hasAutoCollapseTimer: Bool { timer != nil }
}
