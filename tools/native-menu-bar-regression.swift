import AppKit

@MainActor private final class TestVisibilityHandle: MenuVisibilityHandle {
    var invalidations = 0
    func invalidate() { invalidations += 1 }
}
@MainActor private final class TestVisibility: MenuVisibilityProviding {
    var available = true
    var automatic = true
    var lists: [[String]] = []
    var completions: [(MenuVisibilityHandle?) -> Void] = []
    var handles: [TestVisibilityHandle] = []
    func activate(allowing: [String], completion: @escaping (MenuVisibilityHandle?) -> Void) {
        lists.append(allowing)
        if automatic { let handle = TestVisibilityHandle(); handles.append(handle); completion(handle) }
        else { completions.append(completion) }
    }
    func finish(_ index: Int) -> TestVisibilityHandle {
        let handle = TestVisibilityHandle(); handles.append(handle); completions[index](handle); return handle
    }
}

@main struct NativeMenuBarRegression {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw NSError(domain: "NativeMenuBarRegression", code: assertions, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let suite = "cc.anjing.macos-x.native-bar-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = "test.vpn", b = "test.chat"
        func setup(_ bridge: TestVisibility, saved: [String] = [a]) -> MenuBarNativeShelf {
            defaults.set(saved, forKey: "menuBarShelf.drawerBundles.v1")
            let shelf = MenuBarNativeShelf(defaults: defaults, visibility: bridge)
            shelf.permission = { true }; shelf.requestPermission = { false }
            shelf.runningApplications = { [.init(bundle: a, name: "VPN", pid: 101), .init(bundle: b, name: "Chat", pid: 102)] }
            shelf.pointer = { CGPoint(x: 100, y: 100) }; shelf.pressedButtons = { 0 }
            shelf.menuBands = { [CGRect(x: 0, y: 900, width: 1500, height: 80), CGRect(x: -1200, y: -100, width: 1200, height: 50)] }
            shelf.inputEnabled = false; shelf.environmentEnabled = false; shelf.collapseDelay = 0.01
            shelf.beginInteractionOverride = { _, receive in receive(101) }
            shelf.outsideInteractionOverride = { _, receive in receive(102) }
            shelf.readOverride = { _, done in done([.init(bundle: a, frame: .zero), .init(bundle: b, frame: .zero)]) }
            return shelf
        }
        func pause() async { try? await Task.sleep(nanoseconds: 35_000_000) }

        do {
            let bridge = TestVisibility()
            let shelf = setup(bridge, saved: [])
            // Use a fresh empty shelf: no inventory, hiding, permission prompt,
            // observer, or window is needed just to enable an empty module.
            var reads = 0
            shelf.readOverride = { _, _ in reads += 1 }; shelf.start()
            try check(!shelf.hidden && !shelf.hasInputMonitor && reads == 0 && bridge.lists.isEmpty, "Empty startup is passive")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            shelf.start()
            try check(shelf.hidden && bridge.lists.count == 1, "Saved membership is restored")
            try check(!bridge.lists[0].contains(a) && bridge.lists[0].contains(b), "Only selected owner is hidden")
            shelf.hover(inside: true)
            try check(!shelf.hidden && bridge.handles[0].invalidations == 1, "Hover releases native concealment without an input relay")
            shelf.pointer = { CGPoint(x: 1300, y: 950) }; shelf.observe(.down); shelf.observe(.up)
            shelf.observe(.down); shelf.observe(.up)
            try check(shelf.interactionHeld && bridge.lists.count == 1, "Consecutive native clicks do not trigger hide or synthetic activations")
            shelf.pointer = { CGPoint(x: 100, y: 100) }; shelf.observe(.moved); await pause()
            try check(!shelf.hidden && !shelf.hasDismissal, "Leaving the bar does not collapse an active native menu")
            shelf.outsideInteractionOverride = { _, receive in receive(101) }; shelf.observe(.up); await pause()
            try check(shelf.interactionHeld && !shelf.hidden, "Interacting with the owning app's popup stays expanded")
            shelf.outsideInteractionOverride = { _, receive in receive(nil) }; shelf.observe(.up); await pause()
            try check(shelf.interactionHeld && !shelf.hidden, "Unknown popup ownership is not guessed closed")
            shelf.outsideInteractionOverride = { _, receive in receive(102) }; shelf.observe(.up); await pause()
            try check(shelf.hidden && !shelf.interactionHeld, "A confirmed outside app interaction allows delayed collapse")
            shelf.stop()
            try check(!shelf.hidden && !shelf.hasInputMonitor && !shelf.hasDismissal, "Disable releases native visibility and observations")
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            shelf.start(); shelf.pointer = { CGPoint(x: -100, y: -75) }; shelf.observe(.moved)
            try check(!shelf.hidden, "Another display's menu bar also releases restrictions before native interaction")
            shelf.observe(.down); shelf.observe(.escape)
            try check(!shelf.interactionHeld && !shelf.hidden, "Escape preserves the native event while clearing the interaction lease")
            shelf.pointer = { CGPoint(x: 100, y: 100) }; shelf.observe(.moved); await pause()
            try check(shelf.hidden, "Leaving after Escape collapses safely")
            shelf.showAll(); shelf.hover(inside: false); shelf.environmentChanged(); await pause()
            try check(!shelf.hidden && !shelf.wantsCollapsed && !shelf.hasDismissal, "Explicit Show All is not undone by hover or app changes")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            shelf.start(); shelf.readChoices()
            // The pointer may move before the deferred observation executes.
            // Native input is not replayed; only its immutable location is used
            // to protect the menu that the real click has already opened.
            shelf.observe(.down, at: CGPoint(x: 100, y: 950))
            try check(!shelf.hidden && shelf.interactionHeld, "A delayed observation retains the actual click location")
            shelf.setCollected(b, true); await pause()
            try check(shelf.order == [a, b] && !shelf.hidden, "Editing membership does not hide an active native menu")
            shelf.observe(.escape); await pause()
            try check(shelf.hidden && !bridge.lists.last!.contains(b), "New membership applies after interaction finishes")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(); bridge.automatic = false
            let shelf = setup(bridge); shelf.start(); bridge.completions[0](nil)
            try check(!shelf.hidden && !shelf.busy && shelf.issue != nil, "Rejected native activation fails open")
            let duplicate = bridge.finish(0)
            try check(duplicate.invalidations == 1 && !shelf.hidden, "Duplicate completion cannot install another concealment handle")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(); bridge.automatic = false
            let shelf = setup(bridge); shelf.start()
            try check(shelf.busy, "Native activation can be pending")
            shelf.hover(inside: true)
            let late = bridge.finish(0)
            try check(!shelf.hidden && !shelf.busy && late.invalidations == 1, "Hover invalidates a late concealment handle")
            shelf.collapse(); shelf.stop()
            let afterStop = bridge.finish(1)
            try check(afterStop.invalidations == 1 && !shelf.hidden, "Stopping cancels outstanding activation")
        }
        do {
            let bridge = TestVisibility(); bridge.automatic = false
            let shelf = setup(bridge); shelf.activationTimeout = 0.01; shelf.start(); await pause()
            try check(!shelf.hidden && !shelf.busy && shelf.issue != nil, "Native timeout fails open")
            let late = bridge.finish(0)
            try check(late.invalidations == 1, "Timeout cannot strand a late system restriction")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            shelf.start(); shelf.readChoices(); shelf.setCollected(b, true)
            try check(shelf.order == [a, b] && defaults.stringArray(forKey: "menuBarShelf.drawerBundles.v1") == [a, b], "Membership persists independently from expanded state")
            try check(!bridge.lists.last!.contains(a) && !bridge.lists.last!.contains(b), "Updated native allowlist reflects collected owners")
            shelf.setCollected(a, false); shelf.setCollected(b, false)
            try check(shelf.order.isEmpty && !shelf.hidden && !shelf.hasInputMonitor, "Removing the final member restores the bar")
            shelf.setCollected("unknown.app", true)
            try check(shelf.order.isEmpty, "Unread unknown owners are never silently concealed")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            shelf.start(); let previous = bridge.handles[0]
            shelf.runningApplications = { [.init(bundle: a, name: "VPN", pid: 101), .init(bundle: b, name: "Chat", pid: 102), .init(bundle: "new.app", name: "New", pid: 103)] }
            shelf.environmentChanged()
            try check(shelf.hidden && previous.invalidations == 1 && bridge.lists.last!.contains("new.app"), "App launch replaces the allowlist while preserving collection")
            shelf.pointer = { CGPoint(x: 100, y: 950) }; shelf.environmentChanged(reset: true)
            try check(!shelf.hidden && !shelf.busy, "Display change/wake does not hide controls under the pointer")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            shelf.permission = { false }; shelf.start()
            try check(!shelf.hidden && bridge.lists.isEmpty && shelf.issue != nil, "Missing accessibility permission preserves native controls")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(); bridge.available = false
            let shelf = setup(bridge); shelf.start()
            try check(!shelf.hidden && bridge.lists.isEmpty, "Unavailable private API fails open")
            shelf.stop()
        }
        do {
            let bridge = TestVisibility(), shelf = setup(bridge)
            var complete: (([MenuBarEntry]) -> Void)?
            shelf.readOverride = { _, receive in complete = receive }
            shelf.start(); shelf.readChoices(); shelf.stop()
            complete?([.init(bundle: b, frame: .zero)])
            try check(!shelf.reading && shelf.choices.map(\.bundle) == [a], "Stopped inventory cannot repopulate settings; configured membership is preserved")
        }
        for _ in 0..<20 {
            weak var released: MenuBarNativeShelf?
            autoreleasepool { let shelf = setup(TestVisibility()); released = shelf; shelf.start(); shelf.stop() }
            try check(released == nil, "Repeated enable/disable releases the controller")
        }
        print("PASS native menu-bar visibility lifecycle: \(assertions) assertions; no app/window launch or real input")
    }
}
