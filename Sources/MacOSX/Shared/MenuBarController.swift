import AppKit

/// One permanent entry point, with no timer or background polling.
@MainActor final class MenuBarController: NSObject, NSMenuItemValidation {
    private var item: NSStatusItem?
    private let onOpen: () -> Void
    private let onCheckUpdates: () -> Void
    private let canCheckUpdates: () -> Bool
    private let onQuit: () -> Void
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        for (title, action) in [("打开 macos-x", #selector(openClient)), ("检查更新…", #selector(checkUpdates))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 macos-x", action: #selector(quit), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
        return menu
    }()

    init(onOpen: @escaping () -> Void, onCheckUpdates: @escaping () -> Void,
         canCheckUpdates: @escaping () -> Bool, onQuit: @escaping () -> Void) {
        self.onOpen = onOpen; self.onCheckUpdates = onCheckUpdates
        self.canCheckUpdates = canCheckUpdates; self.onQuit = onQuit
        super.init()
    }
    func start() {
        guard item == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.item = item
        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macos-x")
        image?.isTemplate = true; button.image = image
        button.toolTip = "macos-x · 双击打开，右键菜单"
        button.setAccessibilityLabel("macos-x，双击打开主界面，右键打开菜单")
        button.target = self; button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    func stop() {
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item); self.item = nil
    }
    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { onOpen(); return }
        handleClick(event)
    }
    func handleClick(_ event: NSEvent) {
        if event.type == .rightMouseUp {
            guard let button = item?.button else { return }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.minY), in: button)
        } else if event.type == .leftMouseUp, event.clickCount >= 2 {
            onOpen()
        } else if event.type == .keyDown { onOpen() }
    }
    @objc private func openClient() { onOpen() }
    @objc private func checkUpdates() { onCheckUpdates() }
    @objc private func quit() { onQuit() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkUpdates) ? canCheckUpdates() : true
    }
}
