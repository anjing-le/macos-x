import AppKit
import ApplicationServices
import MacOSXCore

/// Shared input is owned by the app. This module never installs another event tap.
@MainActor final class WindowSwitcherModule {
    var onPreviewSettingsChanged: (() -> Void)?
    private let defaults: UserDefaults
    var thumbnailsEnabled: Bool { defaults.object(forKey: "switcher.thumbnails") as? Bool ?? true }
    private(set) var hasConfirmedThumbnailAccess = false
    private(set) var thumbnailPermissionDenied = false
    var onReadinessChanged: ((Bool) -> Void)?
    private(set) var isReady = false
    var isSwitching: Bool { session != nil }
    private let inventory = WindowInventory()
    private let thumbnails = WindowThumbnailService()
    private var thumbnailTicket: WindowThumbnailService.Ticket?
    private var thumbnailPage: [WindowThumbnailID] = []
    private var thumbnailImages: [CGWindowID: CGImage] = [:]
    private var panel: SwitcherPanel?
    private var snapshot = WindowInventorySnapshot.empty
    private var session: SwitcherSelection?
    private enum SessionKind { case command, preview }
    private var sessionKind: SessionKind?
    private var sessionWindows = [SwitcherWindow]()
    private var running = false
    private var generation: UInt64 = 0
    private var sessionToken: UInt64 = 0
    private var refreshWork: DispatchWorkItem?
    private var presentationWork: DispatchWorkItem?
    private var queuedRenderToken: UInt64?
    private var workspaceObservers = [NSObjectProtocol]()
    private var settings: NSView?
    private weak var statusLabel: NSTextField?
    private weak var previewButton: NSButton?
    private var status = "启用后即可使用 Command + Tab 切换窗口"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        inventory.onInvalidation = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        inventory.onConfirmedFocus = { [weak self] id in
            MainActor.assumeIsolated { self?.acceptConfirmedFocus(id) }
        }
    }

    deinit {
        refreshWork?.cancel(); presentationWork?.cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        inventory.stop()
    }

    var settingsView: NSView {
        if let settings { return settings }
        let label = NSTextField(wrappingLabelWithString: status)
        label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor
        let preview = MinimalButton(title: "预览窗口切换", target: self, action: #selector(previewPressed), style: .standard)
        preview.isEnabled = isReady
        let thumbnailToggle = MinimalToggle(title: "", target: self, action: #selector(changeThumbnails(_:)))
        thumbnailToggle.state = thumbnailsEnabled ? .on : .off
        thumbnailToggle.setAccessibilityLabel("窗口缩略图")
        let thumbnailLabel = NSTextField(labelWithString: "窗口缩略图")
        thumbnailLabel.font = .systemFont(ofSize: 12); thumbnailLabel.textColor = .secondaryLabelColor
        let row = NSStackView(views: [thumbnailLabel, thumbnailToggle]); row.spacing = 14
        let stack = NSStackView(views: [row, preview, label])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        settings = stack; statusLabel = label; previewButton = preview
        return stack
    }

    func start() {
        guard AXIsProcessTrusted() else {
            if running { stop() }
            setStatus("需要辅助功能权限；当前使用 macOS 原生切换")
            setReadiness(false); return
        }
        guard PrivateWindowBridge.isAvailable else {
            setStatus("系统窗口映射不可用；当前使用 macOS 原生切换")
            setReadiness(false); return
        }
        if !running {
            running = true; generation &+= 1
            inventory.start(); observeWorkspace()
        }
        setStatus("正在准备窗口列表…")
        scheduleRefresh(immediate: true)
    }

    func stop() {
        running = false; generation &+= 1
        refreshWork?.cancel(); refreshWork = nil
        cancel()
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { center.removeObserver(observer) }
        workspaceObservers.removeAll()
        thumbnails.clear()
        inventory.stop(); snapshot = .empty
        panel?.clear(); panel = nil
        queuedRenderToken = nil; setReadiness(false)
        setStatus("窗口切换已停用")
    }

    /// Input hot path: cached selection only, deferred drawing and no AX/CG calls.
    func advance(reverse: Bool) {
        guard running, isReady else { return }
        if sessionKind == .preview { cancel() }
        if session == nil {
            sessionKind = .command
            sessionWindows = snapshot.windows
            session = SwitcherSelection(windowIDs: sessionWindows.map(\.id),
                                         focusedWindowID: snapshot.focusedID, reverse: reverse)
            schedulePresentation()
        } else {
            session?.move(by: reverse ? -1 : 1)
            enqueueRender()
        }
    }

    func moveSelection(horizontal: Int, vertical: Int) {
        guard session != nil else { return }
        if vertical != 0 { session?.moveVertically(direction: vertical, columns: panel?.columnCount ?? 1) }
        else { session?.move(by: horizontal) }
        enqueueRender()
    }

    func releaseCommand() {
        // A delayed modifier release from an old input session cannot commit a preview choice.
        guard sessionKind == .command else { return }
        confirmSelection()
    }

    func confirmSelection() {
        guard let chosenID = session?.selectedWindowID,
              let chosen = sessionWindows.first(where: { $0.id == chosenID }) else { cancel(); return }
        cancel()
        let expected = generation
        inventory.focus(chosen) { [weak self] landed in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected else { return }
                if !landed { self.setStatus("此窗口未能切换；请重试或使用原生切换") }
                self.scheduleRefresh(immediate: true)
            }
        }
    }

    func cancel() {
        sessionToken &+= 1
        thumbnailTicket?.cancel(); thumbnailTicket = nil
        thumbnailPage.removeAll(); thumbnailImages.removeAll()
        presentationWork?.cancel(); presentationWork = nil
        queuedRenderToken = nil
        session = nil; sessionKind = nil; sessionWindows.removeAll(); panel?.hide()
    }

    func showPreview() {
        guard running, snapshot.accessibilityTrusted, snapshot.mappingAvailable, !snapshot.windows.isEmpty else {
            setStatus("窗口列表尚未就绪"); return
        }
        cancel()
        sessionKind = .preview
        sessionWindows = snapshot.windows
        session = SwitcherSelection(windowIDs: sessionWindows.map(\.id))
        if let current = snapshot.focusedID { session?.select(windowID: current) }
        present()
    }

    @objc private func previewPressed() { showPreview() }

    private func schedulePresentation() {
        let expected = generation
        let expectedSession = sessionToken
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected, self.sessionToken == expectedSession, self.session != nil else { return }
                self.present()
            }
        }
        presentationWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func enqueueRender() {
        guard panel?.isVisible == true, queuedRenderToken == nil else { return }
        let expected = generation
        let expectedSession = sessionToken
        queuedRenderToken = expectedSession
        DispatchQueue.main.async { [weak self] in
            guard let self, self.queuedRenderToken == expectedSession else { return }
            self.queuedRenderToken = nil
            guard self.running, self.generation == expected, self.sessionToken == expectedSession, self.session != nil, self.panel?.isVisible == true else { return }
            self.present()
        }
    }

    private func present() {
        guard session != nil, !sessionWindows.isEmpty else { return }
        if panel == nil {
            let created = SwitcherPanel()
            created.onChoose = { [weak self] id in
                guard let self, self.sessionWindows.contains(where: { $0.id == id }) else { return }
                self.session?.select(windowID: id); self.confirmSelection()
            }
            created.onHighlight = { [weak self] id in
                guard let self, self.session?.selectedWindowID != id else { return }
                self.session?.select(windowID: id); self.enqueueRender()
            }
            created.onMove = { [weak self] in self?.moveSelection(horizontal: $0, vertical: $1) }
            created.onConfirm = { [weak self] in self?.confirmSelection() }
            created.onCancel = { [weak self] in self?.cancel() }
            panel = created
        }
        panel?.show(windows: sessionWindows, selectedID: session?.selectedWindowID,
                    thumbnails: thumbnailImages, preview: sessionKind == .preview)
        requestVisibleThumbnails()
    }

    func retryThumbnailPermission() { thumbnailPermissionDenied = false; thumbnailPage.removeAll() }

    @objc private func changeThumbnails(_ sender: NSButton) {
        defaults.set(sender.state == .on, forKey: "switcher.thumbnails")
        thumbnailTicket?.cancel(); thumbnailTicket = nil
        thumbnailPage.removeAll(); thumbnailImages.removeAll()
        if !thumbnailsEnabled { thumbnails.clear() }
        if session != nil { enqueueRender() }
        onPreviewSettingsChanged?()
    }

    private func requestVisibleThumbnails() {
        guard thumbnailsEnabled, !thumbnailPermissionDenied, hasConfirmedThumbnailAccess || CGPreflightScreenCaptureAccess(),
              let panel, panel.isVisible else { return }
        let visible = panel.visibleWindows
        let ids = visible.map { WindowThumbnailID(window: $0.id, process: $0.pid) }
        guard ids != thumbnailPage else { return }
        thumbnailTicket?.cancel(); thumbnailPage = ids
        let live = Set(ids.map(\.window)); thumbnailImages = thumbnailImages.filter { live.contains($0.key) }
        let expected = generation, token = sessionToken
        // Selected window first, then its visible neighbours; never prefetch all windows.
        let ordered = ids.sorted { $0.window == session?.selectedWindowID && $1.window != session?.selectedWindowID }
        thumbnailTicket = thumbnails.request(ordered, updated: { [weak self] id, image in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected, self.sessionToken == token,
                      self.thumbnailPage.contains(id) else { return }
                self.hasConfirmedThumbnailAccess = true; self.thumbnailImages[id.window] = image
                self.enqueueRender()
            }
        }, failed: { [weak self] error in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected, self.sessionToken == token else { return }
                if case CaptureFailure.permission = CaptureFailure.screenCaptureError(error) {
                    self.hasConfirmedThumbnailAccess = false; self.thumbnailPermissionDenied = true
                    self.setStatus("缩略图需要屏幕权限，仍可用图标切换。")
                    self.onPreviewSettingsChanged?()
                }
            }
        })
    }

    private func scheduleRefresh(immediate: Bool = false) {
        guard running else { return }
        refreshWork?.cancel()
        let expected = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected else { return }
                self.inventory.refresh(frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier) { [weak self] result in
                    MainActor.assumeIsolated { self?.accept(result) }
                }
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.08), execute: work)
    }

    private func acceptConfirmedFocus(_ id: CGWindowID) {
        guard running else { return }
        var windows = snapshot.windows
        if let index = windows.firstIndex(where: { $0.id == id }) {
            let focused = windows.remove(at: index); windows.insert(focused, at: 0)
        }
        snapshot = .init(windows: windows, focusedID: id, mappingAvailable: snapshot.mappingAvailable,
                         accessibilityTrusted: snapshot.accessibilityTrusted)
    }

    private func accept(_ result: WindowInventorySnapshot) {
        guard running else { return }
        snapshot = result
        let ready = result.accessibilityTrusted && result.mappingAvailable && result.windows.count > 1
        setReadiness(ready)
        if !result.accessibilityTrusted { setStatus("辅助功能权限不可用；当前使用 macOS 原生切换") }
        else if !result.mappingAvailable { setStatus("系统窗口映射不可用；当前使用 macOS 原生切换") }
        else { setStatus("⌘Tab 切换 · 松开 ⌘ 确认 · Esc 取消") }
        thumbnails.retain(Set(result.windows.map { WindowThumbnailID(window: $0.id, process: $0.pid) }))
        if session != nil {
            // Freeze order while the user cycles; remove dead windows, append genuinely new ones.
            let live = Dictionary(result.windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            sessionWindows = sessionWindows.compactMap { live[$0.id] }
            let known = Set(sessionWindows.map(\.id))
            sessionWindows += result.windows.filter { !known.contains($0.id) }
            session?.replaceWindows(sessionWindows.map(\.id))
            if sessionWindows.isEmpty { cancel() } else { enqueueRender() }
        }
    }

    private func setReadiness(_ value: Bool) {
        previewButton?.isEnabled = running && snapshot.accessibilityTrusted && snapshot.mappingAvailable && !snapshot.windows.isEmpty
        // The input owner may clear its held modifier state before another release arrives.
        // Close our own held session first, including when the value was already false.
        // A one-window manual preview can stay open while Cmd+Tab uses native fallback.
        if !value && (sessionKind == .command || !snapshot.accessibilityTrusted || !snapshot.mappingAvailable) { cancel() }
        guard isReady != value else { return }
        isReady = value; onReadinessChanged?(value)
    }

    private func setStatus(_ value: String) { status = value; statusLabel?.stringValue = value }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification]
        for name in names {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if notification.name == NSWorkspace.didActivateApplicationNotification,
                       let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                        if self.session != nil { self.cancel() }
                        self.inventory.applicationActivated(application.processIdentifier)
                    }
                    if notification.name == NSWorkspace.activeSpaceDidChangeNotification {
                        self.cancel(); self.inventory.invalidateScans()
                    }
                    self.scheduleRefresh()
                }
            })
        }
    }
}
