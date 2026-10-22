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
        let suite = "cc.anjing.macos-x.menu-shelf-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = FixtureVisibility()
        let drawer = MenuBarDrawer(defaults: defaults, visibility: bridge)
        drawer.permissionOverride = true; drawer.testNoPresentation = true; drawer.testSkipInput = true
        drawer.pressedButtons = { 0 }
        let screen = NSScreen.main!, anchor = CGRect(x: screen.visibleFrame.maxX - 220, y: screen.visibleFrame.maxY, width: 30, height: 24)
        drawer.anchorProvider = { anchor }
        let a = "com.apple.finder", b = "com.apple.Safari", c = "com.apple.TextEdit"
        func entry(_ bundle: String, _ x: CGFloat) -> MenuBarEntry { .init(bundle: bundle, frame: CGRect(x: x, y: 0, width: 20, height: 24)) }
        let entries = [entry(a, 400), entry(b, 440), entry(c, 480), entry("com.apple.controlcenter", 510)]
        func nativeIconRead(_ entries: [MenuBarEntry], _ token: MenuBarReadToken, _ finish: ([String: MenuBarIconPixels]) -> Void) {
            let context = CGContext(data: nil, width: 40, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.1, alpha: 1)); context.fillEllipse(in: CGRect(x: 8, y: 12, width: 24, height: 24))
            let glyph = MenuBarIconPixels(image: context.makeImage()!, size: CGSize(width: 20, height: 24))
            if !token.isCancelled { finish(Dictionary(entries.map { ($0.bundle, glyph) }, uniquingKeysWith: { first, _ in first })) }
        }
        drawer.iconReadOverride = nativeIconRead
        var reads = 0, pressed = [String]()
        drawer.readOverride = { token, receive in reads += 1; if !token.isCancelled { receive(entries) } }
        drawer.pressOverride = { entry, token, receive in if !token.isCancelled { pressed.append(entry.bundle); receive(true) } }
        drawer.start(); drawer.start()
        try require(reads == 0 && bridge.calls.isEmpty, "Empty module must not scan or hide on launch")
        drawer.hover(anchor, inside: true)
        try require(drawer.isOpen && reads == 1, "Apple hover opens the native drawer and bounded on-demand inventory")
        try require(!drawer.entries.contains { $0.bundle == "com.apple.controlcenter" }, "System controls never enter drawer inventory")
        let original = drawer.item(a).icon!
        try require(original.size == CGSize(width: 20, height: 24), "Menu items retain captured point size, not a 32pt application icon")
        drawer.add(a)
        try require(drawer.order.isEmpty && drawer.busy && defaults.stringArray(forKey: "menuBarShelf.drawerBundles.v1") == nil, "An in-flight hide cannot pretend membership was saved")
        let first = FixtureHandle(); bridge.pending.removeFirst()(first)
        try require(drawer.order == [a] && drawer.hidden, "Successful native restriction commits membership")
        try require(bridge.calls[0].contains(Bundle.main.bundleIdentifier!) && bridge.calls[0].contains("com.apple.controlcenter"), "Own apple and system recovery controls always remain visible")
        drawer.add(b)
        try require(first.invalidations == 0 && drawer.hidden, "Pending replacement keeps the old native restriction alive without an all-visible gap")
        bridge.pending.removeFirst()(nil)
        try require(first.invalidations == 1 && drawer.order == [a] && !drawer.hidden && drawer.issue != nil, "Failure fails open and retains last committed membership")
        drawer.add(b); let second = FixtureHandle(); bridge.pending.removeFirst()(second)
        let calls = bridge.calls.count
        let beforeSortIcon = drawer.item(a).icon
        drawer.move(b, to: 0)
        try require(drawer.order == [b, a] && bridge.calls.count == calls, "Sorting persists immediately without recapturing or another native activation")
        try require(drawer.item(a).icon === beforeSortIcon, "Sorting reuses the exact captured native glyph")
        try require(defaults.stringArray(forKey: "menuBarShelf.drawerBundles.v1") == [b, a], "Membership order survives relaunch")
        drawer.restore(b)
        try require(second.invalidations == 0 && drawer.hidden, "Drag-out keeps the old rule until the new allowed set is active")
        let third = FixtureHandle(); bridge.pending.removeFirst()(third)
        try require(drawer.order == [a] && second.invalidations == 1, "Drag-out restores a member while keeping the remaining selection")
        drawer.openMenu(a)
        try require(pressed == [a] && third.invalidations == 1 && !drawer.isOpen, "Click restores real items and forwards one AX press, never a simulated menu")
        drawer.show(); drawer.dismissDelay = 0.02
        drawer.pointer = { CGPoint(x: anchor.midX, y: anchor.minY - 2) }
        drawer.presence(false)
        try require(!drawer.hasDismissWork, "Apple-to-drawer connector corridor must not schedule collapse")
        drawer.pointer = { CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY) }
        drawer.presence(false)
        try require(drawer.hasDismissWork, "Leaving creates one delayed dismissal")
        drawer.pointer = { CGPoint(x: anchor.midX, y: anchor.midY) }
        drawer.hover(anchor, inside: true)
        try require(!bridge.pending.isEmpty, "Returning to apple reapplies saved collection after a menu action")
        bridge.pending.removeFirst()(FixtureHandle())
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try require(drawer.isOpen, "Re-entry cancels the old delayed dismissal")
        drawer.pointer = { CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY) }
        drawer.pressedButtons = { 1 }
        drawer.presence(false); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try require(drawer.isOpen, "A held mouse gesture cannot be collapsed by an idle deadline")
        drawer.pressedButtons = { 0 }
        drawer.presence(false); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try require(!drawer.isOpen, "Leaving idle closes the drawer")
        drawer.show(); drawer.beginDrag(entry(c, 480), at: CGPoint(x: 480, y: screen.frame.maxY - 10))
        drawer.drag(to: CGPoint(x: anchor.midX, y: anchor.midY))
        drawer.finishDrag(at: CGPoint(x: anchor.midX, y: anchor.midY))
        try require(drawer.busy && drawer.order == [a], "Command drag into apple uses transactional hiding")
        let fourth = FixtureHandle(); bridge.pending.removeFirst()(fourth)
        try require(drawer.order == [a, c] && drawer.isOpen, "Drop keeps drawer open and saves the new icon")
        drawer.activationTimeout = 0.02; drawer.add(b)
        let late = bridge.pending.removeFirst()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let lateHandle = FixtureHandle(); late(lateHandle)
        try require(fourth.invalidations == 1 && lateHandle.invalidations == 1 && !drawer.busy && !drawer.hidden && drawer.order == [a, c], "Timeout drops late handles without committing false membership")
        drawer.apply(); let duringStop = bridge.pending.removeFirst(); drawer.stop()
        let stoppedHandle = FixtureHandle(); duringStop(stoppedHandle)
        try require(stoppedHandle.invalidations == 1 && !drawer.active && !drawer.input.enabled && !drawer.isOpen && !drawer.hasDismissWork, "Stop restores icons and discards pending activation/input/popup")
        let restored = MenuBarDrawer(defaults: defaults, visibility: bridge)
        try require(restored.order == [a, c], "A new module reads the stored real membership")
        restored.iconReadOverride = nativeIconRead
        restored.permissionOverride = false; restored.testNoPresentation = true; restored.testSkipInput = true
        restored.start(); restored.prepareDrag()
        try require(restored.issue != nil && !restored.hidden, "Missing permission must be explicit and fail open")
        restored.stop()
        // A late inventory cannot recreate a stopped module or install hiding.
        let delayedDefaults = UserDefaults(suiteName: suite + ".delayed")!
        defer { delayedDefaults.removePersistentDomain(forName: suite + ".delayed") }
        let delayed = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        delayed.iconReadOverride = nativeIconRead
        delayed.permissionOverride = true; delayed.testSkipInput = true; delayed.testNoPresentation = true
        var readBack: (([MenuBarEntry]) -> Void)?, readToken: MenuBarReadToken?
        delayed.readOverride = { token, callback in readToken = token; readBack = callback }
        delayed.start(); delayed.prepareDrag(); delayed.stop(); readBack?(entries)
        try require(readToken?.isCancelled == true && delayed.entries.isEmpty && !delayed.input.enabled, "Stopped inventory never restores stale entries or input capture")
        let latest = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        latest.iconReadOverride = nativeIconRead
        latest.permissionOverride = true; latest.testSkipInput = true; latest.testNoPresentation = true
        latest.readOverride = { _, callback in readBack = callback }
        var latestPresses = [String]()
        latest.pressOverride = { entry, _, callback in latestPresses.append(entry.bundle); callback(true) }
        latest.start(); latest.openMenu(a); latest.openMenu(b); readBack?(entries)
        try require(latestPresses == [b], "Only the latest requested menu may open after queued inventory; earlier clicks cannot open two apps")
        latest.stop()
        // Tap tests run in-memory: they do not install a tap or post real events.
        let input = MenuBarDrawerInput(); input.enabled = true; input.entries = [entry(a, 400)]
        var begin = 0, drag = 0, end = 0
        input.onBegin = { _, _ in begin += 1 }; input.onDrag = { _ in drag += 1 }; input.onEnd = { _ in end += 1 }
        func event(_ type: CGEventType, _ x: CGFloat, command: Bool = true) -> CGEvent {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: 12), mouseButton: .left)!
            event.flags = command ? .maskCommand : []; return event
        }
        try require(!input.consume(.leftMouseDown, event: event(.leftMouseDown, 410, command: false)), "Ordinary application clicks remain untouched")
        try require(!input.consume(.leftMouseDown, event: event(.leftMouseDown, 700)), "Unknown/system/own icons remain native")
        input.canBegin = { false }
        try require(!input.consume(.leftMouseDown, event: event(.leftMouseDown, 410)), "Busy module cannot swallow a native mouse gesture")
        input.canBegin = { true }
        try require(input.consume(.leftMouseDown, event: event(.leftMouseDown, 410)), "Known Command-drag starts from bounded cache")
        try require(input.consume(.leftMouseDragged, event: event(.leftMouseDragged, 500)) && input.consume(.leftMouseUp, event: event(.leftMouseUp, 500)), "Consumed drag owns its matching mouse-up")
        try require(begin == 0 && drag == 0 && end == 0, "Window work must not execute inside the event-tap callback")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try require(begin == 1 && drag == 1 && end == 1 && !input.dragging, "Each real gesture completes exactly once")
        let marked = event(.leftMouseDown, 410); marked.setIntegerValueField(.eventSourceUserData, value: MenuBarDrawerInput.eventMark)
        try require(!input.consume(.leftMouseDown, event: marked), "Native reorder replay cannot recursively enter our tap")
        input.stop()
        input.enabled = true; input.entries = [entry(a, 400)]
        _ = input.consume(.leftMouseDown, event: event(.leftMouseDown, 410))
        input.stop(); input.enabled = true
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try require(begin == 1, "Stopping input discards queued UI work even after immediate re-enable")
        input.stop()
        var prepared = 0
        input.enabled = true; input.onPrepare = { prepared += 1 }
        let flags = CGEvent(source: nil)!; flags.type = .flagsChanged; flags.flags = .maskCommand
        flags.location = CGPoint(x: screen.frame.midX, y: 1)
        _ = input.consume(.flagsChanged, event: flags)
        try require(prepared == 0, "Preparation cannot execute within a flags callback")
        input.stop(); input.enabled = true
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try require(prepared == 0, "Stopping discards pending metadata preparation even after re-enable")
        input.entries = [entry(a, 400)]
        _ = input.consume(.leftMouseDown, event: event(.leftMouseDown, 410))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        let beforeBurst = drag
        for x in 420..<520 { _ = input.consume(.leftMouseDragged, event: event(.leftMouseDragged, CGFloat(x))) }
        try require(drag == beforeBurst, "A burst of mouse events cannot perform inline UI work")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try require(drag == beforeBurst + 1, "Queued drag work coalesces to the latest pointer position")
        _ = input.consume(.leftMouseUp, event: event(.leftMouseUp, 520))
        let beforeEnvironment = end
        input.cancelPendingGesture()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        try require(end == beforeEnvironment && input.enabled && !input.dragging, "Environment changes discard queued drops without disabling native input")
        input.stop()
        var stillCurrent = true, replayed: [CGEventType] = [], replayFinished = false
        MenuBarDrawerInput.move(from: .zero, to: CGPoint(x: 20, y: 0), isCurrent: { stillCurrent }, send: { type, _ in replayed.append(type); if type == .leftMouseDown { stillCurrent = false } }) { replayFinished = true }
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.10))
        try require(replayed == [.leftMouseDown, .leftMouseUp] && replayFinished, "Cancelled replay releases its own mouse down but never posts a new drag")
        let offlineDefaults = UserDefaults(suiteName: suite + ".offline")!
        defer { offlineDefaults.removePersistentDomain(forName: suite + ".offline") }
        offlineDefaults.set([a, b], forKey: "menuBarShelf.drawerBundles.v1")
        let offline = MenuBarDrawer(defaults: offlineDefaults, visibility: bridge)
        offline.iconReadOverride = nativeIconRead
        offline.permissionOverride = true; offline.testSkipInput = true; offline.testNoPresentation = true
        offline.readOverride = { _, done in done([]) }
        let callsBeforeOffline = bridge.calls.count
        offline.start(); offline.restore(a)
        try require(offline.order == [b] && !offline.hidden && !offline.busy && bridge.calls.count == callsBeforeOffline, "An unreadable remaining app cannot prevent removing a saved drawer member")
        offline.stop()
        let missing = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        missing.permissionOverride = true; missing.testSkipInput = true; missing.testNoPresentation = true
        missing.readOverride = { _, done in done(entries) }; missing.iconReadOverride = { _, _, done in done([:]) }
        missing.start(); missing.prepareDrag()
        let beforeMissing = bridge.calls.count
        missing.add(a)
        try require(missing.item(a).icon == nil && missing.input.entries.isEmpty && bridge.calls.count == beforeMissing && !missing.hidden,
                    "Missing original pixels cannot hide the real entry, intercept its drag or substitute an application icon")
        missing.stop()
        let lateIcons = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        lateIcons.permissionOverride = true; lateIcons.testSkipInput = true; lateIcons.testNoPresentation = true
        lateIcons.readOverride = { _, done in done(entries) }
        var latePixels: (([String: MenuBarIconPixels]) -> Void)?
        lateIcons.iconReadOverride = { _, _, done in latePixels = done }
        lateIcons.start(); lateIcons.prepareDrag(); lateIcons.stop()
        nativeIconRead(entries, MenuBarReadToken()) { latePixels?($0) }
        try require(lateIcons.item(a).icon == nil && lateIcons.input.entries.isEmpty, "Late screen pixels cannot repopulate a stopped drawer")
        let pixels = CGContext(data: nil, width: 120, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 120, height: 48))
        let surface = pixels.makeImage()!, area = CGRect(x: 1512, y: -241, width: 60, height: 24)
        let cropped = MenuBarIconCapture.crop(surface, surface: area, item: CGRect(x: 1532, y: -241, width: 20, height: 24))!
        try require(cropped.size == CGSize(width: 20, height: 24) && cropped.image.width == 40 && cropped.image.height == 48,
                    "Native glyph crops use global Quartz coordinates, negative display origins and real Retina scale")
        try require(MenuBarIconCapture.crop(surface, surface: area, item: area.offsetBy(dx: -1, dy: 0)) == nil, "Out-of-surface entries must not capture unrelated pixels")
        let timedIcons = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        timedIcons.permissionOverride = true; timedIcons.testSkipInput = true; timedIcons.testNoPresentation = true; timedIcons.iconReadTimeout = 0.02
        timedIcons.readOverride = { _, done in done(entries) }; timedIcons.iconReadOverride = { _, _, _ in }
        timedIcons.start(); timedIcons.prepareDrag()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try require(!timedIcons.hidden && !timedIcons.busy && timedIcons.issue?.contains("超时") == true, "An unresponsive native pixel request fails open and reports a retry instead of stranding hidden icons")
        timedIcons.stop()
        // Existing native UI is rendered using fixture app identities, not the
        // user's live inventory or preferences. Wide and narrow bounds are checked.
        let module = MenuBarShelfModule(defaults: defaults, visibility: bridge, native: true)
        module.configureDrawer = { $0.permissionOverride = false; $0.testSkipInput = true; $0.testNoPresentation = true }
        module.start(); let owned = module.drawer
        try require(owned?.active == true, "Native module owns exactly one apple drawer")
        module.stop()
        try require(owned?.active == false && module.drawer == nil, "Module disable releases the drawer and its event resources")
        for _ in 0..<20 {
            weak var releasedOwner: MenuBarDrawer?
            weak var releasedView: MenuBarDrawerView?
            autoreleasepool {
                let owner = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
                releasedOwner = owner; releasedView = owner.view
                owner.permissionOverride = false; owner.testSkipInput = true; owner.testNoPresentation = true
                owner.start(); owner.view.items = [.init(bundle: a, name: "Finder", icon: nil)]; owner.stop()
            }
            try require(releasedOwner == nil && releasedView == nil, "Repeated enable/disable must release drawer, accessibility children and view")
        }
        let view = module.makeDashboard()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 840, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        var previewIcons: [String: MenuBarIconPixels] = [:]
        nativeIconRead(entries, MenuBarReadToken()) { previewIcons = $0 }
        let examples = [a, b, c].map { MenuDrawerItem(bundle: $0, name: $0.components(separatedBy: ".").last!, icon: NSImage(cgImage: previewIcons[$0]!.image, size: previewIcons[$0]!.size)) }
        view.setItems(drawer: examples, visible: examples.reversed())
        view.update(active: true, state: .collapsed, auto: false, issue: nil, count: 3, native: true)
        for width: CGFloat in [840, 460, 360, 220] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: width < 520 ? 580 : 500)
            view.needsLayout = true; view.layoutSubtreeIfNeeded()
            try require(view.subviews.filter { !$0.isHidden }.allSatisfy { view.bounds.contains($0.frame) }, "Every visible control fits wide and narrow settings")
            try require(view.drawer.items.count == 3 && view.visible.items.count == 3, "Compact settings preserve all app identities")
        }
        var moved: (String, Int)?
        view.drawer.onMove = { moved = ($0, $1) }
        func localEvent(_ type: NSEvent.EventType, _ point: CGPoint, command: Bool = true) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.drawer.convert(point, to: nil), modifierFlags: command ? .command : [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var dragFeedback = 0, dragRelease = 0
        view.drawer.onDragImage = { _, _ in dragFeedback += 1 }; view.drawer.onDragFinished = { dragRelease += 1 }
        try require(view.drawer.iconFrame(0).size == examples[0].icon!.size, "UI draws native pixels at their original size")
        let compactHeight = MenuBarDrawerView.height(items: examples, width: MenuBarDrawerView.rowWidth(examples))
        try require(compactHeight == 40 && MenuBarDrawerView.rowWidth(examples) == 88, "Native 20×24 glyphs use compact slots and no permanent footer")
        let hintFrame = view.drawer.frame
        view.drawer.mouseMoved(with: localEvent(.mouseMoved, CGPoint(x: view.drawer.cellFrame(0).midX, y: view.drawer.cellFrame(0).midY)))
        try require(view.drawer.toolTip?.contains(examples[0].name) == true && view.drawer.toolTip?.contains(view.drawer.message) == true && view.drawer.frame == hintFrame, "Hover exposes name and actions without resizing the drawer")
        let tall = MenuDrawerItem(bundle: "tall", name: "Tall", icon: NSImage(size: CGSize(width: 20, height: 33)))
        let tallView = MenuBarDrawerView(frame: CGRect(x: 0, y: 0, width: 48, height: MenuBarDrawerView.height(items: [tall], width: 48))); tallView.items = [tall]
        try require(tallView.bounds.contains(tallView.iconFrame(0)), "Compact vertical padding never clips a taller native glyph")
        let firstCell = view.drawer.cellFrame(0), lastCell = view.drawer.cellFrame(2)
        view.drawer.mouseDown(with: localEvent(.leftMouseDown, CGPoint(x: firstCell.midX, y: firstCell.midY)))
        view.drawer.mouseDragged(with: localEvent(.leftMouseDragged, CGPoint(x: lastCell.midX, y: lastCell.midY)))
        view.drawer.mouseUp(with: localEvent(.leftMouseUp, CGPoint(x: lastCell.midX, y: lastCell.midY)))
        try require(moved?.0 == a && moved?.1 == 2 && view.drawer.items[2].bundle == a, "Real Command-drag view handlers reorder live before release and commit matching index")
        try require(dragFeedback == 1 && dragRelease == 1, "Drawer drag displays and releases the same native image on mouse-up")
        let outCell = view.drawer.cellFrame(0)
        var restoredBundle: String?
        view.drawer.onRestore = { bundle, _ in restoredBundle = bundle }
        view.drawer.mouseDown(with: localEvent(.leftMouseDown, CGPoint(x: outCell.midX, y: outCell.midY)))
        view.drawer.mouseDragged(with: localEvent(.leftMouseDragged, CGPoint(x: -40, y: -40)))
        view.drawer.mouseUp(with: localEvent(.leftMouseUp, CGPoint(x: -40, y: -40)))
        try require(restoredBundle == b && dragFeedback == 2 && dragRelease == 2, "Dragging out has the same native-image feedback as dragging in/reordering")
        let originalOrder = view.drawer.items.map(\.bundle)
        view.drawer.mouseDown(with: localEvent(.leftMouseDown, CGPoint(x: outCell.midX, y: outCell.midY)))
        view.drawer.mouseDragged(with: localEvent(.leftMouseDragged, CGPoint(x: lastCell.midX, y: lastCell.midY)))
        view.drawer.cancelDrag()
        try require(view.drawer.items.map(\.bundle) == originalOrder, "Cancelling a drag restores the last saved order and releases its ghost")
        if let directory = ProcessInfo.processInfo.environment["MENU_BAR_SHELF_PREVIEW_DIR"] {
            let path = URL(fileURLWithPath: directory); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            for width: CGFloat in [840, 360] {
                view.frame = CGRect(x: 0, y: 0, width: width, height: width < 520 ? 580 : 500); view.needsLayout = true; view.layoutSubtreeIfNeeded()
                let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])!.write(to: path.appendingPathComponent("menu-drawer-\(Int(width)).png"))
            }
            let popupSize = CGSize(width: MenuBarDrawerView.rowWidth(examples), height: MenuBarDrawerView.height(items: examples, width: MenuBarDrawerView.rowWidth(examples)))
            let popup = MenuBarDrawerView(frame: CGRect(origin: .zero, size: popupSize)); popup.items = examples; popup.selected = b
            window.contentView = popup; window.setContentSize(popupSize)
            popup.message = "点击打开 · ⌘ 拖动排序，拖出恢复"
            let image = popup.bitmapImageRepForCachingDisplay(in: popup.bounds)!; popup.cacheDisplay(in: popup.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: path.appendingPathComponent("menu-drawer-popup.png"))
        }
        window.orderOut(nil)
        print("Menu drawer regression passed: transactional membership, saved order, real view drag, native action routing, hover corridor, idle delay, failure/timeout/stop, input capture isolation and narrow settings. No real application icons were hidden or events posted.")
    }
}
