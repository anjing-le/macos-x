import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let updates = UpdateController()
    private let modules = ModuleCoordinator()
    private var client: ToolboxWindowController?
    private lazy var menuBar = MenuBarController(
        onOpen: { [weak self] in self?.showClient() },
        onCheckUpdates: { [weak self] in self?.checkUpdates() },
        canCheckUpdates: { [weak self] in self?.updates.canCheckForUpdates ?? false },
        onQuit: { NSApp.terminate(nil) }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        menuBar.start()
        updates.onAvailabilityChanged = { [weak self] available in self?.client?.setUpdateAvailable(available) }
        updates.start()
        prepareClient()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showClient()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { menuBar.stop(); modules.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        modules.prepareToTerminate { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    private func prepareClient() {
        if client == nil {
            client = ToolboxWindowController(
                modules: modules,
                onCheckUpdates: { [weak self] in self?.checkUpdates() },
                canCheckUpdates: { [weak self] in self?.updates.canCheckForUpdates ?? false }
            )
        }
    }

    private func showClient() {
        prepareClient()
        client?.setUpdateAvailable(updates.hasAvailableUpdate)
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
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
            ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(selector), keyEquivalent: key))
        }
        let redo = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]; edit.insertItem(redo, at: 1)
        editItem.submenu = edit; menuBar.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        // Nil targets use AppKit's responder chain: operate on the active
        // window and respect panels that deliberately disallow closing.
        windowMenu.addItem(NSMenuItem(title: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu; menuBar.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menuBar
    }

    @objc private func checkUpdates() { updates.checkForUpdates(self) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkUpdates) ? updates.canCheckForUpdates : true
    }
}
