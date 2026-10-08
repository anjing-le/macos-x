import AppKit
import os

/// One permanent entry point, with no timer or background polling.
@MainActor final class MenuBarController: NSObject, NSMenuItemValidation {
    private var item: NSStatusItem?
    private var lastLeftClick: TimeInterval?
    private let logger = Logger(subsystem: "cc.anjing.macos-x", category: "menu-bar")
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
        let item = NSStatusBar.system.statusItem(withLength: 30)
        self.item = item
        guard let button = item.button else { return }
        button.imageScaling = .scaleProportionallyDown
        button.image = Self.icon()
        button.toolTip = "macos-x · 双击打开，右键菜单"
        button.setAccessibilityLabel("macos-x，双击打开主界面，右键打开菜单")
        button.target = self; button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    static func icon() -> NSImage? {
        let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macos-x")
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        image?.size = NSSize(width: 20, height: 22); image?.isTemplate = true
        return image
    }
    func stop() {
        lastLeftClick = nil
        guard let item else { return }
        NSStatusBar.system.removeStatusItem(item); self.item = nil
    }
    @objc private func clicked() {
        guard let event = NSApp.currentEvent else { onOpen(); return }
        handleClick(event)
    }
    func handleClick(_ event: NSEvent, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        logger.info("button event=\(event.type.rawValue)")
        if event.type == .rightMouseUp || event.type == .rightMouseDown {
            lastLeftClick = nil
            guard let button = item?.button else { return }
            menu.popUp(positioning: nil, at: CGPoint(x: 0, y: button.bounds.minY), in: button)
        } else if event.type == .leftMouseUp || event.type == .leftMouseDown {
            // Status-item actions may not carry the usual window double-click
            // count. Recognize consecutive actions using the user's OS interval.
            if let previous = lastLeftClick, now >= previous, now - previous <= NSEvent.doubleClickInterval {
                lastLeftClick = nil; logger.info("double click opens client"); onOpen()
            } else { lastLeftClick = now }
        } else if event.type == .keyDown { lastLeftClick = nil; onOpen() }
    }
    @objc private func openClient() { onOpen() }
    @objc private func checkUpdates() { onCheckUpdates() }
    @objc private func quit() { onQuit() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(checkUpdates) ? canCheckUpdates() : true
    }
}
