import AppKit
import MacOSXCore

/// This opt-in module owns its sampler and bounded history; values stay in its dashboard.
@MainActor
final class SystemStatusModule: NSObject {
    var onStatusChange: (() -> Void)?
    private let sampler: SystemStatusSampler
    private var active = false
    private var latest: SystemStatusSnapshot?
    private var history: [SystemStatusSnapshot] = []
    private var dashboards: [WeakDashboard] = []
    private(set) var issue: String?

    init(sampler: SystemStatusSampler? = nil) {
        self.sampler = sampler ?? SystemStatusSampler()
        super.init()
        self.sampler.onUpdate = { [weak self] snapshot in self?.receive(snapshot) }
    }

    func start() {
        guard !active else { return }
        active = true
        updateDashboards(includeHidden: true)
        sampler.start()
    }

    func stop() {
        guard active else { return }
        active = false
        sampler.stop()
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

    private final class WeakDashboard {
        weak var view: SystemStatusDashboardView?
        init(_ view: SystemStatusDashboardView) { self.view = view }
    }
}
