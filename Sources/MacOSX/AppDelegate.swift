import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let updates = UpdateController()
    private var client: ToolboxWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updates.start()
        showClient()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showClient()
        return true
    }

    private func showClient() {
        if client == nil {
            client = ToolboxWindowController(
                onCheckUpdates: { [weak self] in self?.checkUpdates() },
                canCheckUpdates: { [weak self] in self?.updates.canCheckForUpdates ?? false }
            )
        }
        client?.present()
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
