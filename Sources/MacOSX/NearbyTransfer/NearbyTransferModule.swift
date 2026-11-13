import AppKit

@MainActor final class NearbyTransferModule {
    let service: NearbyTransferService
    var anchor: (() -> CGRect?)?
    var onSettings: (() -> Void)?
    var onStatusChange: (() -> Void)?
    var onOpen: (() -> Void)?
    var isDrawerVisible: Bool { panel?.isVisible == true }
    private var panel: NearbyPanel?
    private var view: NearbyTransferView?
    private var dashboards: [WeakView] = []
    private var localMonitor: Any?
    init(service: NearbyTransferService? = nil) {
        self.service = service ?? NearbyTransferService(link: NearbyMultipeerLink())
        self.service.onChange = { [weak self] in self?.refresh() }
        self.service.onAttention = { [weak self] in
            guard let self, self.service.incomingInvitation || (self.service.pairingCode != nil && !self.service.ready) else { return }
            self.show(focus: false)
        }
    }
    func start() { service.start() }
    func stop() {
        hide(); panel?.contentView = nil; panel = nil; view = nil
        service.stop(); refresh()
    }
    func makeDashboard() -> NSView {
        let view = NearbyTransferView(service: service)
        view.onSettings = { [weak self] in self?.show(focus: true) }
        dashboards.removeAll { $0.view == nil }; dashboards.append(WeakView(view)); return view
    }
    func toggle() { isDrawerVisible ? hide() : show(focus: true) }
    func hide() {
        panel?.orderOut(nil)
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }
    func show(focus: Bool) {
        guard service.running, let anchor = anchor?() else { return }
        if panel == nil {
            let panel = NearbyPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 548), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = NearbyTransferView(service: service)
            view.onSettings = { [weak self] in self?.hide(); self?.onSettings?() }
            panel.contentView = view; self.panel = panel; self.view = view
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: min(420, available.width - 16), height: min(548, available.height - 16))
        let x = min(max(available.minX + 8, anchor.midX - size.width / 2), available.maxX - size.width - 8)
        let y = max(available.minY + 8, min(anchor.minY - size.height - 6, available.maxY - size.height - 8))
        onOpen?(); panel?.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: size), display: true)
        view?.refresh(); panel?.orderFrontRegardless()
        if focus { panel?.makeKey(); panel?.makeFirstResponder(view) }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53, event.window === self.panel { self.hide(); return nil }
                return event
            }
        }
    }
    private func refresh() {
        view?.refresh(); dashboards.removeAll { $0.view == nil }; dashboards.forEach { $0.view?.refresh() }; onStatusChange?()
    }
    private final class WeakView { weak var view: NearbyTransferView?; init(_ view: NearbyTransferView) { self.view = view } }
}

@MainActor private final class NearbyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
