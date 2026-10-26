import AppKit

struct MenuBarBoundaryLayout {
    let apple: CGRect
    let entries: [MenuBarEntry]
    let complete: Bool
}

enum MenuBarBoundaryGrouping {
    /// A right-side sibling always wins: native concealment is per application.
    /// Unreadable/overflow entries must never become new hiding candidates.
    static func order(_ layout: MenuBarBoundaryLayout, previous: [String], running: Set<String>) -> [String]? {
        let apple = layout.apple
        guard layout.complete, apple.minX.isFinite, apple.minY.isFinite,
              apple.width > 0, apple.width < 100, apple.height > 0, apple.height < 80 else { return nil }
        let uncertain = Set(layout.entries.filter { !$0.visible }.map(\.bundle))
        let verified = layout.entries.filter { $0.visible && !uncertain.contains($0.bundle) }
        let left = MenuBarSections.hidden(verified, boundary: apple, leftToRight: true)
            .subtracting(MenuBarSections.systemOwners).subtracting([Bundle.main.bundleIdentifier ?? "cc.anjing.macos-x"])
        let offline = previous.filter { !running.contains($0) }
        let inPositionOrder = verified.sorted { $0.frame.minX < $1.frame.minX }.map(\.bundle)
        var seen = Set<String>()
        return Array((previous.filter { left.contains($0) } + inPositionOrder.filter { left.contains($0) } + offline)
            .filter { seen.insert($0).inserted }.prefix(40))
    }
}

/// Observe settled native geometry. This does not move status items or send
/// input. Two matching reads (at most three attempts) protect against reflow.
final class MenuBarBoundaryReader {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.menu-bar-boundary", qos: .userInitiated)
    /// Resolve the apple on the actual drop surface, not the one AppKit's
    /// single status-item window happened to report. Multiple own items without
    /// a matching AppKit anchor remain ambiguous and must stay visible.
    static func layout(_ snapshot: MenuBarContainerSnapshot, own: pid_t, names: [pid_t: String],
                       expectedApple: CGRect?, dropPoint: CGPoint?) -> MenuBarBoundaryLayout? {
        guard snapshot.complete else { return nil }
        var anchors = snapshot.entries.filter { item in
            item.pid == own && item.frame.width > 0 && item.frame.height > 0
                && (dropPoint.map { item.surface?.contains($0) == true } ?? true)
        }
        if let expectedApple {
            let center = CGPoint(x: expectedApple.midX, y: expectedApple.midY)
            let matching = anchors.filter { $0.frame.contains(center) }
            if !matching.isEmpty { anchors = matching }
            else if dropPoint == nil { return nil }
        } else if dropPoint == nil { return nil }
        // Duplicate AX nodes with identical surface/geometry are one anchor.
        var unique: [MenuBarContainer] = []
        for item in anchors where !unique.contains(where: {
            $0.frame == item.frame && $0.surface == item.surface && $0.surfaceID == item.surfaceID
        }) { unique.append(item) }
        guard unique.count == 1, let anchor = unique.first else { return nil }
        let local = snapshot.entries.filter { $0.surfaceID == anchor.surfaceID && $0.surface == anchor.surface }
        var entries: [MenuBarEntry] = []
        for item in local where item.pid != own {
            guard let bundle = names[item.pid], !MenuBarSections.systemOwners.contains(bundle) else { continue }
            let overlap = local.contains { other in
                other.pid != item.pid && other.frame.intersection(item.frame).width > 0.5
                    && other.frame.intersection(item.frame).height > 0.5
            }
            entries.append(.init(bundle: bundle, frame: item.frame, pid: item.pid, visible: !overlap))
        }
        return .init(apple: anchor.frame, entries: entries, complete: true)
    }
    func read(apple expected: CGRect?, at dropPoint: CGPoint?, applications: [NativeMenuBarApplication], token: MenuBarReadToken,
              completion: @escaping (MenuBarBoundaryLayout?) -> Void) {
        let own = ProcessInfo.processInfo.processIdentifier
        let names = Dictionary(applications.map { ($0.pid, $0.bundle) }, uniquingKeysWith: { a, _ in a })
        func sample() -> MenuBarBoundaryLayout? {
            guard !token.isCancelled else { return nil }
            let snapshot = MenuBarInventory.snapshot(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.65)
            return Self.layout(snapshot, own: own, names: names, expectedApple: expected, dropPoint: dropPoint)
        }
        func signature(_ layout: MenuBarBoundaryLayout?) -> [String]? {
            layout.map { value in
                [NSStringFromRect(value.apple)] + value.entries.map { "\($0.pid)|\($0.bundle)|\(NSStringFromRect($0.frame))|\($0.visible)" }.sorted()
            }
        }
        func finish(_ layout: MenuBarBoundaryLayout?) {
            DispatchQueue.main.async { if !token.isCancelled { completion(layout) } }
        }
        func next(_ previous: MenuBarBoundaryLayout?, attempt: Int) {
            guard !token.isCancelled else { return }
            let current = sample()
            if let current, signature(current) == signature(previous) { finish(current); return }
            guard attempt < 2 else { finish(nil); return }
            self.queue.asyncAfter(deadline: .now() + 0.12) { next(current, attempt: attempt + 1) }
        }
        queue.asyncAfter(deadline: .now() + 0.16) { next(nil, attempt: 0) }
    }
}
