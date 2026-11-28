import MacOSXCore
import AppKit
import os

/// One permanent entry point, with no timer or background polling.
@MainActor final class MenuBarController: NSObject, NSMenuItemValidation, NSMenuDelegate {
    private var item: NSStatusItem?
    var onHover: ((CGRect, Bool) -> Void)?
    var onSingleClick: (() -> Void)?
    var onAbout: (() -> Void)?
    var onCancelFileActions: (() -> Void)?
    var onRevealFileActions: (() -> Void)?
    private var fileFeedback: FileActionFeedback?
    private var unreadFileFeedback = false, menuIsOpen = false
    private var retainCancelRow = false
    private var hoverView: MenuBarHoverView?
    private let fileHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fileDetail = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fileCancel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let fileReveal = NSMenuItem(title: "Finder", action: nil, keyEquivalent: "")
    private let fileSeparator = NSMenuItem.separator()
    var screenFrame: CGRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    private var lastLeftClick: TimeInterval?
    private let logger = Logger(subsystem: "cc.anjing.macos-x", category: "menu-bar")
    private let onOpen: () -> Void
    private let onCheckUpdates: () -> Void
    private let canCheckUpdates: () -> Bool
    private let onQuit: () -> Void
    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        for entry in [fileHeader, fileDetail, fileCancel, fileReveal, fileSeparator] { menu.addItem(entry) }
        fileCancel.title = AppLanguage.text("取消"); fileCancel.action = #selector(cancelFileTask); fileCancel.target = self
        fileReveal.action = #selector(revealFileResult); fileReveal.target = self
        refreshFileFeedback()
        for (title, action) in [(AppLanguage.text("打开 macos-x"), #selector(openClient)), (AppLanguage.text("检查更新…"), #selector(checkUpdates)), (AppLanguage.text("关于 macos-x"), #selector(showAbout))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: AppLanguage.text("退出 macos-x"), action: #selector(quit), keyEquivalent: "")
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
        button.toolTip = AppLanguage.text("macos-x · 双击打开，右键菜单")
        button.setAccessibilityLabel(AppLanguage.text("macos-x，双击打开主界面，右键打开菜单"))
        button.target = self; button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let hover = MenuBarHoverView(frame: button.bounds)
        hover.autoresizingMask = [.width, .height]
        hover.onHover = { [weak self] inside in
            guard let self, let frame = self.screenFrame else { return }
            self.onHover?(frame, inside)
        }
        button.addSubview(hover)
        hoverView = hover; refreshFileFeedback()
    }
    func updateFileActions(_ feedback: FileActionFeedback?) {
        guard fileFeedback != feedback else { return }
        if feedback == nil { retainCancelRow = false }
        else if menuIsOpen, fileFeedback?.phase.isBusy == true, feedback?.phase.isBusy != true { retainCancelRow = true }
        fileFeedback = feedback
        unreadFileFeedback = !menuIsOpen && (feedback?.phase == .completed || feedback?.phase == .failed)
        refreshFileFeedback()
    }
    private func refreshFileFeedback() {
        fileHeader.isEnabled = false; fileDetail.isEnabled = false
        fileHeader.isHidden = fileFeedback == nil; fileDetail.isHidden = fileFeedback == nil
        fileSeparator.isHidden = fileFeedback == nil
        fileHeader.title = fileFeedback?.title ?? ""
        fileDetail.title = fileFeedback?.detail ?? ""
        fileDetail.toolTip = fileFeedback.map { ($0.output ?? $0.input).lastPathComponent + "\n" + $0.message }
        fileCancel.isHidden = fileFeedback == nil || (fileFeedback?.phase.isBusy != true && !retainCancelRow)
        fileCancel.isEnabled = fileFeedback?.phase.isBusy == true
        let reserveResultRow = menuIsOpen && (fileFeedback?.phase.isBusy == true || retainCancelRow)
        fileReveal.isHidden = fileFeedback == nil || (fileFeedback?.output == nil && !reserveResultRow)
        fileReveal.isEnabled = fileFeedback?.output != nil && fileFeedback?.phase.isBusy == false
        let tooltip = fileFeedback.map {
            $0.title + "\n" + $0.detail + "\n" + AppLanguage.text("右键查看文件操作")
        } ?? AppLanguage.text("macos-x · 双击打开，右键菜单")
        item?.button?.toolTip = tooltip
        item?.button?.setAccessibilityValue(fileFeedback?.title)
        hoverView?.feedbackPhase = fileFeedback.flatMap { $0.phase.isBusy || unreadFileFeedback ? $0.phase : nil }
        fileHeader.menu?.update()
    }
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true; unreadFileFeedback = false; retainCancelRow = false; refreshFileFeedback()
    }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false; retainCancelRow = false; refreshFileFeedback() }
    static func icon() -> NSImage? {
        let symbol = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macos-x")
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        image?.size = NSSize(width: 20, height: 22); image?.isTemplate = true
        return image
    }
    func stop() {
        lastLeftClick = nil
        fileFeedback = nil; unreadFileFeedback = false; menuIsOpen = false; retainCancelRow = false
        refreshFileFeedback(); hoverView = nil
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
            } else { lastLeftClick = now; onSingleClick?() }
        } else if event.type == .keyDown { lastLeftClick = nil; onOpen() }
    }
    @objc private func showAbout() { onAbout?() }
    @objc private func openClient() { onOpen() }
    @objc private func checkUpdates() { onCheckUpdates() }
    @objc private func quit() { onQuit() }
    @objc private func cancelFileTask() { onCancelFileActions?() }
    @objc private func revealFileResult() { onRevealFileActions?() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkUpdates) { return canCheckUpdates() }
        if menuItem.action == #selector(cancelFileTask) { return fileFeedback?.phase.isBusy == true }
        if menuItem.action == #selector(revealFileResult) { return fileFeedback?.output != nil && fileFeedback?.phase.isBusy == false }
        return true
    }
}

/// Tracking-only overlay: never intercepts the status button's native clicks
/// or Command-drag. No global mouse move monitor is needed for apple hover.
@MainActor private final class MenuBarHoverView: NSView {
    var feedbackPhase: FileActionFeedback.Phase? { didSet { if oldValue != feedbackPhase { needsDisplay = true } } }
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func draw(_ dirtyRect: NSRect) {
        guard let phase = feedbackPhase else { return }
        let color: NSColor
        switch phase {
        case .preparing, .processing, .saving: color = .secondaryLabelColor
        case .completed: color = .systemGreen
        case .failed: color = .systemOrange
        case .cancelled: return
        }
        let path = NSBezierPath(ovalIn: CGRect(x: bounds.maxX-7, y: bounds.minY+2, width: 5, height: 5))
        NSColor.windowBackgroundColor.withAlphaComponent(0.8).setStroke(); path.lineWidth = 1.5; path.stroke()
        color.setFill(); path.fill()
    }
}
