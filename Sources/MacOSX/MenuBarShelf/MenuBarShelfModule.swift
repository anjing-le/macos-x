import AppKit
import ApplicationServices
import MenuBarVisibilityBridge

/// The apple expands the original native menu bar; it never hosts proxy icons. Older systems retain the geometric
/// boundary implementation; stopping either path restores all real icons.
@MainActor final class MenuBarShelfModule: NSObject {
    enum State { case expanded, reading, collapsed }
    var onStatusChange: (() -> Void)?
    var anchorProvider: (() -> CGRect?)?
    var onAppleEvent: ((NSEvent) -> Void)?
    private(set) var active = false
    private(set) var state: State = .expanded
    private(set) var issue: String?
    private(set) var hiddenCount = 0
    private(set) var shelf: MenuBarNativeShelf?
    private let defaults: UserDefaults
    private let native: Bool
    private let visibility: MenuVisibilityProviding
    private var boundary: NSStatusItem?
    private var spacer: NSStatusItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private weak var dashboard: MenuBarShelfDashboard?
    private weak var nativeDashboard: MenuBarNativeShelfDashboard?
    var configureShelf: ((MenuBarNativeShelf) -> Void)?
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
            let shelf = MenuBarNativeShelf(defaults: defaults, visibility: visibility); self.shelf = shelf
            shelf.appleFrame = { [weak self] in self?.anchorProvider?() }
            configureShelf?(shelf)
            shelf.onChange = { [weak self, weak shelf] in
                guard let self, let shelf else { return }
                self.state = shelf.busy ? .reading : shelf.hidden ? .collapsed : .expanded
                self.hiddenCount = shelf.hidden ? shelf.order.count : 0
                self.issue = shelf.issue; self.refresh()
            }
            shelf.start(); refresh(); return
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
        shelf?.stop(); shelf = nil; expand(allowAutoCollapse: false)
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        if let boundary { NSStatusBar.system.removeStatusItem(boundary) }; boundary = nil
        if let spacer { NSStatusBar.system.removeStatusItem(spacer) }; spacer = nil
        issue = nil; refresh()
    }
    func appleHover(_ frame: CGRect, inside: Bool) { shelf?.hover(inside: inside) }
    func appleClick() { shelf?.toggle() }
    func makeDashboard() -> NSView {
        if native {
            let view = MenuBarNativeShelfDashboard(); nativeDashboard = view
            view.onRead = { [weak self] in self?.shelf?.collectLeftOfApple() }
            view.onShow = { [weak self] in self?.shelf?.showAll() }
            view.onCollapse = { [weak self] in self?.shelf?.collapse() }
            view.onAccess = { [weak self] in self?.shelf?.requestAccess() }
            refresh(); return view
        }
        let view = MenuBarShelfDashboard(); dashboard = view
        view.onExpand = { [weak self] in self?.expand() }
        view.onCollapse = { [weak self] in self?.collapse() }
        view.onAutoCollapse = { [weak self] in self?.autoCollapse = $0 }
        refresh(); return view
    }
    @objc private func clicked() { if state == .expanded { collapse() } else { expand() } }
    func expand(allowAutoCollapse: Bool = true) {
        if let shelf { shelf.showAll(); return }
        cancelTimer(); spacer?.length = 8; state = .expanded; issue = nil
        if active, allowAutoCollapse, autoCollapse { scheduleCollapse(after: 10) }; refresh()
    }
    func collapse() {
        if let shelf { shelf.collapse(); return }
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
        nativeDashboard?.update(active: active, hidden: shelf?.hidden ?? false, busy: shelf?.busy ?? false,
                                reading: shelf?.reading ?? false, issue: issue, choices: shelf?.choices ?? [], permitted: shelf?.permission() ?? false)
        dashboard?.setItems(drawer: [], visible: [])
        dashboard?.update(active: active, state: state, auto: autoCollapse, issue: issue, count: hiddenCount, native: native)
        onStatusChange?()
    }
    var hasAutoCollapseTimer: Bool { timer != nil }
}
