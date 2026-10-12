import AppKit
import MacOSXCore

/// This opt-in module owns its single sampler, bounded history and status item.
@MainActor
final class SystemStatusModule: NSObject {
    var onOpenDashboard: (() -> Void)?
    var onStatusChange: (() -> Void)?
    private let sampler: SystemStatusSampler
    private let makeStatusItem: () -> NSStatusItem?
    private var item: NSStatusItem?
    private var active = false
    private var latest: SystemStatusSnapshot?
    private var history: [SystemStatusSnapshot] = []
    private var dashboards: [WeakDashboard] = []
    private(set) var issue: String?

    init(sampler: SystemStatusSampler? = nil, makeStatusItem: (() -> NSStatusItem?)? = nil) {
        self.sampler = sampler ?? SystemStatusSampler()
        self.makeStatusItem = makeStatusItem ?? { NSStatusBar.system.statusItem(withLength: 74) }
        super.init()
        self.sampler.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
    }

    func start() {
        guard !active else { return }
        active = true
        let item = makeStatusItem()
        self.item = item
        if let button = item?.button {
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.title = "CPU —"
            button.target = self
            button.action = #selector(openDashboard)
            button.setAccessibilityLabel("系统状态 · 点击查看实时监控")
        }
        updateDashboards(includeHidden: true)
        sampler.start()
    }

    func stop() {
        guard active else { return }
        active = false
        sampler.stop()
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        latest = nil
        history.removeAll(keepingCapacity: false)
        issue = nil
        updateDashboards(includeHidden: true)
    }

    func makeDashboard() -> SystemStatusDashboardView {
        dashboards.removeAll { $0.view == nil }
        let view = SystemStatusDashboardView(frame: .zero)
        dashboards.append(WeakDashboard(view))
        view.update(snapshot: latest, history: history, isEnabled: active)
        return view
    }

    private func receive(_ snapshot: SystemStatusSnapshot) {
        guard active, snapshot.timestamp.isFinite else { return }
        // A fresh baseline after wake must not join the previous session's curve.
        if let previous = latest,
           snapshot.timestamp <= previous.timestamp || snapshot.timestamp - previous.timestamp > 8 {
            history.removeAll(keepingCapacity: true)
        }
        latest = snapshot
        history.append(snapshot)
        history = Array(history.filter { snapshot.timestamp - $0.timestamp <= 60 }.suffix(31))
        let nextIssue = snapshot.issues.first
        if issue != nextIssue { issue = nextIssue; onStatusChange?() }
        let percent = snapshot.cpuPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        let title = percent.map { "CPU \(Int($0.rounded()))%" } ?? "CPU —"
        if item?.button?.title != title { item?.button?.title = title }
        item?.button?.toolTip = "系统状态 · \(title) · 点击查看内存、网速与最近一分钟趋势"
        updateDashboards()
    }

    func refreshDashboard() { updateDashboards() }

    private func updateDashboards(includeHidden: Bool = false) {
        dashboards.removeAll { $0.view == nil }
        for dashboard in dashboards {
            // Hidden pages keep the latest model here and redraw only when reopened.
            guard let view = dashboard.view, includeHidden || view.window?.isVisible == true else { continue }
            view.update(snapshot: latest, history: history, isEnabled: active)
        }
    }

    @objc private func openDashboard() { guard active else { return }; onOpenDashboard?() }

    private final class WeakDashboard {
        weak var view: SystemStatusDashboardView?
        init(_ view: SystemStatusDashboardView) { self.view = view }
    }
}
