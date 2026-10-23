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
        drawer.menuInteraction.captureOverride = { _, done in done(true) }; drawer.permissionOverride = true; drawer.testNoPresentation = true; drawer.testSkipInput = true; drawer.testSkipEnvironment = true
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
        try require(third.invalidations == 0 && bridge.pending.count == 1 && pressed.isEmpty, "Native activation keeps the collected restriction until the covered input surface is ready")
        let menuAccess = FixtureHandle(); bridge.pending.removeFirst()(menuAccess)
        try require(pressed == [a] && !drawer.isOpen, "The native owner receives the operation once")
        awaitTransition { !bridge.pending.isEmpty }
        let menuRestored = FixtureHandle(); bridge.pending.removeFirst()(menuRestored)
        awaitTransition { !drawer.busy }
        try require(third.invalidations == 1 && menuAccess.invalidations == 1 && drawer.hidden && menuRestored.invalidations == 0, "The complete collection is restored before activation finishes")
        drawer.show(); drawer.dismissDelay = 0.02
        drawer.pointer = { CGPoint(x: anchor.midX, y: anchor.minY - 2) }
        drawer.presence(false)
        try require(!drawer.hasDismissWork, "Apple-to-drawer connector corridor must not schedule collapse")
        drawer.pointer = { CGPoint(x: screen.visibleFrame.minX, y: screen.visibleFrame.minY) }
        drawer.presence(false)
        try require(drawer.hasDismissWork, "Leaving creates one delayed dismissal")
        drawer.pointer = { CGPoint(x: anchor.midX, y: anchor.midY) }
        drawer.hover(anchor, inside: true)
        try require(bridge.pending.isEmpty && drawer.hidden, "Returning to apple needs no extra collection after a completed native gesture")
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
        restored.menuInteraction.captureOverride = { _, done in done(true) }; restored.permissionOverride = false; restored.testNoPresentation = true; restored.testSkipInput = true; restored.testSkipEnvironment = true
        restored.start(); restored.prepareDrag()
        try require(restored.issue != nil && !restored.hidden, "Missing permission must be explicit and fail open")
        restored.stop()
        let recoveryDefaults = UserDefaults(suiteName: suite + ".recovery")!
        defer { recoveryDefaults.removePersistentDomain(forName: suite + ".recovery") }
        let recoveryBridge = FixtureVisibility(), recovery = MenuBarDrawer(defaults: recoveryDefaults, visibility: recoveryBridge)
        recovery.menuInteraction.captureOverride = { _, done in done(true) }; recovery.permissionOverride = true; recovery.testSkipInput = true; recovery.testSkipEnvironment = true; recovery.testNoPresentation = true
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
        let targetedDefaults = UserDefaults(suiteName: suite + ".targeted")!
        defer { targetedDefaults.removePersistentDomain(forName: suite + ".targeted") }
        targetedDefaults.set([a, b], forKey: "menuBarShelf.drawerBundles.v1")
        let targetedBridge = FixtureVisibility(), targeted = MenuBarDrawer(defaults: targetedDefaults, visibility: targetedBridge)
        targeted.menuInteraction.captureOverride = { _, done in done(true) }; targeted.permissionOverride = true; targeted.testSkipInput = true; targeted.testSkipEnvironment = true; targeted.testNoPresentation = true
        targeted.readOverride = { _, done in done(entries) }; targeted.iconReadOverride = nativeIconRead
        var targetedPresses = [String]()
        targeted.pressOverride = { entry, _, done in targetedPresses.append(entry.bundle); done(true) }
        targeted.start(); let collectedHandle = FixtureHandle(); targetedBridge.pending.removeFirst()(collectedHandle)
        targeted.openMenu(a); targeted.openMenu(a)
        try require(targetedBridge.pending.count == 1 && collectedHandle.invalidations == 0 && targetedPresses.isEmpty,
                    "Repeated activation waits for one covered native input surface")
        try require(targetedBridge.calls.last!.contains(a) && !targetedBridge.calls.last!.contains(b), "The temporary input surface is limited to its native owner")
        let targetHandle = FixtureHandle(); targetedBridge.pending.removeFirst()(targetHandle)
        try require(targetedPresses == [a] && collectedHandle.invalidations == 1 && targetHandle.invalidations == 0,
                    "The covered native input assertion replaces the old rule only once it is active")
        awaitTransition { !targetedBridge.pending.isEmpty }
        try require(!targetedBridge.calls.last!.contains(a) && !targetedBridge.calls.last!.contains(b), "Every collected app is hidden again after mouse-up, without waiting for menu-close detection")
        let restoredMenuHandle = FixtureHandle(); targetedBridge.pending.removeFirst()(restoredMenuHandle)
        awaitTransition { !targeted.busy }
        try require(targeted.hidden && targeted.order == [a,b] && collectedHandle.invalidations == 1 && targetHandle.invalidations == 1,
                    "Menu activation preserves membership and releases both obsolete assertions")
        targeted.openMenu(b); targetedBridge.pending.removeFirst()(nil)
        try require(restoredMenuHandle.invalidations == 0 && targeted.hidden, "A failed input assertion keeps the original hidden handle")
        targetedBridge.pending.removeFirst()(FixtureHandle()); awaitTransition { !targeted.busy }
        try require(targeted.issue != nil && targeted.hidden, "A rejected activation reports failure while retaining collection")
        targeted.menuInteractionTimeout = 0.02; targeted.openMenu(b)
        let lateException = targetedBridge.pending.removeFirst()
        awaitTransition { !targetedBridge.pending.isEmpty }
        let lateExceptionHandle = FixtureHandle(); lateException(lateExceptionHandle)
        try require(lateExceptionHandle.invalidations == 1 && targeted.hidden, "A timed-out native activation cannot revive its input surface")
        targetedBridge.pending.removeFirst()(FixtureHandle()); awaitTransition { !targeted.busy }
        targeted.openMenu(b); let cancelledException = targetedBridge.pending.removeFirst(); targeted.showAll()
        let cancelledHandle = FixtureHandle(); cancelledException(cancelledHandle)
        try require(cancelledHandle.invalidations == 1 && !targeted.hidden && !targeted.busy,
                    "Explicit show-all cancels native delivery and discards its late assertion")
        targeted.readOverride = { _, done in done(entries) }; targeted.apply(); let retainedAfterRead = FixtureHandle(); targetedBridge.pending.removeFirst()(retainedAfterRead)
        targeted.iconReadTimeout = 0.02; targeted.readOverride = { _, _ in }; targeted.readEntries(force: true)
        awaitTransition { targeted.issue?.contains("读取超时") == true }
        try require(retainedAfterRead.invalidations == 0 && targeted.hidden && targeted.issue?.contains("读取超时") == true,
                    "An icon read timeout keeps the last successful native hiding rule")
        targeted.stop()
        // Real view mouse routing preserves both pairs of a double click.
        // Only the event sink is substituted; no global events are posted.
        let clickView = MenuBarDrawerView(frame: CGRect(x: 0, y: 0, width: 100, height: 44))
        clickView.items = [.init(bundle: a, name: "Native fixture", icon: nil)]
        var gestures: [[MenuBarPointerSample]] = []
        clickView.onActivate = { _, samples in gestures.append(samples) }
        let clickCell = clickView.cellFrame(0)
        func pointerEvent(_ type: NSEvent.EventType, count: Int, time: TimeInterval, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: clickCell.midX, y: clickCell.midY), modifierFlags: modifiers,
                               timestamp: time, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        clickView.mouseDown(with: pointerEvent(.leftMouseDown, count: 1, time: 1))
        clickView.mouseUp(with: pointerEvent(.leftMouseUp, count: 1, time: 1.02))
        try require(gestures.isEmpty, "The first click remains available for the system double-click interval")
        clickView.mouseDown(with: pointerEvent(.leftMouseDown, count: 2, time: 1.1, modifiers: [.option]))
        clickView.mouseUp(with: pointerEvent(.leftMouseUp, count: 2, time: 1.12, modifiers: [.option]))
        try require(gestures.count == 1 && gestures[0].map(\.count) == [1,1,2,2] && gestures[0][2].flags.contains(.maskAlternate),
                    "A double click keeps both original down/up pairs, counts, timing and modifier keys")
        let nativeDelivery = MenuBarNativeInteraction(), nativeToken = MenuBarReadToken()
        nativeDelivery.captureOverride = { _, done in done(true) }
        nativeDelivery.prepare(token: nativeToken) { _ in }
        var delivered: [MenuBarPointerSample] = [], nativeFinished = false
        nativeDelivery.sendOverride = { _, _, sample in if let sample { delivered.append(sample) } }
        nativeDelivery.deliver(gestures[0], point: .zero, token: nativeToken) { nativeFinished = $0 }
        awaitTransition { nativeFinished }
        try require(delivered.map(\.type) == [.leftMouseDown,.leftMouseUp,.leftMouseDown,.leftMouseUp]
                    && delivered.map(\.count) == [1,1,2,2] && delivered[2].flags.contains(.maskAlternate),
                    "The native relay does not replace a double click with AXPress or app activation")
        nativeDelivery.cancel()
        clickView.mouseDown(with: pointerEvent(.leftMouseDown, count: 1, time: 2))
        clickView.mouseUp(with: pointerEvent(.leftMouseUp, count: 1, time: 2.02))
        awaitTransition { gestures.count == 2 }
        try require(gestures.count == 2 && gestures.last!.map(\.count) == [1,1], "A standalone single click is forwarded exactly once")
        clickView.rightMouseDown(with: pointerEvent(.rightMouseDown, count: 1, time: 3, modifiers: [.shift]))
        clickView.rightMouseUp(with: pointerEvent(.rightMouseUp, count: 1, time: 3.02, modifiers: [.shift]))
        try require(gestures.count == 3 && gestures.last!.map(\.type) == [.rightMouseDown,.rightMouseUp], "Native context-menu clicks retain their mouse button")
        clickView.mouseDown(with: pointerEvent(.leftMouseDown, count: 1, time: 4))
        clickView.mouseUp(with: pointerEvent(.leftMouseUp, count: 1, time: 4.02))
        clickView.cancelActivation()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: NSEvent.doubleClickInterval + 0.02))
        try require(gestures.count == 3, "Closing or cancelling the drawer discards pending activation")
        let cancelDelivery = MenuBarNativeInteraction(), cancelToken = MenuBarReadToken()
        cancelDelivery.captureOverride = { _, done in done(true) }; cancelDelivery.prepare(token: cancelToken) { _ in }
        var cancelledEvents: [CGEventType] = []
        cancelDelivery.sendOverride = { type, _, _ in
            cancelledEvents.append(type)
            if type == .leftMouseDown { cancelDelivery.cancelInput() }
        }
        cancelDelivery.deliver(MenuBarPointerSample.singleClick, point: .zero, token: cancelToken) { _ in }
        awaitTransition { cancelToken.isCancelled }
        try require(cancelledEvents == [.mouseMoved,.leftMouseDown,.leftMouseUp], "Cancelling native input releases its own pressed button and drops later events")
        cancelDelivery.cancel()
        try require(!MenuBarPointerSample.valid([.init(type: .leftMouseDown, timestamp: 0)])
                    && !MenuBarPointerSample.valid([.init(type: .leftMouseDown, timestamp: 0),.init(type: .leftMouseUp, timestamp: 4)]),
                    "Unpaired or unbounded gestures are rejected before changing native visibility")
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
        delayed.menuInteraction.captureOverride = { _, done in done(true) }; delayed.permissionOverride = true; delayed.testSkipInput = true; delayed.testSkipEnvironment = true; delayed.testNoPresentation = true
        var readBack: (([MenuBarEntry]) -> Void)?, readToken: MenuBarReadToken?
        delayed.readOverride = { token, callback in readToken = token; readBack = callback }
        delayed.start(); delayed.prepareDrag(); delayed.stop(); readBack?(entries)
        try require(readToken?.isCancelled == true && delayed.entries.isEmpty && !delayed.input.enabled, "Stopped inventory never restores stale entries or input capture")
        let latest = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        latest.iconReadOverride = nativeIconRead
        latest.menuInteraction.captureOverride = { _, done in done(true) }; latest.permissionOverride = true; latest.testSkipInput = true; latest.testSkipEnvironment = true; latest.testNoPresentation = true
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
        continuity.menuInteraction.captureOverride = { _, done in done(true) }; continuity.permissionOverride = true; continuity.testSkipInput = true; continuity.testSkipEnvironment = true; continuity.testNoPresentation = true
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
        offline.menuInteraction.captureOverride = { _, done in done(true) }; offline.permissionOverride = true; offline.testSkipInput = true; offline.testSkipEnvironment = true; offline.testNoPresentation = true
        offline.readOverride = { _, done in done([]) }
        let callsBeforeOffline = bridge.calls.count
        offline.start(); offline.restore(a)
        try require(offline.order == [b] && !offline.hidden && !offline.busy && bridge.calls.count == callsBeforeOffline, "An unreadable remaining app cannot prevent removing a saved drawer member")
        offline.stop()
        let missing = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        missing.menuInteraction.captureOverride = { _, done in done(true) }; missing.permissionOverride = true; missing.testSkipInput = true; missing.testSkipEnvironment = true; missing.testNoPresentation = true
        missing.readOverride = { _, done in done(entries) }; missing.iconReadOverride = { _, _, done in done([:]) }
        missing.start(); missing.prepareDrag()
        let beforeMissing = bridge.calls.count
        missing.add(a)
        try require(missing.item(a).icon == nil && missing.input.entries.isEmpty && bridge.calls.count == beforeMissing && !missing.hidden,
                    "Missing original pixels cannot hide the real entry, intercept its drag or substitute an application icon")
        missing.stop()

        let resumedDefaults = UserDefaults(suiteName: suite + ".cold-cache")!
        defer { resumedDefaults.removePersistentDomain(forName: suite + ".cold-cache") }
        resumedDefaults.set([a], forKey: "menuBarShelf.drawerBundles.v1")
        let resumedBridge = FixtureVisibility(), resumed = MenuBarDrawer(defaults: resumedDefaults, visibility: resumedBridge)
        resumed.permissionOverride = true; resumed.testSkipInput = true; resumed.testSkipEnvironment = true; resumed.testNoPresentation = true
        resumed.readOverride = { _, done in done(entries.map { MenuBarEntry(bundle: $0.bundle, frame: $0.frame, visible: false) }) }
        resumed.iconReadOverride = { _, _, done in done([:]) }
        resumed.start()
        try require(resumedBridge.calls.count == 1 && resumed.busy && resumed.item(a).icon == nil,
                    "A cold pixel cache cannot discard previously saved collection intent or expose its native owner")
        resumedBridge.pending.removeFirst()(FixtureHandle())
        try require(resumed.hidden && resumed.order == [a] && resumed.input.entries.isEmpty,
                    "Restoring saved membership never arms an unverified native drag geometry")
        resumed.stop()
        let lateIcons = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        lateIcons.menuInteraction.captureOverride = { _, done in done(true) }; lateIcons.permissionOverride = true; lateIcons.testSkipInput = true; lateIcons.testSkipEnvironment = true; lateIcons.testNoPresentation = true
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
        let duplicate = MenuBarContainer(pid: 101, frame: physical.frame.offsetBy(dx: -80, dy: 0), surface: compositorArea)
        try require(!MenuBarContainerGeometry.reconcile([stale], containers: [physical, duplicate])[0].visible,
                    "Two distinct items from one PID cannot be guessed from stale AX coordinates")
        try require(MenuBarContainerGeometry.reconcile([stale], containers: [physical, physical])[0].visible,
                    "Duplicate reports of the identical native container are safe to coalesce")
        let proxy = MenuBarContainer(pid: 102, frame: physical.frame.insetBy(dx: 2, dy: 0), surface: compositorArea)
        try require(!MenuBarContainerGeometry.reconcile([stale], containers: [physical, proxy])[0].visible,
                    "Overlapping native overflow proxies from different owners cannot become original icon crops")
        let sourced = MenuBarEntry(bundle: a, frame: physical.frame, pid: 101, surface: compositorArea, surfaceID: 42)
        try require(MenuBarIconCapture.matchesSurface(sourced, id: 42, frame: compositorArea, compositor: true)
                    && !MenuBarIconCapture.matchesSurface(sourced, id: 43, frame: compositorArea, compositor: true),
                    "Identical rectangles from different native surfaces cannot exchange icon pixels")
        let replacedSurface = MenuBarEntry(bundle: a, frame: physical.frame, pid: 101, surface: compositorArea, surfaceID: 43)
        try require(MenuBarIconCapture.stableEntries([sourced], after: [replacedSurface]).isEmpty,
                    "A recreated compositor window invalidates a crop even when its geometry did not change")
        try require(!MenuBarIconCapture.matchesSurface(stableA, id: 42, frame: compositorArea, compositor: true),
                    "Unresolved compositor identity never falls back to a rectangle-only match")
        let cacheDefaults = UserDefaults(suiteName: suite + ".pixel-layout")!
        defer { cacheDefaults.removePersistentDomain(forName: suite + ".pixel-layout") }
        let cacheBridge = FixtureVisibility(), cacheOwner = MenuBarDrawer(defaults: cacheDefaults, visibility: cacheBridge)
        cacheOwner.menuInteraction.captureOverride = { _, done in done(true) }; cacheOwner.permissionOverride = true; cacheOwner.testSkipInput = true; cacheOwner.testSkipEnvironment = true; cacheOwner.testNoPresentation = true; cacheOwner.pressedButtons = { 0 }
        var snapshot = entries
        cacheOwner.readOverride = { _, done in done(snapshot) }; cacheOwner.iconReadOverride = nativeIconRead
        cacheOwner.start(); cacheOwner.prepareDrag()
        var confirmedIcon = cacheOwner.item(a).icon
        snapshot = entries.map { MenuBarEntry(bundle: $0.bundle, frame: $0.frame, pid: $0.pid, visible: false) }
        var requestedPixels = [MenuBarEntry]()
        cacheOwner.iconReadOverride = { requested, token, done in requestedPixels = requested; nativeIconRead(requested, token, done) }
        cacheOwner.readEntries(force: true)
        try require(requestedPixels.isEmpty && cacheOwner.item(a).icon === confirmedIcon && cacheOwner.input.entries.isEmpty,
                    "Unresolved containers preserve verified images and never arm stale native drag targets")
        cacheOwner.add(a)
        try require(cacheBridge.calls.isEmpty && cacheOwner.order.isEmpty,
                    "An old cached image cannot hide an item whose current native container is unresolved")
        snapshot = entries
        cacheOwner.readEntries(force: true)
        confirmedIcon = cacheOwner.item(a).icon
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
        geometryOwner.menuInteraction.captureOverride = { _, done in done(true) }; geometryOwner.permissionOverride = true; geometryOwner.testSkipInput = true; geometryOwner.testSkipEnvironment = true; geometryOwner.testNoPresentation = true
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
                for key in Array(refreshed.keys) {
                    refreshed[key]?.sourceFrame = currentFrame
                    refreshed[key]?.sourceSurface = CGRect(x: 0, y: 0, width: 1512, height: 33)
                    refreshed[key]?.sourceSurfaceID = 42
                }
                done(refreshed)
            }
        }
        geometryOwner.readEntries(force: true)
        try require(Set(geometryOwner.entries.filter(\.visible).map(\.bundle)) == Set([a, b, c])
                    && geometryOwner.entries.filter(\.visible).allSatisfy { $0.frame == currentFrame }
                    && !geometryOwner.input.entries.isEmpty && geometryOwner.input.entries.allSatisfy { $0.frame == currentFrame },
                    "Accepted fresh pixels and native drag hit targets use the same capture-time coordinates")
        try require(geometryOwner.entries.allSatisfy { $0.surfaceID == 42 && $0.surface == CGRect(x: 0, y: 0, width: 1512, height: 33) },
                    "Accepted pixels carry their actual compositor identity through to cached input geometry")
        geometryOwner.stop()
        cacheOwner.stop()
        let pixels = CGContext(data: nil, width: 120, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        pixels.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1)); pixels.fill(CGRect(x: 0, y: 0, width: 120, height: 48))
        let surface = pixels.makeImage()!, area = CGRect(x: 1512, y: -241, width: 60, height: 24)
        let cropped = MenuBarIconCapture.crop(surface, surface: area, item: CGRect(x: 1532, y: -241, width: 20, height: 24))!
        try require(cropped.size == CGSize(width: 20, height: 24) && cropped.image.width == 40 && cropped.image.height == 48,
                    "Native glyph crops use global Quartz coordinates, negative display origins and real Retina scale")
        try require(MenuBarIconCapture.crop(surface, surface: area, item: area.offsetBy(dx: -1, dy: 0)) == nil, "Out-of-surface entries must not capture unrelated pixels")
        try require(MenuBarIconCapture.crop(surface, surface: CGRect(x: 1512, y: -241, width: 120, height: 24), item: CGRect(x: 1532, y: -241, width: 20, height: 24)) == nil,
                    "An anisotropic padded canvas cannot be treated as native point-to-pixel geometry")
        let timedIcons = MenuBarDrawer(defaults: delayedDefaults, visibility: bridge)
        timedIcons.menuInteraction.captureOverride = { _, done in done(true) }; timedIcons.permissionOverride = true; timedIcons.testSkipInput = true; timedIcons.testSkipEnvironment = true; timedIcons.testNoPresentation = true; timedIcons.iconReadTimeout = 0.02
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
                owner.menuInteraction.captureOverride = { _, done in done(true) }; owner.permissionOverride = false; owner.testSkipInput = true; owner.testSkipEnvironment = true; owner.testNoPresentation = true
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
        var accessibleOpens = [String]()
        view.drawer.onOpen = { accessibleOpens.append($0) }
        let accessibleIcon = view.drawer.accessibilityChildren()!.first as! NSAccessibilityElement
        try require(accessibleIcon.isAccessibilityEnabled() && accessibleIcon.accessibilityPerformPress() && accessibleOpens == [a],
                    "Collected icons expose an enabled, working native accessibility action")
        view.update(active: false, state: .expanded, auto: false, issue: nil, count: 3, native: true)
        try require(!accessibleIcon.isAccessibilityEnabled() && !accessibleIcon.accessibilityPerformPress() && accessibleOpens == [a],
                    "Disabled module icons cannot invoke stale accessibility actions")
        view.update(active: true, state: .collapsed, auto: false, issue: nil, count: 3, native: true)
        for width: CGFloat in [840, 460, 360, 220] {
            view.frame = CGRect(x: 0, y: 0, width: width, height: width < 520 ? 580 : 500)
            view.needsLayout = true; view.layoutSubtreeIfNeeded()
            try require(view.subviews.filter { !$0.isHidden }.allSatisfy { view.bounds.contains($0.frame) }, "Every visible control fits wide and narrow settings")
            try require(view.drawer.items.count == 3 && view.visible.items.count == 3, "Compact settings preserve all app identities")
            let expectedAccessibleFrame = window.convertToScreen(view.drawer.convert(view.drawer.cellFrame(0), to: nil))
            try require(accessibleIcon.accessibilityFrame() == expectedAccessibleFrame && expectedAccessibleFrame.width > 0,
                        "Accessible icon frames track actual slots after wide/narrow resizing")
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
        do {
            let area = CGRect(x: 0, y: 0, width: 1512, height: 33)
            let selected = MenuBarContainer(pid: 101, frame: CGRect(x: 1040, y: 0, width: 86, height: 33))
            let clock = MenuBarContainer(pid: 102, frame: CGRect(x: 1380, y: 0, width: 130, height: 33))
            let removed = MenuBarContainer(pid: 103, frame: CGRect(x: 1100, y: 0, width: 160, height: 33))
            try require(!MenuBarNativeInteraction.confirmsHidden(.init(entries: [clock], complete: false), owners: [101])
                        && MenuBarNativeInteraction.confirmsHidden(.init(entries: [clock], complete: true), owners: [101])
                        && !MenuBarNativeInteraction.confirmsHidden(.init(entries: [clock, selected], complete: true), owners: [101]),
                        "A partial AX read cannot be mistaken for proof that collected owners have disappeared")
            try require(MenuBarNativeInteraction.coverRightEdge(before: [clock, removed], after: [selected, clock], owners: [101], area: area) == 1264,
                        "Covered reflow retains the removed-item footprint while leaving the unchanged clock native and live")
            let routing = MenuBarCoveredInput(); var dismissals = 0, appleClicks: [NSEvent] = []
            routing.onDismiss = { _ in dismissals += 1 }; routing.onApple = { appleClicks.append($0) }
            func pointer(_ type: CGEventType, _ point: CGPoint, right: Bool = false) -> CGEvent {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: right ? .right : .left)!
            }
            try require(routing.arm(regions: [CGRect(x: 0, y: 0, width: 500, height: 33)], apple: CGRect(x: 100, y: 0, width: 40, height: 33)), "A single covered bar can own its temporary input boundary")
            let down = pointer(.rightMouseDown, CGPoint(x: 120, y: 12), right: true)
            let up = pointer(.rightMouseUp, CGPoint(x: 120, y: 12), right: true)
            up.flags = .maskAlternate; up.setIntegerValueField(.mouseEventClickState, value: 2)
            try require(routing.consume(.rightMouseDown, event: down) && routing.consume(.rightMouseUp, event: up), "Both halves of a covered apple click are consumed")
            awaitTransition { dismissals == 1 }
            try require(appleClicks.isEmpty && !routing.consume(.flagsChanged, event: down), "The old layout cannot receive the click and modifier changes are never swallowed")
            routing.uncover(); awaitTransition { appleClicks.count == 1 }
            try require(appleClicks[0].type == .rightMouseUp && appleClicks[0].clickCount == 2 && appleClicks[0].modifierFlags.contains(.option), "The existing apple handler receives original type, count and modifiers after restoration")
            try require(!routing.isRouting, "A completed covered click releases temporary input state")
            _ = routing.arm(regions: [CGRect(x: 0, y: 0, width: 500, height: 33)], apple: .zero)
            _ = routing.consume(.leftMouseDown, event: pointer(.leftMouseDown, CGPoint(x: 10, y: 10)))
            routing.cancel(); RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            try require(dismissals == 1, "A cancelled cover cannot deliver its queued dismissal into a later session")

            let bridge = FixtureVisibility(), session = MenuBarLiveSession(visibility: bridge)
            session.cover.captureOverride = { _, done in done(true) }
            var receiver: (([String: MenuBarIconPixels]) -> Void)?, failed: (() -> Void)?
            var stops = 0, frames = 0, exposed = 0, ended = 0, failures = 0
            session.pixelsStartOverride = { _, _, receive, failure in receiver = receive; failed = failure }
            session.pixelsStopOverride = { stops += 1 }; session.onPixels = { _ in frames += 1 }
            session.onExposed = { exposed += 1 }; session.onEnded = { ended += 1 }; session.onFailure = { failures += 1 }
            var restore: ((Bool) -> Void)?
            session.onRestore = { restore = $0 }
            session.start(entries: [entries[0]], displayID: CGMainDisplayID())
            let lease = FixtureHandle(); bridge.pending.removeFirst()(lease)
            awaitTransition { receiver != nil }
            try require(exposed == 1 && session.isActive, "Concealment is handed off only after the rendering lease is active")
            var values: [String: MenuBarIconPixels] = [:]; nativeIconRead([entries[0]], MenuBarReadToken()) { values = $0 }
            receiver?(values); try require(frames == 1, "An open preview accepts current native image frames")
            var restored: Bool?
            session.finish { restored = $0 }
            failed?()
            try require(lease.invalidations == 0 && restored == nil && failures == 0, "Closing retains the render lease until concealment is restored and ignores a late capture error")
            restore?(true)
            try require(lease.invalidations == 1 && restored == true && !session.isActive && ended == 1 && stops > 0, "Restoration drops the lease and releases every rendering resource")
            receiver?(values); try require(frames == 1, "Late preview pixels cannot reach a closed drawer")

            let actionBridge = FixtureVisibility(), action = MenuBarLiveSession(visibility: actionBridge)
            action.cover.captureOverride = { _, done in done(true) }; action.onRestore = { $0(true) }
            var actionFrame: (([String: MenuBarIconPixels]) -> Void)?
            action.pixelsStartOverride = { _, _, receive, _ in actionFrame = receive }; action.pixelsStopOverride = {}
            var nativeSamples: [MenuBarPointerSample] = [], actionResult: Bool?
            action.replayOverride = { _, samples, _, done in nativeSamples = samples; done(true) }
            action.start(entries: [entries[0]], displayID: CGMainDisplayID()); let renderLease = FixtureHandle(); actionBridge.pending.removeFirst()(renderLease)
            awaitTransition { actionFrame != nil }; actionFrame?(values)
            let sequence: [MenuBarPointerSample] = [.init(type: .leftMouseDown, count: 1, timestamp: 0), .init(type: .leftMouseUp, count: 1, timestamp: 0.04), .init(type: .leftMouseDown, count: 2, timestamp: 0.1), .init(type: .leftMouseUp, count: 2, timestamp: 0.14)]
            try require(action.activate(entries[0], samples: sequence) { actionResult = $0 }, "A ready renderer accepts the user's complete double-click sequence")
            awaitTransition { !actionBridge.pending.isEmpty }
            let inputLease = FixtureHandle(); actionBridge.pending.removeFirst()(inputLease)
            awaitTransition { actionResult != nil }
            try require(actionResult == true && nativeSamples.map(\.count) == [1, 1, 2, 2] && renderLease.invalidations == 1 && inputLease.invalidations == 1 && !action.isActive,
                        "A single owner receives the unmodified gesture, then both native leases are released after restoration")

            let pending = MenuBarLiveSession(visibility: bridge); pending.cover.captureOverride = { _, done in done(true) }
            pending.pixelsStartOverride = { _, _, _, _ in throwAway() }
            func throwAway() {}
            pending.start(entries: [entries[0]], displayID: CGMainDisplayID()); pending.restoreTimeout = 0.02
            var cancelled: Bool?
            pending.finish { cancelled = $0 }; awaitTransition { cancelled != nil }
            let lateLease = FixtureHandle(); bridge.pending.removeFirst()(lateLease)
            try require(cancelled == false && !pending.isActive && lateLease.invalidations == 1, "Closing during a hung activation times out safely and invalidates a late lease")

            let surface = CGContext(data: nil, width: 32, height: 16, bitsPerComponent: 8, bytesPerRow: 128, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            surface.setFillColor(CGColor(red: 1, green: 0.9, blue: 0, alpha: 1)); surface.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
            surface.setFillColor(CGColor(gray: 0, alpha: 1)); surface.fill(CGRect(x: 8, y: 4, width: 8, height: 8))
            surface.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.7, alpha: 1)); surface.fill(CGRect(x: 20, y: 4, width: 4, height: 8))
            let input = surface.makeImage()!
            let originalColour = NSBitmapImageRep(cgImage: input).colorAt(x: 21, y: 8)!.usingColorSpace(.deviceRGB)!
            let matte = MenuBarIconCapture.removeBarBackground(MenuBarIconPixels(image: input, size: CGSize(width: 16, height: 8)))
            let bitmap = NSBitmapImageRep(cgImage: matte.image)
            let colour = bitmap.colorAt(x: 21, y: 8)!.usingColorSpace(.deviceRGB)!
            let matteOK = bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0 && bitmap.colorAt(x: 10, y: 8)!.alphaComponent > 0.99 && abs(colour.redComponent - originalColour.redComponent) < 0.02 && abs(colour.blueComponent - originalColour.blueComponent) < 0.02
            if !matteOK { print("MATTE", bitmap.colorAt(x: 0, y: 0)!, bitmap.colorAt(x: 10, y: 8)!, colour); fflush(stdout) }
            try require(matteOK, "Bar removal makes the background transparent and preserves neutral and coloured native ink")

            // A photographed P3 yellow bar must stay in its source gamut until
            // unmatting. Device RGB clips the background and tints neutral ink.
            let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
            let yellow = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 256,
                                   space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            yellow.setFillColor(CGColor(colorSpace: p3, components: [1, 218.0/255, 90.0/255, 1])!)
            yellow.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            yellow.setFillColor(CGColor(colorSpace: p3, components: [166.0/255, 142.0/255, 59.0/255, 1])!)
            yellow.fill(CGRect(x: 20, y: 10, width: 12, height: 12))
            let p3Crop = MenuBarIconCapture.crop(yellow.makeImage()!, surface: CGRect(x: 0, y: 0, width: 32, height: 16),
                                               item: CGRect(x: 8, y: 0, width: 12, height: 16))!
            let neutral = NSBitmapImageRep(cgImage: MenuBarIconCapture.removeBarBackground(p3Crop).image).colorAt(x: 8, y: 14)!.usingColorSpace(.deviceRGB)!
            try require(neutral.redComponent < 0.02 && neutral.greenComponent < 0.02 && neutral.blueComponent < 0.02 && (0.3...0.4).contains(neutral.alphaComponent),
                        "Cropping a wide-gamut yellow bar preserves neutral translucent ink instead of gold silhouettes")
            yellow.setFillColor(CGColor(colorSpace: p3, components: [191.0/255, 154.0/255, 26.0/255, 1])!)
            yellow.fill(CGRect(x: 20, y: 10, width: 12, height: 12))
            let vibrantCrop = MenuBarIconCapture.crop(yellow.makeImage()!, surface: CGRect(x: 0, y: 0, width: 32, height: 16),
                                                    item: CGRect(x: 8, y: 0, width: 12, height: 16))!
            let vibrant = NSBitmapImageRep(cgImage: MenuBarIconCapture.removeBarBackground(vibrantCrop).image).colorAt(x: 8, y: 14)!.usingColorSpace(.deviceRGB)!
            try require(vibrant.redComponent < 0.02 && vibrant.greenComponent < 0.02 && vibrant.blueComponent < 0.02 && (0.23...0.27).contains(vibrant.alphaComponent),
                        "Inactive remote template ink is unmatted using its subtractive vibrancy, without retaining coloured wallpaper")
            let shaded = CGContext(data: nil, width: 40, height: 32, bitsPerComponent: 8, bytesPerRow: 160,
                                   space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            let shadedBytes = shaded.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<32 { for x in 0..<40 {
                let shadow = max(0, Double(y) - 14) * Double(x) / 50
                let ink = (12..<24).contains(x) && (8..<24).contains(y)
                for (c, base) in [255.0, 218, 90].enumerated() {
                    let value = base * (1 - shadow / 255) - (ink ? 64 : 0)
                    shadedBytes[(y * 40 + x) * 4 + c] = UInt8(value.rounded())
                }
                shadedBytes[(y * 40 + x) * 4 + 3] = 255
            } }
            // A genuine coloured glyph touching the side is not empty padding.
            for y in 8..<24 { for (c, value) in [150, 50, 180, 255].enumerated() { shadedBytes[y * 160 + c] = UInt8(value) } }
            let shadedResult = NSBitmapImageRep(cgImage: MenuBarIconCapture.removeBarBackground(.init(image: shaded.makeImage()!, size: CGSize(width: 40, height: 32))).image)
            let shadowInk = shadedResult.colorAt(x: 18, y: 18)!.usingColorSpace(.deviceRGB)!
            try require(shadedResult.colorAt(x: 35, y: 28)!.alphaComponent == 0
                        && shadedResult.colorAt(x: 28, y: 16)!.alphaComponent == 0
                        && shadowInk.redComponent < 0.02 && shadowInk.blueComponent < 0.02 && (0.22...0.28).contains(shadowInk.alphaComponent)
                        && shadedResult.colorAt(x: 0, y: 16)!.alphaComponent > 0.99,
                        "A spatially varying bar shadow is removed without colour blocks, while native edge ink remains intact")
        }
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
