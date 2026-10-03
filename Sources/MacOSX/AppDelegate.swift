import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let updates = UpdateController()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updates.start()
        showBlankWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showBlankWindow()
        return true
    }

    private func showBlankWindow() {
        if window == nil {
            let blank = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            blank.title = "macos-x"
            blank.backgroundColor = .white
            blank.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
            blank.isReleasedWhenClosed = false
            blank.minSize = NSSize(width: 320, height: 240)
            blank.center()
            window = blank
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let menuBar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "macos-x")
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 macos-x", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        menuBar.addItem(appItem)
        NSApp.mainMenu = menuBar
    }

    @objc private func checkUpdates() { updates.checkForUpdates(self) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkUpdates) ? updates.canCheckForUpdates : true
    }
}
