import AppKit

@MainActor final class FixtureVisibility: MenuVisibilityProviding {
    var available = true
    var calls: [[String]] = []
    var pending: [(MenuVisibilityHandle?) -> Void] = []
    func activate(allowing: [String], completion: @escaping (MenuVisibilityHandle?) -> Void) { calls.append(allowing); pending.append(completion) }
}
@MainActor final class FixtureHandle: MenuVisibilityHandle {
    var invalidations = 0
    func invalidate() { invalidations += 1 }
}
@main struct MenuBarShelfRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        func require(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain: message, code: 1) } }
        let frame = CGRect(x: 500, y: 0, width: 28, height: 24)
        func entry(_ bundle: String, _ x: CGFloat, _ y: CGFloat = 0) -> MenuBarEntry { .init(bundle: bundle, frame: CGRect(x: x, y: y, width: 20, height: 24)) }
        let entries = [entry("hidden", 400), entry("mixed", 300), entry("mixed", 600), entry("visible", 650), entry("other-screen", 100, 400), entry("com.apple.controlcenter", 200)]
        try require(MenuBarSections.hidden(entries, boundary: frame, leftToRight: true) == ["hidden"], "Visible sibling and system controls must never be hidden; other displays cannot change grouping")
        try require(MenuBarSections.hidden(entries, boundary: frame, leftToRight: false) == ["visible"], "Right-to-left grouping must reverse without changing sibling precedence")
        let suite = "cc.anjing.macos-x.menu-shelf-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = FixtureVisibility()
        let module = MenuBarShelfModule(defaults: defaults, visibility: bridge, native: true)
        module.boundaryOverride = frame; module.permissionOverride = true
        var reads = 0, readOwnProcess = false
        var deliver: (([MenuBarEntry]) -> Void)?
        var token: MenuBarReadToken?
        module.readOverride = { apps, readToken, done in
            reads += 1; readOwnProcess = apps.contains { $0.0 == ProcessInfo.processInfo.processIdentifier }; token = readToken; deliver = done
        }
        let view = module.makeDashboard()
        module.start(); module.start()
        try require(reads == 0 && bridge.calls.isEmpty && module.state == .expanded, "Enabling must not scan or hide other applications")
        module.collapse(); module.collapse()
        try require(reads == 1 && !readOwnProcess && module.state == .reading, "Collapse inventory must be single-flight")
        module.expand(allowAutoCollapse: false)
        try require(token?.isCancelled == true, "Expanding cancels the pending inventory")
        deliver?([entry("hidden", 400)])
        try require(bridge.calls.isEmpty, "Cancelled inventory must never activate hiding")
        module.collapse(); deliver?(entries)
        try require(bridge.calls.count == 1 && !bridge.calls[0].contains("hidden"), "Only classified hidden bundles leave the allow list")
        try require(bridge.calls[0].contains("com.apple.controlcenter") && bridge.calls[0].contains(Bundle.main.bundleIdentifier!), "System controls and own recovery arrow must remain allowed")
        let first = FixtureHandle(); bridge.pending.removeFirst()(first)
        try require(module.state == .collapsed && module.hiddenCount == 1, "Success reflects actual activated restriction")
        view.expanded.performClick(nil)
        try require(first.invalidations == 1 && module.state == .expanded, "Whole expanded card releases the native restriction")
        module.collapse(); deliver?(entries)
        let stale = bridge.pending.removeFirst()
        module.stop(); let late = FixtureHandle(); stale(late)
        try require(late.invalidations == 1 && !module.active && module.state == .expanded, "Stop invalidates a late successful activation")
        module.start(); module.permissionOverride = false; module.collapse()
        try require(module.state == .expanded && module.issue != nil, "Missing permission fails open")
        module.permissionOverride = true; bridge.available = false; module.collapse()
        try require(module.state == .expanded && module.issue != nil, "Missing private backend fails open")
        bridge.available = true; module.collapse(); deliver?([])
        try require(module.state == .expanded && module.issue != nil, "Empty/unreadable inventory cannot hide all applications")
        module.collapse(); deliver?(entries); bridge.pending.removeFirst()(nil)
        try require(module.state == .expanded && module.hiddenCount == 0, "Backend failure cannot report success")
        module.activationTimeout = 0.02
        module.collapse(); deliver?(entries)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
        let timedOut = FixtureHandle(); bridge.pending.removeFirst()(timedOut)
        try require(module.state == .expanded && module.issue != nil && timedOut.invalidations == 1, "Timed out activation fails open and drops late handles")
        module.autoCollapse = true; module.expand()
        try require(module.hasAutoCollapseTimer, "Auto collapse owns only an expanded one-shot timer")
        module.autoCollapse = false
        try require(!module.hasAutoCollapseTimer && !defaults.bool(forKey: "menuBarShelf.autoCollapse"), "Disabling auto collapse cancels and persists")
        module.autoCollapse = true; module.expand(); module.stop()
        try require(!module.hasAutoCollapseTimer, "Stop releases auto-collapse work")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 840, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        for width: CGFloat in [840, 460, 360] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: width < 430 ? 540 : 400)
            view.needsLayout = true; view.layoutSubtreeIfNeeded()
            try require(view.subviews.allSatisfy { view.bounds.contains($0.frame) }, "Every control and note fits narrow and wide dashboard bounds")
            try require(!view.expanded.frame.intersects(view.collapsed.frame), "State choices must not overlap")
        }
        module.start(); view.frame.size = CGSize(width: 840, height: 400); view.needsLayout = true; view.layoutSubtreeIfNeeded()
        try require(view.expanded.accessibilityLabel()?.contains("展开") == true && view.collapsed.accessibilityLabel()?.contains("收起") == true, "State choices expose meaningful native actions")
        if let directory = ProcessInfo.processInfo.environment["MENU_BAR_SHELF_PREVIEW_DIR"] {
            let path = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: path.appendingPathComponent("menu-bar-shelf.png"))
        }
        module.stop(); window.orderOut(nil)
        print("Menu bar shelf regression passed; native bridge available: \(NativeMenuVisibility().available). No real application icons were hidden.")
    }
}
