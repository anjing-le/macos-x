import AppKit
import Darwin

struct MenuBarOwnerIdentity {
    let bundle: String
    let aliases: Set<String>
}
struct MenuBarHiddenFamily {
    var aliases: Set<String>
    var pids: Set<pid_t>
}
struct MenuBarProtectedOwner {
    let pid: pid_t
    let surface: CGRect
}
struct MenuBarConcealmentPlan {
    let families: [String: MenuBarHiddenFamily]
    let allowing: Set<String>
    let rightAliases: Set<String>
    let protected: [MenuBarProtectedOwner]
    var hidden: Set<String> { Set(families.keys) }
    var hiddenPIDs: Set<pid_t> { Set(families.values.flatMap { $0.pids }) }
}

/// A whitelist hides every omitted owner, not just the configured left side.
/// Revalidate all bars before each concealment and verify the actual result.
/// The guard is event-driven, serial and bounded; no capture or idle polling.
final class MenuBarConcealmentGuard {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.menu-bar-concealment", qos: .userInitiated)

    static func plan(snapshot: MenuBarContainerSnapshot, own: pid_t, expectedApple: CGRect?,
                     identities: [pid_t: MenuBarOwnerIdentity], runningBundles: Set<String>,
                     desired: Set<String>, previous: MenuBarConcealmentPlan?) -> MenuBarConcealmentPlan? {
        guard snapshot.complete, !snapshot.entries.isEmpty else { return nil }
        func key(_ item: MenuBarContainer) -> String? {
            guard let area = item.surface, area.minX.isFinite, area.minY.isFinite,
                  area.width.isFinite, area.height.isFinite, area.width > 0, area.height > 0, area.height <= 80 else { return nil }
            return item.surfaceID.map { "window:\($0)" } ?? NSStringFromRect(area)
        }
        var bars: [String: [MenuBarContainer]] = [:]
        for item in snapshot.entries {
            guard let id = key(item) else { return nil }
            bars[id, default: []].append(item)
        }
        var families = previous?.families.filter { desired.contains($0.key) } ?? [:]
        var right = Set<String>(), protectedAliases = MenuBarSections.systemOwners
        var allAliases = runningBundles.union(MenuBarSections.systemOwners)
        var identified: [(MenuBarContainer, MenuBarOwnerIdentity)] = []
        var foundApple = false
        for items in bars.values {
            var anchors: [MenuBarContainer] = []
            for item in items where item.pid == own && !anchors.contains(where: { $0.frame == item.frame }) { anchors.append(item) }
            if anchors.count > 1, let expectedApple {
                let center = CGPoint(x: expectedApple.midX, y: expectedApple.midY)
                anchors = anchors.filter { $0.frame.contains(center) }
            }
            guard anchors.count <= 1 else { return nil }
            let apple = anchors.first?.frame
            if apple != nil { foundApple = true }
            // A bar with no confirmed apple is protected in its entirety.
            for item in items where item.pid != own {
                guard let identity = identities[item.pid], !identity.bundle.isEmpty,
                      !identity.aliases.isEmpty, identity.aliases.contains(identity.bundle) else { return nil }
                allAliases.formUnion(identity.aliases); identified.append((item, identity))
                let wanted = desired.filter { identity.aliases.contains($0) || families[$0]?.aliases.isDisjoint(with: identity.aliases) == false }
                let left = apple.map { boundary in
                    item.frame.width > 0 && item.frame.height > 0 && item.frame.maxX <= boundary.minX + 0.5
                        && abs(item.frame.midY - boundary.midY) <= 8
                } ?? false
                let confirmedRight = apple.map { boundary in
                    item.frame.minX >= boundary.maxX - 0.5 && abs(item.frame.midY - boundary.midY) <= 8
                } ?? false
                if confirmedRight { right.formUnion(identity.aliases) }
                if !left || wanted.isEmpty { protectedAliases.formUnion(identity.aliases) }
                if left {
                    for bundle in wanted {
                        var family = families[bundle] ?? MenuBarHiddenFamily(aliases: [bundle], pids: [])
                        family.aliases.formUnion(identity.aliases); family.pids.insert(item.pid); families[bundle] = family
                    }
                }
            }
        }
        guard foundApple else { return nil }
        if let ownIdentity = identities[own] { allAliases.formUnion(ownIdentity.aliases); protectedAliases.formUnion(ownIdentity.aliases) }
        families = families.filter { $0.value.aliases.isDisjoint(with: protectedAliases) }
        let hiddenAliases = Set(families.values.flatMap { $0.aliases })
        let protected = identified.compactMap { item, identity -> MenuBarProtectedOwner? in
            guard identity.aliases.isDisjoint(with: hiddenAliases), let surface = item.surface else { return nil }
            return .init(pid: item.pid, surface: surface)
        }
        return .init(families: families, allowing: allAliases.subtracting(hiddenAliases), rightAliases: right, protected: protected)
    }

    static func preserves(_ plan: MenuBarConcealmentPlan, snapshot: MenuBarContainerSnapshot) -> Bool {
        guard snapshot.complete else { return false }
        if snapshot.entries.contains(where: { plan.hiddenPIDs.contains($0.pid) }) { return false }
        return plan.protected.allSatisfy { before in
            snapshot.entries.contains { after in
                guard after.pid == before.pid, let surface = after.surface else { return false }
                // The compositor may rebuild its window ID during reflow.
                return abs(surface.midY - before.surface.midY) <= 4
                    && surface.intersection(before.surface).width >= min(surface.width, before.surface.width) * 0.5
            }
        }
    }

    private func identities(_ snapshot: MenuBarContainerSnapshot, applications: [NativeMenuBarApplication],
                            token: MenuBarReadToken, deadline: TimeInterval) -> [pid_t: MenuBarOwnerIdentity]? {
        let names = Dictionary(applications.map { ($0.pid, $0.bundle) }, uniquingKeysWith: { a, _ in a })
        var result: [pid_t: MenuBarOwnerIdentity] = [:]
        for pid in Set(snapshot.entries.map(\.pid)) {
            guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var aliases = Set<String>()
            if let name = names[pid], !name.isEmpty { aliases.insert(name) }
            // Native menu owners can be LSUIElement helpers missing from the
            // NSWorkspace list. Resolve their own and enclosing app identities.
            var bytes = [CChar](repeating: 0, count: 4096)
            let size = proc_pidpath(pid, &bytes, UInt32(bytes.count))
            if size > 0 {
                var path = URL(fileURLWithPath: String(cString: bytes)).deletingLastPathComponent()
                for _ in 0..<32 {
                    if path.pathExtension == "app", let id = Bundle(url: path)?.bundleIdentifier, !id.isEmpty { aliases.insert(id) }
                    let parent = path.deletingLastPathComponent(); if parent == path { break }; path = parent
                }
            }
            guard let bundle = names[pid] ?? aliases.sorted().first else { return nil }
            result[pid] = .init(bundle: bundle, aliases: aliases)
        }
        return result
    }
    private func signature(_ snapshot: MenuBarContainerSnapshot) -> [String] {
        snapshot.entries.map { "\($0.pid)|\(NSStringFromRect($0.frame))|\(NSStringFromRect($0.surface ?? .zero))" }.sorted()
    }
    func prepare(desired: Set<String>, previous: MenuBarConcealmentPlan?, apple: CGRect?,
                 applications: [NativeMenuBarApplication], token: MenuBarReadToken,
                 completion: @escaping (MenuBarConcealmentPlan?) -> Void) {
        let own = ProcessInfo.processInfo.processIdentifier
        queue.async {
            guard !token.isCancelled else { return }
            let first = MenuBarInventory.snapshot(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.65)
            self.queue.asyncAfter(deadline: .now() + 0.12) {
                guard !token.isCancelled else { return }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.8
                let second = MenuBarInventory.snapshot(token: token, deadline: deadline)
                let identities = self.identities(second, applications: applications, token: token, deadline: deadline)
                let plan = first.complete && second.complete && self.signature(first) == self.signature(second)
                    ? identities.flatMap { Self.plan(snapshot: second, own: own, expectedApple: apple, identities: $0,
                          runningBundles: Set(applications.map(\.bundle)), desired: desired, previous: previous) } : nil
                DispatchQueue.main.async { if !token.isCancelled { completion(plan) } }
            }
        }
    }
    func verify(_ plan: MenuBarConcealmentPlan, token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        func check(_ previous: Bool, attempt: Int) {
            guard !token.isCancelled else { return }
            let snapshot = MenuBarInventory.snapshot(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.65)
            let valid = Self.preserves(plan, snapshot: snapshot)
            if valid && previous { DispatchQueue.main.async { if !token.isCancelled { completion(true) } }; return }
            guard attempt < 2 else { DispatchQueue.main.async { if !token.isCancelled { completion(false) } }; return }
            self.queue.asyncAfter(deadline: .now() + 0.12) { check(valid, attempt: attempt + 1) }
        }
        queue.asyncAfter(deadline: .now() + 0.12) { check(false, attempt: 0) }
    }
}
