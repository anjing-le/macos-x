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
    func read(apple expected: CGRect, applications: [NativeMenuBarApplication], token: MenuBarReadToken,
              completion: @escaping (MenuBarBoundaryLayout?) -> Void) {
        let own = ProcessInfo.processInfo.processIdentifier
        let names = Dictionary(applications.map { ($0.pid, $0.bundle) }, uniquingKeysWith: { a, _ in a })
        func sample() -> MenuBarBoundaryLayout? {
            guard !token.isCancelled else { return nil }
            let snapshot = MenuBarInventory.snapshot(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.65)
            guard snapshot.complete else { return nil }
            let center = CGPoint(x: expected.midX, y: expected.midY)
            let anchors = snapshot.entries.filter { $0.pid == own && $0.frame.contains(center) }
            guard let anchor = anchors.first, Set(anchors.map { NSValue(rect: $0.frame) }).count == 1 else { return nil }
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
