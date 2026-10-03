import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let switcher = WindowSwitcherModule()
    private let updates = UpdateController()
    private var statusItem: NSStatusItem?
    private var moduleItem: NSMenuItem?
    private var statusLine: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var showItem: NSMenuItem?
    private let enabledKey = "module.window-switcher.enabled"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [enabledKey: true])
        buildMenu()
        switcher.onStatusChange = { [weak self] message in self?.statusLine?.title = message }
        if UserDefaults.standard.bool(forKey: enabledKey) { switcher.start() }
        updates.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        switcher.stop()
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "macos-x")
        let menu = NSMenu()
        menu.delegate = self
        let heading = NSMenuItem(title: "macos-x · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")", action: nil, keyEquivalent: "")
        menu.addItem(heading)
        let state = NSMenuItem(title: "窗口切换正在启动…", action: nil, keyEquivalent: "")
        menu.addItem(state)
        menu.addItem(.separator())
        let show = action("显示窗口切换器", #selector(showSwitcher))
        menu.addItem(show)
        let toggle = action("启用窗口切换 · ⌥Tab", #selector(toggleSwitcher))
        toggle.state = UserDefaults.standard.bool(forKey: enabledKey) ? .on : .off
        menu.addItem(toggle)
        menu.addItem(action("授权辅助功能…", #selector(requestAccessibility)))
        menu.addItem(action("授权屏幕录制…", #selector(requestScreenCapture)))
        menu.addItem(.separator())
        let check = action("检查更新…", #selector(checkUpdates))
        menu.addItem(check)
        menu.addItem(action("关于 macos-x…", #selector(showAbout)))
        menu.addItem(.separator())
        let quit = action("退出 macos-x", #selector(quitApp))
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        statusLine = state
        moduleItem = toggle
        updateItem = check
        showItem = show
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func showSwitcher() {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        switcher.showFromMenu()
    }

    @objc private func toggleSwitcher() {
        let enabled = !UserDefaults.standard.bool(forKey: enabledKey)
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        moduleItem?.state = enabled ? .on : .off
        if enabled { switcher.start() } else { switcher.stop() }
    }

    @objc private func requestAccessibility() {
        switcher.requestAccessibilityPermission()
    }

    @objc private func requestScreenCapture() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @objc private func checkUpdates() { updates.checkForUpdates(self) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "macos-x",
            .credits: NSAttributedString(string: "原生 macOS 工具箱 · anjing-le\n窗口切换模块：⌥Tab，Shift 反向，松开 ⌥ 切换，Esc 取消。\n初版支持当前桌面的普通窗口。"),
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        ])
    }

    @objc private func quitApp() { NSApp.terminate(self) }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        updateItem?.isEnabled = updates.canCheckForUpdates
        showItem?.isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    }
}
