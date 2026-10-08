import AppKit

@main struct MenuBarRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        var opened = 0, checked = 0, quit = 0, available = false
        let controller = MenuBarController(onOpen: { opened += 1 }, onCheckUpdates: { checked += 1 },
                                          canCheckUpdates: { available }, onQuit: { quit += 1 })
        func click(_ count: Int, type: NSEvent.EventType = .leftMouseUp) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
        }
        controller.handleClick(click(1), now: 10)
        precondition(opened == 0, "Single click must not raise the main window")
        controller.handleClick(click(1), now: 10 + NSEvent.doubleClickInterval / 2)
        precondition(opened == 1 && checked == 0 && quit == 0, "Two status actions with count one must open exactly once without other actions")
        controller.handleClick(click(1), now: 20)
        controller.handleClick(click(1), now: 20 + NSEvent.doubleClickInterval + 1)
        precondition(opened == 1, "Slow separate clicks must not open the window")
        controller.stop()
        controller.handleClick(click(1, type: .leftMouseDown), now: 30)
        controller.handleClick(click(1, type: .leftMouseDown), now: 30 + NSEvent.doubleClickInterval / 2)
        precondition(opened == 2, "Tracked button actions with mouse-down current event also recognize double click")
        controller.handleClick(click(1), now: 40)
        controller.handleClick(click(1, type: .rightMouseUp), now: 40.01)
        controller.handleClick(click(1), now: 40.02)
        precondition(opened == 2, "Right click resets pending left-click sequence")
        controller.stop()
        controller.handleClick(click(2), now: 50)
        precondition(opened == 2, "Restart cannot reuse a stale first click")
        let keyboard = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        controller.handleClick(keyboard, now: 60)
        precondition(opened == 3, "Keyboard activation opens the UI without requiring mouse double click")
        precondition(MenuBarController.icon()?.size == NSSize(width: 20, height: 22)
            && MenuBarController.icon()?.isTemplate == true, "Icon uses explicit larger size and adaptive template color")
        let update = NSMenuItem(title: "检查更新", action: NSSelectorFromString("checkUpdates"), keyEquivalent: "")
        precondition(!controller.validateMenuItem(update), "Unavailable update check stays disabled")
        available = true
        precondition(controller.validateMenuItem(update), "Ready updater enables manual check")
        precondition(NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) != nil,
                     "Menu bar apple symbol must exist on supported macOS")
        controller.stop(); controller.stop()
        print("PASS menu bar: single-count double actions, slow clicks, tracked mouse-down actions, right-click reset, update availability, native icon and idempotent shutdown; no status item, window or permissions created")
    }
}
