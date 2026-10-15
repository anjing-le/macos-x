import AppKit
import ApplicationServices
import MacOSXCore

/// Explicit opt-in. Merely adding/enabling the module performs no scan and
/// installs no keyboard tap, global hotkey, notification watcher or timer.
@MainActor
final class ShortcutRadarModule {
    private let scanner: ShortcutRadarScanner
    private let configuration: ([UInt16: String]) -> [RadarUse]
    private let captureChanged: (Bool) -> Void
    private let requestPermission: () -> Void
    private var active = false
    private var generation: UInt64 = 0
    private var token: RadarScanToken?
    private var snapshot: RadarSnapshot?
    private var icons: [String: NSImage] = [:]
    private weak var dashboard: ShortcutRadarDashboard?
    private var busy = false

    init(scanner: ShortcutRadarScanner = ShortcutRadarScanner(),
         configuration: @escaping ([UInt16: String]) -> [RadarUse],
         captureChanged: @escaping (Bool) -> Void,
         requestPermission: @escaping () -> Void) {
        self.scanner = scanner; self.configuration = configuration
        self.captureChanged = captureChanged; self.requestPermission = requestPermission
    }
    func start() { guard !active else { return }; active = true; refresh() }
    func stop() {
        active = false; cancel(); snapshot = nil; icons.removeAll()
        dashboard?.endCapture(); refresh()
    }
    func makeDashboard() -> ShortcutRadarDashboard {
        dashboard?.endCapture()
        let view = ShortcutRadarDashboard(frame: .zero)
        dashboard = view
        view.onScan = { [weak self] query in
            guard let self else { return }
            if self.busy { self.cancel() } else { self.scan(query: query) }
        }
        view.onCaptureChanged = { [weak self] value in self?.captureChanged(value) }
        view.onRequestPermission = { [weak self] in self?.requestPermission() }
        view.onLeave = { [weak self] in self?.cancel() }
        refresh()
        return view
    }
    private func cancel() {
        generation &+= 1; token?.cancel(); token = nil; busy = false
        refresh()
    }
    private func scan(query: RadarChord?) {
        guard active, !busy else { return }
        dashboard?.endCapture()
        let labels = RadarNativeSeed.keyLabels()
        let canReadMenus = AXIsProcessTrusted()
        let own = configuration(labels)
        let (system, available) = RadarNativeSeed.systemUses(labels: labels)
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory) && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }.sorted {
            if $0.activationPolicy != $1.activationPolicy { return $0.activationPolicy == .regular }
            return ($0.localizedName ?? "") < ($1.localizedName ?? "")
        }
        // NSRunningApplication icons and metadata are snapshotted on the main
        // thread. The AX worker never reaches back into AppKit or UserDefaults.
        icons.removeAll(keepingCapacity: true)
        let apps = applications.prefix(32).map { app -> RadarApp in
            let id = (app.bundleIdentifier ?? "pid") + ":\(app.processIdentifier)"
            if canReadMenus, let source = app.icon, let icon = RadarNativeSeed.thumbnail(source) { icons[id] = icon }
            return .init(pid: app.processIdentifier, id: id, name: String((app.localizedName ?? "未命名应用").prefix(100)))
        }
        var seed = RadarSnapshot(uses: Array((own + system).prefix(RadarIndex.maximumUses)), totalApps: applications.count,
                                 accessibility: canReadMenus, systemAvailable: available)
        if let query { seed.probe = RadarNativeSeed.probe(query, labels: labels, known: seed.uses) }
        busy = true; generation &+= 1
        let expected = generation, token = RadarScanToken()
        self.token = token
        refresh()
        scanner.scan(apps: apps, labels: labels, seed: seed, token: token) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active, self.generation == expected, !token.isCancelled else { return }
                self.busy = false; self.token = nil; self.snapshot = result
                self.refresh()
            }
        }
    }
    private func refresh() {
        dashboard?.update(snapshot: snapshot, icons: icons, enabled: active, busy: busy)
    }
}
