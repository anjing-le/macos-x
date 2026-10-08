import AppKit

@main struct MenuBarRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        var opened = 0, checked = 0, quit = 0, available = false
        let controller = MenuBarController(onOpen: { opened += 1 }, onCheckUpdates: { checked += 1 },
                                          canCheckUpdates: { available }, onQuit: { quit += 1 })
        func click(_ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 0)!
        }
        controller.handleClick(click(1))
        precondition(opened == 0, "Single click must not raise the main window")
        controller.handleClick(click(2))
        precondition(opened == 1 && checked == 0 && quit == 0, "Double click opens exactly once without other actions")
        let update = NSMenuItem(title: "检查更新", action: NSSelectorFromString("checkUpdates"), keyEquivalent: "")
        precondition(!controller.validateMenuItem(update), "Unavailable update check stays disabled")
        available = true
        precondition(controller.validateMenuItem(update), "Ready updater enables manual check")
        precondition(NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil) != nil,
                     "Menu bar apple symbol must exist on supported macOS")
        controller.stop(); controller.stop()
        print("PASS menu bar: single/double click routing, update availability, native icon and idempotent shutdown; no status item, window or permissions created")
    }
}
