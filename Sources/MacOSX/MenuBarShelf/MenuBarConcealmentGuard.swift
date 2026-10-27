import AppKit
import Darwin
import os

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
    // Only these owners were actually hit-testable before the transition.
    // AXChildren also contains overflow/hidden logical nodes.
    var renderedProtected: [MenuBarProtectedOwner] = []
    var hidden: Set<String> { Set(families.keys) }
    var hiddenPIDs: Set<pid_t> { Set(families.values.flatMap { $0.pids }) }
}

/// A whitelist hides every omitted owner, not just the configured left side.
/// Revalidate all bars before each concealment and verify the actual result.
/// The guard is event-driven, serial and bounded; no capture or idle polling.
final class MenuBarConcealmentGuard {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.menu-bar-concealment", qos: .userInitiated)
    private let logger = Logger(subsystem: "cc.anjing.macos-x", category: "menu-bar-concealment")

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

    private static func matches(_ item: MenuBarContainer, _ before: MenuBarProtectedOwner) -> Bool {
        guard item.pid == before.pid, let surface = item.surface else { return false }
        return abs(surface.midY - before.surface.midY) <= 4
            && surface.intersection(before.surface).width >= min(surface.width, before.surface.width) * 0.5
    }

    static func confirmingRenderedProtection(_ plan: MenuBarConcealmentPlan, snapshot: MenuBarContainerSnapshot,
                                            hitOwner: (MenuBarContainer) -> pid_t?) -> MenuBarConcealmentPlan {
        var result = plan
        result.renderedProtected = plan.protected.filter { before in
            snapshot.entries.contains { matches($0, before) && hitOwner($0) == before.pid }
        }
        return result
    }

    static func preserves(_ plan: MenuBarConcealmentPlan, snapshot: MenuBarContainerSnapshot,
                          hitOwner: ((MenuBarContainer) -> pid_t?)? = nil) -> Bool {
        guard snapshot.complete else { return false }
        // Concealment does not promise to remove the app's logical AX nodes.
        // Their continued existence is not evidence that an icon is visible.
        guard plan.protected.allSatisfy({ before in
            snapshot.entries.contains { matches($0, before) }
        }) else { return false }
        guard let hitOwner else { return true }
        return plan.renderedProtected.allSatisfy { before in
            snapshot.entries.contains { matches($0, before) && hitOwner($0) == before.pid }
        }
    }

    /// Read-only z-order hit testing. Never moves the pointer or sends input.
    /// Only previously confirmed visible owners become hard hit-test requirements;
    /// unsupported/overflow entries remain protected by aliases and AX geometry.
    private func hitReader(_ snapshot: MenuBarContainerSnapshot, token: MenuBarReadToken,
                           deadline: TimeInterval) -> (MenuBarContainer) -> pid_t? {
        let root = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.025)
        let own = ProcessInfo.processInfo.processIdentifier
        var cache: [String: pid_t] = [:]
        return { item in
            guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let point = CGPoint(x:item.frame.midX,y:item.frame.midY)
            // Avoid dispatching a background AX request into our own AppKit.
            if snapshot.entries.contains(where: { $0.pid == own && $0.frame.contains(point) }) { return own }
            let key = NSStringFromPoint(point)
            if let cached = cache[key] { return cached > 0 ? cached : nil }
            var element: AXUIElement?, pid: pid_t = 0
            if AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element) == .success,
               let element, AXUIElementGetPid(element, &pid) == .success, pid > 0 {
                cache[key] = pid; return pid
            }
            cache[key] = 0; return nil
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
    static func stablePlan(first:MenuBarContainerSnapshot, second:MenuBarContainerSnapshot, own:pid_t,
                           expectedApple:CGRect?, identities:[pid_t:MenuBarOwnerIdentity],
                           runningBundles:Set<String>, desired:Set<String>, previous:MenuBarConcealmentPlan?) -> MenuBarConcealmentPlan? {
        guard let a = plan(snapshot:first,own:own,expectedApple:expectedApple,identities:identities,runningBundles:runningBundles,desired:desired,previous:previous),
              let b = plan(snapshot:second,own:own,expectedApple:expectedApple,identities:identities,runningBundles:runningBundles,desired:desired,previous:previous) else { return nil }
        func protection(_ value:MenuBarConcealmentPlan) -> [String] {
            value.protected.map { "\($0.pid)|\(NSStringFromRect($0.surface))" }.sorted()
        }
        // Traffic labels may change width without changing safe ownership.
        guard a.hidden == b.hidden, a.allowing == b.allowing, a.rightAliases == b.rightAliases,
              protection(a) == protection(b) else { return nil }
        return b
    }
    func prepare(desired: Set<String>, previous: MenuBarConcealmentPlan?, apple: CGRect?,
                 applications: [NativeMenuBarApplication], token: MenuBarReadToken,
                 completion: @escaping (MenuBarConcealmentPlan?) -> Void) {
        let own = ProcessInfo.processInfo.processIdentifier
        let deadline = ProcessInfo.processInfo.systemUptime + 2.4
        func sample(_ prior:MenuBarContainerSnapshot?, attempt:Int) {
            guard !token.isCancelled else { return }
            let current = MenuBarInventory.snapshot(token:token,deadline:min(deadline,ProcessInfo.processInfo.systemUptime+0.45))
            let ids = self.identities(current,applications:applications,token:token,deadline:min(deadline,ProcessInfo.processInfo.systemUptime+0.35))
            if let prior, let ids,
               let pending = Self.stablePlan(first:prior,second:current,own:own,expectedApple:apple,
                    identities:ids,runningBundles:Set(applications.map(\.bundle)),desired:desired,previous:previous) {
                let hit = self.hitReader(current,token:token,deadline:ProcessInfo.processInfo.systemUptime+0.4)
                let plan = Self.confirmingRenderedProtection(pending,snapshot:current,hitOwner:hit)
                DispatchQueue.main.async { if !token.isCancelled { completion(plan) } }
                return
            }
            guard attempt < 3, ProcessInfo.processInfo.systemUptime+0.12 < deadline else {
                self.logger.error("preflight incomplete: attempt=\(attempt+1) complete=\(current.complete) entries=\(current.entries.count) identities=\(ids != nil)")
                DispatchQueue.main.async { if !token.isCancelled { completion(nil) } }; return
            }
            self.queue.asyncAfter(deadline:.now()+0.12) { sample(current,attempt:attempt+1) }
        }
        queue.async { sample(nil,attempt:0) }
    }
    func verify(_ plan: MenuBarConcealmentPlan, token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.8
        func check(_ previous: Bool, attempt: Int) {
            guard !token.isCancelled else { return }
            let readDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
            let snapshot = MenuBarInventory.snapshot(token: token, deadline: readDeadline)
            let hit = self.hitReader(snapshot, token:token, deadline:readDeadline)
            let valid = Self.preserves(plan, snapshot:snapshot, hitOwner:hit)
            if valid && previous { DispatchQueue.main.async { if !token.isCancelled { completion(true) } }; return }
            guard attempt < 5, ProcessInfo.processInfo.systemUptime + 0.18 < deadline else {
                self.logger.error("postflight rejected: complete=\(snapshot.complete) protected=\(plan.protected.count) rendered=\(plan.renderedProtected.count)")
                DispatchQueue.main.async { if !token.isCancelled { completion(false) } }; return
            }
            self.queue.asyncAfter(deadline: .now() + 0.18) { check(valid, attempt: attempt + 1) }
        }
        queue.asyncAfter(deadline: .now() + 0.12) { check(false, attempt: 0) }
    }
}
