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
        // Dispatch timers can be coalesced on a background CI runner. Wait for
        // the observed transition within a bound, rather than assume 190 ms.
        func awaitTransition(_ condition: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
        }
        let suite = "cc.anjing.macos-x.menu-shelf-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        // Fixtures deliver their own environment changes; live runner launches
        // must not race deterministic recovery assertions.
        let bridge = FixtureVisibility()
        let drawer = MenuBarDrawer(defaults: defaults, visibility: bridge)
        drawer.permissionOverride = true; drawer.testNoPresentation = true; drawer.testSkipInput = true; drawer.testSkipEnvironment = true
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
        drawer.pointer = { CGPoint(x: anchor.midX, y: anchor.midY) }
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
        awaitTransition { !drawer.busy }
        let lateHandle = FixtureHandle(); late(lateHandle)
        try require(fourth.invalidations == 1 && lateHandle.invalidations == 1 && !drawer.busy && !drawer.hidden && drawer.order == [a, c], "Timeout drops late handles without committing false membership")
        drawer.apply(); let duringStop = bridge.pending.removeFirst(); drawer.stop()
        let stoppedHandle = FixtureHandle(); duringStop(stoppedHandle)
        try require(stoppedHandle.invalidations == 1 && !drawer.active && !drawer.input.enabled && !drawer.isOpen && !drawer.hasDismissWork, "Stop restores icons and discards pending activation/input/popup")
        let restored = MenuBarDrawer(defaults: defaults, visibility: bridge)
        try require(restored.order == [a, c], "A new module reads the stored real membership")
        restored.iconReadOverride = nativeIconRead
        restored.permissionOverride = false; restored.testNoPresentation = true; restored.testSkipInput = true; restored.testSkipEnvironment = true
        restored.start(); restored.prepareDrag()
        try require(restored.issue != nil && !restored.hidden, "Missing permission must be explicit and fail open")
        restored.stop()
        let recoveryDefaults = UserDefaults(suiteName: suite + ".recovery")!
        defer { recoveryDefaults.removePersistentDomain(forName: suite + ".recovery") }
        let recoveryBridge = FixtureVisibility(), recovery = MenuBarDrawer(defaults: recoveryDefaults, visibility: recoveryBridge)
        recovery.permissionOverride = true; recovery.testSkipInput = true; recovery.testSkipEnvironment = true; recovery.testNoPresentation = true
        recovery.readOverride = { _, done in done(entries) }; recovery.iconReadOverride = nativeIconRead
        recovery.start(); recovery.prepareDrag(); recovery.add(a)
        let held = FixtureHandle(); recoveryBridge.pending.removeFirst()(held)
        let originalCalls = recoveryBridge.calls.count
        recovery.environmentChanged(rebuild: false, application: "fixture.unrelated")
        try require(recovery.hidden && held.invalidations == 0, "An unrelated app launch never exposes collected icons")
        awaitTransition { recoveryBridge.calls.count > originalCalls }
        try require(recoveryBridge.calls.count == originalCalls + 1 && held.invalidations == 0,
                    "An updated allow-list is installed without dropping the old restriction")
        let replaced = FixtureHandle(); recoveryBridge.pending.removeFirst()(replaced)
        try require(recovery.hidden && held.invalidations == 1, "Application changes finish collected without requiring another hover")
        recovery.environmentChanged(rebuild: true)
        try require(!recovery.hidden && replaced.invalidations == 1, "Display/wake recovery releases an obsolete native restriction")
        awaitTransition { !recoveryBridge.pending.isEmpty }
        try require(recoveryBridge.pending.count == 1, "A rebuilt inventory automatically reapplies saved collection")
        recoveryBridge.pending.removeFirst()(FixtureHandle())
        try require(recovery.hidden, "Recovered screens return to collection without a pointer event")
        let beforeManual = recoveryBridge.calls.count
        recovery.environmentChanged(rebuild: true); recovery.showAll()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.19))
        try require(!recovery.hidden && recoveryBridge.calls.count == beforeManual,
                    "Explicit show-all cancels queued automatic hiding")
        recovery.environmentChanged(rebuild: false, application: "fixture.unrelated")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.19))
        try require(!recovery.hidden && recovery.order == [a] && recoveryBridge.calls.count == beforeManual,
                    "Application changes respect an explicit expanded state and retain the saved membership")
        recovery.readEntries(force: true); recovery.apply(); recoveryBridge.pending.removeFirst()(FixtureHandle())
        let beforeRecoveryBurst = recoveryBridge.calls.count
        for _ in 0..<3 { recovery.environmentChanged(rebuild: false, application: "fixture.unrelated") }
        awaitTransition { recoveryBridge.calls.count > beforeRecoveryBurst }
        try require(recoveryBridge.calls.count == beforeRecoveryBurst + 1, "A launch burst coalesces into one native replacement (before=\(beforeRecoveryBurst), after=\(recoveryBridge.calls.count), pending=\(recoveryBridge.pending.count), busy=\(recovery.busy), hidden=\(recovery.hidden))")
        let staleReplacement = recoveryBridge.pending.removeFirst()
        recovery.environmentChanged(rebuild: false, application: "fixture.newer")
        awaitTransition { !recoveryBridge.pending.isEmpty }
        let staleRecoveryHandle = FixtureHandle(); staleReplacement(staleRecoveryHandle)
        try require(staleRecoveryHandle.invalidations == 1 && recoveryBridge.pending.count == 1,
                    "A newer environment supersedes an in-flight replacement without losing its recovery")
        recoveryBridge.pending.removeFirst()(FixtureHandle())
        var lateRecoveryRead: (([MenuBarEntry]) -> Void)?
        recovery.readOverride = { _, done in lateRecoveryRead = done }
        recovery.environmentChanged(rebuild: true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.19))
        let beforeLateRecovery = recoveryBridge.calls.count
        recovery.showAll(); lateRecoveryRead?(entries)
        try require(!recovery.hidden && recoveryBridge.calls.count == beforeLateRecovery,
                    "A late inventory cannot hide icons after the user chose show-all")
        recovery.readOverride = { _, done in done(entries) }; recovery.readEntries(force: true); recovery.apply()
        recoveryBridge.pending.removeFirst()(FixtureHandle())
        recovery.environmentChanged(rebuild: true); let beforeRecoveryStop = recoveryBridge.calls.count; recovery.stop()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.19))
        try require(recoveryBridge.calls.count == beforeRecoveryStop && !recovery.hidden, "Stop cancels automatic recovery and leaves native icons accessible")
        let menuRecoveryDefaults = UserDefaults(suiteName: suite + ".menu-recovery")!
        defer { menuRecoveryDefaults.removePersistentDomain(forName: suite + ".menu-recovery") }
        let menuRecoveryBridge = FixtureVisibility(), menuRecovery = MenuBarDrawer(defaults: menuRecoveryDefaults, visibility: menuRecoveryBridge)
        menuRecovery.permissionOverride = true; menuRecovery.testSkipInput = true; menuRecovery.testSkipEnvironment = true; menuRecovery.testNoPresentation = true
        menuRecovery.anchorProvider = { anchor }; menuRecovery.pointer = { CGPoint(x: anchor.midX, y: anchor.midY) }
        menuRecovery.readOverride = { _, done in done(entries) }; menuRecovery.iconReadOverride = nativeIconRead
        menuRecovery.pressOverride = { _, _, done in done(true) }
        menuRecovery.start(); menuRecovery.prepareDrag(); menuRecovery.add(a); menuRecoveryBridge.pending.removeFirst()(FixtureHandle())
        menuRecovery.openMenu(a)
        var menuRecoveryRead: (([MenuBarEntry]) -> Void)?, menuRecoveryToken: MenuBarReadToken?
        menuRecovery.readOverride = { token, done in menuRecoveryToken = token; menuRecoveryRead = done }
        let beforeMenuRecovery = menuRecoveryBridge.calls.count
        menuRecovery.hover(anchor, inside: true)
        try require(menuRecoveryToken?.isCancelled == false && menuRecoveryBridge.calls.count == beforeMenuRecovery,
                    "Fallback hover waits for fresh icon geometry instead of cancelling its own read")
        menuRecoveryRead?(entries)
        try require(menuRecoveryBridge.calls.count == beforeMenuRecovery + 1, "Fresh geometry completes fallback menu collection")
        menuRecoveryBridge.pending.removeFirst()(FixtureHandle()); menuRecovery.stop()
        let targetedDefaults = UserDefaults(suiteName: suite + ".targeted")!
        defer { targetedDefaults.removePersistentDomain(forName: suite + ".targeted") }
        targetedDefaults.set([a, b], forKey: "menuBarShelf.drawerBundles.v1")
        let targetedBridge = FixtureVisibility(), targeted = MenuBarDrawer(defaults: targetedDefaults, visibility: targetedBridge)
        targeted.permissionOverride = true; targeted.testSkipInput = true; targeted.testSkipEnvironment = true; targeted.testNoPresentation = true
        targeted.readOverride = { _, done in done(entries) }; targeted.iconReadOverride = nativeIconRead
        var targetedPresses = [String]()
        targeted.pressOverride = { entry, _, done in targetedPresses.append(entry.bundle); done(true) }
        targeted.start(); let collectedHandle = FixtureHandle(); targetedBridge.pending.removeFirst()(collectedHandle)
        targeted.openMenu(a); targeted.openMenu(a)
        try require(targetedBridge.pending.count == 1 && collectedHandle.invalidations == 0 && targetedPresses.isEmpty,
                    "Double click waits for one target exception without releasing the collected restriction")
        try require(targetedBridge.calls.last!.contains(a) && !targetedBridge.calls.last!.contains(b),
                    "Opening one menu permits only its owner and leaves other drawer apps hidden")
        let targetHandle = FixtureHandle(); targetedBridge.pending.removeFirst()(targetHandle)
        targeted.openMenu(a)
        try require(targetedPresses == [a] && collectedHandle.invalidations == 1 && targetHandle.invalidations == 0 && targeted.hidden && targeted.order == [a,b],
                    "The target receives exactly one native action; collection membership and other hidden icons remain unchanged")
        targeted.openMenu(b); targetedBridge.pending.removeFirst()(nil)
        try require(targetHandle.invalidations == 0 && targeted.hidden && targeted.issue != nil,
                    "Failed menu exception retains the working restriction rather than exposing the whole bar")
        targeted.activationTimeout = 0.02; targeted.openMenu(b)
        let lateException = targetedBridge.pending.removeFirst()
        awaitTransition { !targeted.busy }
        let lateExceptionHandle = FixtureHandle(); lateException(lateExceptionHandle)
        try require(lateExceptionHandle.invalidations == 1 && targetHandle.invalidations == 0 && !targeted.busy,
                    "Timed-out target exceptions discard late handles without exposing other icons")
        targeted.openMenu(b); let cancelledException = targetedBridge.pending.removeFirst(); targeted.showAll()
        let cancelledHandle = FixtureHandle(); cancelledException(cancelledHandle)
        try require(cancelledHandle.invalidations == 1 && targetHandle.invalidations == 1 && !targeted.hidden,
                    "Explicit show-all cancels a menu exception and prevents a stale callback from rehiding icons")
        targeted.readOverride = { _, done in done(entries) }; targeted.apply(); let retainedAfterRead = FixtureHandle(); targetedBridge.pending.removeFirst()(retainedAfterRead)
        targeted.iconReadTimeout = 0.02; targeted.readOverride = { _, _ in }; targeted.readEntries(force: true)
        awaitTransition { targeted.issue?.contains("读取超时") == true }
        try require(retainedAfterRead.invalidations == 0 && targeted.hidden && targeted.issue?.contains("读取超时") == true,
                    "An icon read timeout keeps the last successful native hiding rule")
        targeted.stop()
        var nativeSelection = MenuBarMenuSelection()
        try require(!nativeSelection.receive(false) && !nativeSelection.receive(nil), "A closed/unreadable custom popover does not start an automatic hide timeout")
        try require(!nativeSelection.receive(true) && !nativeSelection.receive(true, closedNotification: true),
                    "Closing a submenu does not hide its still-selected parent menu")
        try require(nativeSelection.receive(false) && !nativeSelection.receive(false), "A confirmed selected-to-unselected transition closes exactly once")
        var notifiedSelection = MenuBarMenuSelection()
        try require(notifiedSelection.receive(nil, closedNotification: true), "A real menu-close event remains usable when selection is unavailable")
        // A late inventory cannot recreate a stopped module or install hiding.
        let delayedDefaults = UserDefaults(suiteName: suite + ".delayed")!
        defer { delayedDefaults.removePersistentDomain(forName: suite + ".delayed") }
        let delayed = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        delayed.iconReadOverride = nativeIconRead
        delayed.permissionOverride = true; delayed.testSkipInput = true; delayed.testSkipEnvironment = true; delayed.testNoPresentation = true
        var readBack: (([MenuBarEntry]) -> Void)?, readToken: MenuBarReadToken?
        delayed.readOverride = { token, callback in readToken = token; readBack = callback }
        delayed.start(); delayed.prepareDrag(); delayed.stop(); readBack?(entries)
        try require(readToken?.isCancelled == true && delayed.entries.isEmpty && !delayed.input.enabled, "Stopped inventory never restores stale entries or input capture")
        let latest = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        latest.iconReadOverride = nativeIconRead
        latest.permissionOverride = true; latest.testSkipInput = true; latest.testSkipEnvironment = true; latest.testNoPresentation = true
        latest.readOverride = { _, callback in readBack = callback }
        var latestPresses = [String]()
        latest.pressOverride = { entry, _, callback in latestPresses.append(entry.bundle); callback(true) }
        latest.start(); latest.openMenu(a); latest.openMenu(b); readBack?(entries)
        try require(latestPresses == [b], "Only the latest requested menu may open after queued inventory; earlier clicks cannot open two apps")
        latest.stop()
        // Exercise transitions with the real native view/window and fake OS
        // handles, without moving the user's pointer or hiding live icons.
        let continuityDefaults = UserDefaults(suiteName: suite + ".continuity")!
        defer { continuityDefaults.removePersistentDomain(forName: suite + ".continuity") }
        let continuityBridge = FixtureVisibility(), continuity = MenuBarDrawer(defaults: continuityDefaults, visibility: continuityBridge)
        continuity.permissionOverride = true; continuity.testSkipInput = true; continuity.testSkipEnvironment = true; continuity.testNoPresentation = true
        continuity.iconReadOverride = nativeIconRead; continuity.readOverride = { _, done in done(entries) }
        continuity.pressedButtons = { 0 }; continuity.dismissDelay = 0.025
        var currentAnchor = anchor, pointer = CGPoint(x: anchor.midX, y: anchor.midY)
        continuity.anchorProvider = { currentAnchor }; continuity.pointer = { pointer }
        continuity.start(); continuity.hover(currentAnchor, inside: true)
        continuity.add(a); continuityBridge.pending.removeFirst()(FixtureHandle())
        let popup = continuity.view.window!, initialFrame = continuity.view.window!.frame
        let child = continuity.view.accessibilityChildren()!.first as AnyObject
        continuity.show(); continuity.show()
        try require(continuity.view.window === popup && popup.frame == initialFrame && continuity.view.accessibilityChildren()!.first as AnyObject === child,
                    "Repeated hover preserves the native window, geometry and accessibility children")
        continuity.view.updateTrackingAreas()
        try require(continuity.view.trackingAreas.contains { $0.options.contains(.enabledDuringMouseDrag) }, "Drawer hover remains active during a held drag")
        for position in [CGPoint(x: anchor.midX, y: anchor.midY), CGPoint(x: initialFrame.midX, y: initialFrame.maxY + 2), CGPoint(x: initialFrame.midX, y: initialFrame.midY)] {
            pointer = position
            continuity.hover(currentAnchor, inside: false); continuity.view.onPresence?(false)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
            try require(continuity.isOpen && !continuity.hasDismissWork, "Obsolete apple/drawer exits cannot collapse the shared hover region")
        }
        currentAnchor = currentAnchor.offsetBy(dx: -100, dy: 0)
        continuity.show()
        try require(popup.frame == initialFrame, "Native apple reflow does not recenter the open drawer")
        pointer = CGPoint(x: currentAnchor.maxX + 10, y: initialFrame.maxY + 1)
        continuity.presence(false)
        try require(continuity.contains(pointer) && !continuity.hasDismissWork, "A continuous connector spans a moved apple and the stable drawer")
        currentAnchor = currentAnchor.offsetBy(dx: 0, dy: -300)
        try require(!continuity.contains(CGPoint(x: initialFrame.midX, y: initialFrame.maxY - 150)), "A different display height cannot create a tall invisible hover region")
        currentAnchor = currentAnchor.offsetBy(dx: 0, dy: 300)
        pointer = CGPoint(x: initialFrame.midX, y: initialFrame.midY)
        continuity.add(b)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.04))
        try require(continuity.isOpen && !continuity.hasDismissWork, "Pending drag-in activation cannot dismiss the drawer")
        continuityBridge.pending.removeFirst()(FixtureHandle())
        let twoItemFrame = popup.frame
        continuity.restore(b); continuityBridge.pending.removeFirst()(FixtureHandle())
        try require(popup.frame == twoItemFrame, "Drag-out does not shrink the hit region out from under the pointer")
        continuity.close()
        pointer = CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)
        continuity.hover(currentAnchor, inside: true)
        try require(!continuity.isOpen, "An obsolete apple enter cannot reopen a closed drawer")
        pointer = CGPoint(x: currentAnchor.midX, y: currentAnchor.midY)
        continuity.hover(currentAnchor, inside: true)
        try require(popup.frame.width < twoItemFrame.width, "The next genuine opening restores compact content width")
        let activeCell = continuity.view.cellFrame(0)
        func continuityEvent(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: continuity.view.convert(point, to: nil), modifierFlags: [.command], timestamp: 0,
                               windowNumber: popup.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        continuity.view.mouseDown(with: continuityEvent(.leftMouseDown, CGPoint(x: activeCell.midX, y: activeCell.midY)))
        pointer = CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)
        continuity.view.mouseDragged(with: continuityEvent(.leftMouseDragged, CGPoint(x: -30, y: -30)))
        continuity.presence(false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try require(continuity.view.isDragging && continuity.isOpen && !continuity.hasDismissWork, "Local drag holds the drawer open even when a tracking exit arrives outside")
        continuity.view.mouseUp(with: continuityEvent(.leftMouseUp, CGPoint(x: -30, y: -30)))
        try require(!continuity.view.isDragging && continuity.isOpen && continuity.hasDismissWork, "After drag-out releases, idle dismissal is rearmed without immediate collapse")
        pointer = CGPoint(x: popup.frame.midX, y: popup.frame.midY)
        continuity.view.onPresence?(true)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        try require(continuity.isOpen && !continuity.hasDismissWork, "Re-entering after release cancels the old deadline")
        pointer = CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY)
        continuity.presence(false)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        let dismissalDeadline = Date(timeIntervalSinceNow: 1)
        while continuity.isOpen, Date() < dismissalDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
        try require(!continuity.isOpen, "Only a full idle delay outside all regions closes the drawer")
        continuity.stop()
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
        let replayDeadline = Date(timeIntervalSinceNow: 5)
        while !replayFinished, Date() < replayDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.005)) }
        try require(replayed == [.leftMouseDown, .leftMouseUp] && replayFinished, "Cancelled replay releases its own mouse down but never posts a new drag")
        let offlineDefaults = UserDefaults(suiteName: suite + ".offline")!
        defer { offlineDefaults.removePersistentDomain(forName: suite + ".offline") }
        offlineDefaults.set([a, b], forKey: "menuBarShelf.drawerBundles.v1")
        let offline = MenuBarDrawer(defaults: offlineDefaults, visibility: bridge)
        offline.iconReadOverride = nativeIconRead
        offline.permissionOverride = true; offline.testSkipInput = true; offline.testSkipEnvironment = true; offline.testNoPresentation = true
        offline.readOverride = { _, done in done([]) }
        let callsBeforeOffline = bridge.calls.count
        offline.start(); offline.restore(a)
        try require(offline.order == [b] && !offline.hidden && !offline.busy && bridge.calls.count == callsBeforeOffline, "An unreadable remaining app cannot prevent removing a saved drawer member")
        offline.stop()
        let missing = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        missing.permissionOverride = true; missing.testSkipInput = true; missing.testSkipEnvironment = true; missing.testNoPresentation = true
        missing.readOverride = { _, done in done(entries) }; missing.iconReadOverride = { _, _, done in done([:]) }
        missing.start(); missing.prepareDrag()
        let beforeMissing = bridge.calls.count
        missing.add(a)
        try require(missing.item(a).icon == nil && missing.input.entries.isEmpty && bridge.calls.count == beforeMissing && !missing.hidden,
                    "Missing original pixels cannot hide the real entry, intercept its drag or substitute an application icon")
        missing.stop()
        let lateIcons = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        lateIcons.permissionOverride = true; lateIcons.testSkipInput = true; lateIcons.testSkipEnvironment = true; lateIcons.testNoPresentation = true
        lateIcons.readOverride = { _, done in done(entries) }
        var latePixels: (([String: MenuBarIconPixels]) -> Void)?
        lateIcons.iconReadOverride = { _, _, done in latePixels = done }
        lateIcons.start(); lateIcons.prepareDrag(); lateIcons.stop()
        nativeIconRead(entries, MenuBarReadToken()) { latePixels?($0) }
        try require(lateIcons.item(a).icon == nil && lateIcons.input.entries.isEmpty, "Late screen pixels cannot repopulate a stopped drawer")
        let compositorArea = CGRect(x: 1512, y: -241, width: 2560, height: 30)
        let stale = MenuBarEntry(bundle: a, frame: CGRect(x: 3600, y: -239, width: 20, height: 24), pid: 101)
        let physical = MenuBarContainer(pid: 101, frame: CGRect(x: 3800, y: -241, width: 44, height: 30), surface: compositorArea)
        let reconciled = MenuBarContainerGeometry.reconcile([stale], containers: [physical])[0]
        try require(reconciled.visible && reconciled.frame == physical.frame && reconciled.pid == stale.pid,
                    "Native compositor container replaces stale application coordinates and includes the full icon height")
        let nativeSurface = CGContext(data: nil, width: 5120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let physicalX = (physical.frame.minX - compositorArea.minX) * 2
        nativeSurface.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        nativeSurface.fill(CGRect(x: physicalX + 4, y: 0, width: 4, height: 60))
        nativeSurface.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        nativeSurface.fill(CGRect(x: physicalX + 80, y: 0, width: 4, height: 60))
        let fullGlyph = MenuBarIconCapture.crop(nativeSurface.makeImage()!, surface: compositorArea, item: reconciled.frame)!
        let fullBitmap = NSBitmapImageRep(cgImage: fullGlyph.image)
        try require(fullGlyph.size == CGSize(width: 44, height: 30) && fullBitmap.colorAt(x: 5, y: 30)!.redComponent > 0.9
                        && fullBitmap.colorAt(x: 81, y: 30)!.blueComponent > 0.9,
                    "Final native glyph retains both outer edges and full height after compositor reflow")
        let stableA = MenuBarEntry(bundle: a, frame: CGRect(x: 100, y: 0, width: 38, height: 30), pid: 101)
        let movingB = MenuBarEntry(bundle: b, frame: CGRect(x: 138, y: 0, width: 38, height: 30), pid: 102)
        let movedB = MenuBarEntry(bundle: b, frame: movingB.frame.offsetBy(dx: 18, dy: 0), pid: 102)
        try require(MenuBarIconCapture.stableEntries([stableA, movingB], after: [stableA, movedB]).map(\.bundle) == [a],
                    "A menu reflow during capture discards the moved glyph rather than caching half of its neighbour")
        let replacedA = MenuBarEntry(bundle: a, frame: stableA.frame, pid: 999)
        try require(MenuBarIconCapture.stableEntries([stableA], after: [replacedA]).isEmpty,
                    "An identical rectangle from a replacement process cannot validate an old capture")
        let hiddenA = MenuBarEntry(bundle: a, frame: stableA.frame, pid: 101, visible: false)
        try require(MenuBarIconCapture.stableEntries([stableA], after: [hiddenA]).isEmpty && fullGlyph.sourceFrame == physical.frame,
                    "Hidden entries cannot validate pixels; a complete crop records its actual source bounds")
        let hiddenEntry = MenuBarContainerGeometry.reconcile([stale], containers: [])[0]
        try require(!hiddenEntry.visible && hiddenEntry.frame == stale.frame, "Hidden app coordinates cannot be treated as a visible pixel source")
        let otherDisplay = MenuBarContainer(pid: 101, frame: CGRect(x: 100, y: 0, width: 44, height: 33), surface: CGRect(x: 0, y: 0, width: 1512, height: 33))
        try require(!MenuBarContainerGeometry.reconcile([stale], containers: [otherDisplay])[0].visible,
                    "Incomplete native inventory cannot substitute a matching PID from another display")
        try require(MenuBarContainerGeometry.reconcile([stale], containers: [otherDisplay, physical])[0].frame == physical.frame,
                    "Multi-display coordinates retain the physical menu surface and original owner")
        let cacheDefaults = UserDefaults(suiteName: suite + ".pixel-layout")!
        defer { cacheDefaults.removePersistentDomain(forName: suite + ".pixel-layout") }
        let cacheBridge = FixtureVisibility(), cacheOwner = MenuBarDrawer(defaults: cacheDefaults, visibility: cacheBridge)
        cacheOwner.permissionOverride = true; cacheOwner.testSkipInput = true; cacheOwner.testSkipEnvironment = true; cacheOwner.testNoPresentation = true; cacheOwner.pressedButtons = { 0 }
        var snapshot = entries
        cacheOwner.readOverride = { _, done in done(snapshot) }; cacheOwner.iconReadOverride = nativeIconRead
        cacheOwner.start(); cacheOwner.prepareDrag()
        let confirmedIcon = cacheOwner.item(a).icon
        snapshot = entries.map { MenuBarEntry(bundle: $0.bundle, frame: $0.frame, pid: $0.pid, visible: false) }
        var requestedPixels = [MenuBarEntry]()
        cacheOwner.iconReadOverride = { requested, token, done in requestedPixels = requested; nativeIconRead(requested, token, done) }
        cacheOwner.readEntries(force: true)
        try require(requestedPixels.isEmpty && cacheOwner.item(a).icon === confirmedIcon && cacheOwner.input.entries.isEmpty,
                    "Unresolved containers preserve verified images and never arm stale native drag targets")
        snapshot = entries
        var stalePixels: (([String: MenuBarIconPixels]) -> Void)?, staleToken: MenuBarReadToken?
        cacheOwner.iconReadOverride = { _, token, done in staleToken = token; stalePixels = done }
        cacheOwner.readEntries(force: true); cacheOwner.add(a)
        try require(staleToken?.isCancelled == true, "Changing native visibility cancels any position/image pair captured before reflow")
        var wrongPixels: [String: MenuBarIconPixels] = [:]
        nativeIconRead(entries, MenuBarReadToken()) { wrongPixels = $0 }
        stalePixels?(wrongPixels)
        try require(cacheOwner.item(a).icon === confirmedIcon, "Late pre-reflow crops cannot replace the verified original")
        cacheBridge.pending.removeFirst()(nil)
        cacheOwner.readEntries(force: true)
        let restoredLayoutToken = staleToken
        cacheOwner.showAll()
        try require(restoredLayoutToken?.isCancelled == true && cacheOwner.input.entries.isEmpty,
                    "Explicit native restoration also invalidates in-flight pixels and drag coordinates")
        let geometryDefaults = UserDefaults(suiteName: suite + ".capture-geometry")!
        defer { geometryDefaults.removePersistentDomain(forName: suite + ".capture-geometry") }
        let geometryOwner = MenuBarDrawer(defaults: geometryDefaults, visibility: FixtureVisibility())
        geometryOwner.permissionOverride = true; geometryOwner.testSkipInput = true; geometryOwner.testSkipEnvironment = true; geometryOwner.testNoPresentation = true
        geometryOwner.readOverride = { _, done in done(entries) }; geometryOwner.iconReadOverride = nativeIconRead
        geometryOwner.start(); geometryOwner.prepareDrag()
        let verifiedOriginal = geometryOwner.item(a).icon
        try require(verifiedOriginal != nil && !geometryOwner.input.entries.isEmpty, "Geometry fixture starts with real cached images and active native drag targets")
        geometryOwner.iconReadOverride = { _, _, done in done([:]) }
        geometryOwner.readEntries(force: true)
        try require(geometryOwner.item(a).icon === verifiedOriginal && geometryOwner.input.entries.isEmpty,
                    "A reflow rejected by pixel capture keeps the good image but never arms stale native drag coordinates")
        let currentFrame = CGRect(x: 600, y: 0, width: 20, height: 24)
        geometryOwner.iconReadOverride = { requested, token, done in
            nativeIconRead(requested, token) { values in
                var refreshed = values
                for key in Array(refreshed.keys) { refreshed[key]?.sourceFrame = currentFrame }
                done(refreshed)
            }
        }
        geometryOwner.readEntries(force: true)
        try require(Set(geometryOwner.entries.filter(\.visible).map(\.bundle)) == Set([a, b, c])
                    && geometryOwner.entries.filter(\.visible).allSatisfy { $0.frame == currentFrame }
                    && !geometryOwner.input.entries.isEmpty && geometryOwner.input.entries.allSatisfy { $0.frame == currentFrame },
                    "Accepted fresh pixels and native drag hit targets use the same capture-time coordinates")
        geometryOwner.stop()
        cacheOwner.stop()
        let pixels = CGContext(data: nil, width: 120, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 120, height: 48))
        let surface = pixels.makeImage()!, area = CGRect(x: 1512, y: -241, width: 60, height: 24)
        let cropped = MenuBarIconCapture.crop(surface, surface: area, item: CGRect(x: 1532, y: -241, width: 20, height: 24))!
        try require(cropped.size == CGSize(width: 20, height: 24) && cropped.image.width == 40 && cropped.image.height == 48,
                    "Native glyph crops use global Quartz coordinates, negative display origins and real Retina scale")
        try require(MenuBarIconCapture.crop(surface, surface: area, item: area.offsetBy(dx: -1, dy: 0)) == nil, "Out-of-surface entries must not capture unrelated pixels")
        let timedIcons = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        timedIcons.permissionOverride = true; timedIcons.testSkipInput = true; timedIcons.testSkipEnvironment = true; timedIcons.testNoPresentation = true; timedIcons.iconReadTimeout = 0.02
        timedIcons.readOverride = { _, done in done(entries) }; timedIcons.iconReadOverride = { _, _, _ in }
        timedIcons.start(); timedIcons.prepareDrag()
        awaitTransition { timedIcons.issue != nil }
        try require(!timedIcons.hidden && !timedIcons.busy && timedIcons.issue?.contains("超时") == true, "An unresponsive native pixel request fails open and reports a retry instead of stranding hidden icons")
        timedIcons.stop()
        // Existing native UI is rendered using fixture app identities, not the
        // user's live inventory or preferences. Wide and narrow bounds are checked.
        let module = MenuBarShelfModule(defaults: defaults, visibility: bridge, native: true)
        module.configureDrawer = { $0.permissionOverride = false; $0.testSkipInput = true; $0.testSkipEnvironment = true; $0.testNoPresentation = true }
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
                owner.permissionOverride = false; owner.testSkipInput = true; owner.testSkipEnvironment = true; owner.testNoPresentation = true
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
        print("Menu drawer regression passed: collected-state recovery, explicit show-all, coalesced replacement, menu selection and submenu lifetime, transactional membership, saved order, real view drag, native action routing, hover corridor, idle delay, failure/timeout/stop, input capture isolation and narrow settings. No real application icons were hidden or events posted.")
    }
}
