import AppKit
import ApplicationServices
import MacOSXCore
import os

@MainActor
final class WindowSwitcherModule {
    var onStatusChange: ((String) -> Void)?
    private let inventory = WindowInventory()
    private let thumbnails = WindowThumbnails()
    private let panel = SwitcherPanel()
    private var running = false
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var refreshWork: DispatchWorkItem?
    private var snapshot = WindowInventorySnapshot(windows: [], focusedID: nil, mappingAvailable: true)
    private var selection = SwitcherSelection()
    private var hotSession: UInt64?
    private var hotCommitsOnRelease = false
    private var sessionCounter: UInt64 = 0
    private var displayedSession: UInt64?
    private var lifecycle: UInt64 = 0
    private var capturePage: [CGWindowID] = []
    private var status = "窗口切换未启用"
    private var lastFocusRequest: UInt64 = 0
    private var focusNotice: String?
    private var thumbnailPermissionMissing = false
    private let metrics = OSLog(subsystem: "cc.anjing.macos-x", category: "WindowSwitcher")

    init() {
        inventory.onInvalidation = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        panel.onChoose = { [weak self] id in
            guard let self else { return }
            self.selection.select(windowID: id)
            self.commitSelection()
        }
        thumbnails.onUpdate = { [weak self] in
            guard let self, self.running, self.panel.isVisible else { return }
            self.panel.updateSelection(self.selection.selectedWindowID, thumbnails: self.thumbnails.images)
        }
        thumbnails.onPermissionMissing = { [weak self] in
            self?.thumbnailPermissionMissing = true
            self?.setStatus("窗口切换可用；缩略图需要屏幕录制权限，当前显示应用图标")
        }
    }

    /// May be called again after permission is granted. A failed permission check
    /// leaves the module stopped, so toggling it after Settings retries normally.
    func start() {
        guard AXIsProcessTrusted() else {
            if running { stop() }
            setStatus("窗口切换需要辅助功能权限；授权后停用再启用")
            return
        }
        if !running {
            running = true
            lifecycle &+= 1
            inventory.start()
            installWorkspaceObservers()
        }
        if eventTap == nil { installEventTap() }
        scheduleRefresh(immediate: true)
        if eventTap != nil { setStatus("窗口切换正在准备窗口缓存…") }
    }

    func stop() {
        running = false
        lifecycle &+= 1
        lastFocusRequest &+= 1
        refreshWork?.cancel(); refreshWork = nil
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        eventSource = nil; eventTap = nil
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
        inventory.stop()
        thumbnails.cancel()
        panel.clear()
        snapshot = WindowInventorySnapshot(windows: [], focusedID: nil, mappingAvailable: true)
        selection = SwitcherSelection()
        capturePage.removeAll(); hotSession = nil; hotCommitsOnRelease = false; displayedSession = nil
        focusNotice = nil; thumbnailPermissionMissing = false
        setStatus("窗口切换已停用")
    }

    func showFromMenu() {
        guard running else { return }
        sessionCounter &+= 1
        hotSession = sessionCounter; hotCommitsOnRelease = false
        show(offset: 0, session: sessionCounter)
    }

    func requestAccessibilityPermission() {
        // This is only called by an explicit menu action, never by start or a hotkey.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setStatus(_ value: String) {
        guard status != value else { return }
        status = value; onStatusChange?(value)
    }

    private func installEventTap() {
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let module = Unmanaged<WindowSwitcherModule>.fromOpaque(context).takeUnretainedValue()
                // This source is explicitly attached to the main run loop.
                return MainActor.assumeIsolated { module.handleEvent(type, event) }
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setStatus("全局快捷键监听不可用；请检查辅助功能权限，菜单仍可打开窗口列表")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap; eventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The hot path only reads cached availability and enqueues ordered actions.
    /// It never calls AX, scans, captures, draws, or shows a panel synchronously.
    /// Unavailable shortcuts pass on without changing the system's key behavior.
    private func handleEvent(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let measurement = OSSignpostID(log: metrics)
        os_signpost(.begin, log: metrics, name: "EventTapCallback", signpostID: measurement)
        defer { os_signpost(.end, log: metrics, name: "EventTapCallback", signpostID: measurement) }
        let passthrough = Unmanaged.passUnretained(event)
        guard running else { return passthrough }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hotSession = nil; hotCommitsOnRelease = false
            enqueue { module in
                module.cancelSelection()
                if let eventTap = module.eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
                module.setStatus("快捷键监听曾被系统暂停；已尝试恢复")
            }
            return passthrough
        }
        if type == .flagsChanged {
            if let session = hotSession, hotCommitsOnRelease, !event.flags.contains(.maskAlternate) {
                hotSession = nil; hotCommitsOnRelease = false
                enqueue { module in
                    guard module.displayedSession == session else { return }
                    module.commitSelection(session: session)
                }
            }
            return passthrough // allow modifier releases to reach the previous app
        }
        guard type == .keyDown else { return passthrough }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let optionTab = key == 48 && event.flags.contains(.maskAlternate)
            && !event.flags.contains(.maskCommand) && !event.flags.contains(.maskControl)
        if optionTab {
            guard !snapshot.windows.isEmpty else {
                enqueue { module in
                    module.scheduleRefresh()
                    module.setStatus("窗口缓存尚未就绪或没有可切换窗口；快捷键已放行")
                }
                return passthrough
            }
            let step = event.flags.contains(.maskShift) ? -1 : 1
            if let session = hotSession {
                hotCommitsOnRelease = true
                enqueue { module in
                    guard module.displayedSession == session else { return }
                    module.selection.move(by: step); module.renderCachedPanel()
                }
            } else {
                sessionCounter &+= 1
                let session = sessionCounter
                hotSession = session; hotCommitsOnRelease = true
                enqueue { $0.show(offset: step, session: session) }
            }
            return nil
        }
        guard let session = hotSession else { return passthrough }
        switch key {
        case 53:
            hotSession = nil; hotCommitsOnRelease = false
            enqueue { if $0.displayedSession == session { $0.cancelSelection(session: session) } }
            return nil
        case 36, 76:
            hotSession = nil; hotCommitsOnRelease = false
            enqueue { if $0.displayedSession == session { $0.commitSelection(session: session) } }
            return nil
        case 123, 126, 124, 125:
            let offset = (key == 123 || key == 126) ? -1 : 1
            enqueue { module in
                guard module.displayedSession == session else { return }
                module.selection.move(by: offset); module.renderCachedPanel()
            }
            return nil
        default: return passthrough
        }
    }

    private func enqueue(_ action: @escaping @MainActor (WindowSwitcherModule) -> Void) {
        let expected = lifecycle
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.lifecycle == expected else { return }
            action(self)
        }
    }

    private func show(offset: Int, session: UInt64) {
        guard !snapshot.windows.isEmpty else {
            if hotSession == session { hotSession = nil; hotCommitsOnRelease = false }
            scheduleRefresh(immediate: true)
            setStatus("当前桌面没有已缓存的普通窗口；后台正在刷新")
            return
        }
        selection = SwitcherSelection(windowIDs: snapshot.windows.map(\.id))
        if let focusedID = snapshot.focusedID { selection.select(windowID: focusedID) }
        selection.move(by: offset)
        displayedSession = session
        capturePage.removeAll()
        renderCachedPanel()
        scheduleRefresh()
    }

    private func renderCachedPanel() {
        let measurement = OSSignpostID(log: metrics)
        os_signpost(.begin, log: metrics, name: "PanelPresentation", signpostID: measurement)
        defer { os_signpost(.end, log: metrics, name: "PanelPresentation", signpostID: measurement) }
        panel.show(windows: snapshot.windows, selectedID: selection.selectedWindowID, thumbnails: thumbnails.images)
        let ids = panel.displayedWindows.map(\.id)
        if capturePage != ids {
            capturePage = ids
            thumbnails.load(panel.displayedWindows)
        }
    }

    private func cancelSelection(session: UInt64? = nil) {
        if session == nil || hotSession == session { hotSession = nil; hotCommitsOnRelease = false }
        panel.hide(); thumbnails.cancel(); capturePage.removeAll(); displayedSession = nil
    }

    private func commitSelection(session: UInt64? = nil) {
        let chosen = snapshot.windows.first { $0.id == selection.selectedWindowID }
        cancelSelection(session: session)
        guard let chosen else { return }
        lastFocusRequest &+= 1
        let request = lastFocusRequest
        inventory.focus(chosen) { [weak self] landed in
            MainActor.assumeIsolated {
                guard let self, self.running, self.lastFocusRequest == request else { return }
                self.focusNotice = landed ? nil : "公开接口未确认“\(chosen.title)”聚焦成功"
                if let notice = self.focusNotice { self.setStatus(notice) }
                self.scheduleRefresh(immediate: true)
            }
        }
    }

    private func scheduleRefresh(immediate: Bool = false) {
        guard running else { return }
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.inventory.refresh(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] snapshot in
                    MainActor.assumeIsolated { self?.accept(snapshot) }
                }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.08), execute: work)
    }

    private func accept(_ updated: WindowInventorySnapshot) {
        guard running else { return }
        snapshot = updated
        selection.replaceWindows(updated.windows.map(\.id))
        if panel.isVisible {
            if updated.windows.isEmpty { cancelSelection() } else { renderCachedPanel() }
        }
        if !updated.mappingAvailable {
            setStatus("窗口映射接口不可用；未猜测对应窗口，快捷键放行")
        } else if eventTap == nil {
            setStatus("已缓存 \(updated.windows.count) 个窗口；全局监听不可用，可从菜单打开")
        } else {
            var value = "窗口切换已启用 · 当前桌面 \(updated.windows.count) 个普通窗口 · Option + Tab"
            if thumbnailPermissionMissing { value += " · 缩略图未授权，使用图标" }
            if let focusNotice { value += " · \(focusNotice)" }
            setStatus(value)
        }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification]
        for name in names {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if notification.name == NSWorkspace.didActivateApplicationNotification,
                       let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        self.inventory.applicationActivated(application.processIdentifier)
                    }
                    if notification.name == NSWorkspace.activeSpaceDidChangeNotification {
                        self.lifecycle &+= 1
                        self.cancelSelection()
                        self.snapshot = WindowInventorySnapshot(windows: [], focusedID: nil, mappingAvailable: true)
                        self.selection = SwitcherSelection()
                        self.inventory.invalidateScans()
                        self.scheduleRefresh(immediate: true)
                    } else {
                        self.scheduleRefresh()
                    }
                }
            })
        }
    }
}
