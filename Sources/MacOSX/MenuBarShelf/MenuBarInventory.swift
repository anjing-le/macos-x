import AppKit
import ApplicationServices

struct MenuBarEntry {
    let bundle: String
    let frame: CGRect
    var element: AXUIElement? = nil
    var pid: pid_t = 0
    var visible = true
}

/// Failed/unreadable applications remain allowed. A partial inventory must not
/// silently hide an app the user left on the visible side of the boundary.
enum MenuBarSections {
    static let systemOwners: Set<String> = ["com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver"]
    static func hidden(_ entries: [MenuBarEntry], boundary: CGRect, leftToRight: Bool) -> Set<String> {
        var hidden = Set<String>(), visible = systemOwners
        for entry in entries {
            guard !entry.bundle.isEmpty, entry.frame.width > 0, entry.frame.height > 0,
                  entry.frame.midX.isFinite, entry.frame.midY.isFinite,
                  entry.frame.midY >= boundary.minY - 8, entry.frame.midY <= boundary.maxY + 8 else { continue }
            let isHidden = leftToRight ? entry.frame.midX < boundary.midX : entry.frame.midX > boundary.midX
            if isHidden { hidden.insert(entry.bundle) } else { visible.insert(entry.bundle) }
        }
        return hidden.subtracting(visible)
    }
}

final class MenuBarReadToken {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct MenuBarContainer {
    let pid: pid_t
    let frame: CGRect
    var surface: CGRect? = nil
}

/// On macOS 27 app-provided AX frames can survive native hiding/reflow.
/// MenuBarAgent's on-screen containers are authoritative for image geometry.
enum MenuBarContainerGeometry {
    static func reconcile(_ entries: [MenuBarEntry], containers: [MenuBarContainer]) -> [MenuBarEntry] {
        entries.map { entry in
            let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
            let matches = containers.filter {
                $0.pid == entry.pid && $0.frame.minX.isFinite && $0.frame.minY.isFinite
                    && $0.frame.width > 0 && $0.frame.width <= 320 && $0.frame.height > 0 && $0.frame.height <= 80
                    && ($0.surface?.contains(center) ?? (abs($0.frame.midY - entry.frame.midY) <= 80))
            }
            let nearest = matches.min { a, b in
                hypot(a.frame.midX - entry.frame.midX, (a.frame.midY - entry.frame.midY) * 16)
                    < hypot(b.frame.midX - entry.frame.midX, (b.frame.midY - entry.frame.midY) * 16)
            }
            guard let nearest else { return MenuBarEntry(bundle: entry.bundle, frame: entry.frame, element: entry.element, pid: entry.pid, visible: false) }
            return MenuBarEntry(bundle: entry.bundle, frame: nearest.frame, element: entry.element, pid: entry.pid)
        }
    }
}

/// One serial worker; one explicit collapse = at most 3 seconds / 128 apps /
/// 64 items per app. Nothing reads AX on the status-item event callback.
final class MenuBarInventory {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.menu-bar-inventory", qos: .userInitiated)
    func press(_ entry: MenuBarEntry, token: MenuBarReadToken, onClosed: @escaping () -> Void,
               completion: @escaping (Bool, MenuBarMenuWatch?) -> Void) {
        queue.async {
            guard !token.isCancelled, let element = entry.element else {
                DispatchQueue.main.async { if !token.isCancelled { completion(false, nil) } }; return
            }
            AXUIElementSetMessagingTimeout(element, 0.15)
            let watch = MenuBarMenuWatch(pid: entry.pid, onClosed: onClosed)
            guard !token.isCancelled else { watch?.cancel(); return }
            let ok = AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            DispatchQueue.main.async {
                guard !token.isCancelled else { watch?.cancel(); return }
                if ok { watch?.attach() } else { watch?.cancel() }
                completion(ok, ok ? watch : nil)
            }
        }
    }
    func read(_ apps: [(pid_t, String)], token: MenuBarReadToken, completion: @escaping ([MenuBarEntry]) -> Void) {
        queue.async {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            let compositor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
            let appDeadline = compositor ? deadline - 1 : deadline
            var entries: [MenuBarEntry] = []
            for (pid, bundle) in apps.prefix(128) {
                guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < appDeadline else { break }
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.035)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
                let bar = unsafeBitCast(value, to: AXUIElement.self)
                AXUIElementSetMessagingTimeout(bar, 0.035)
                var children: CFArray?
                guard AXUIElementCopyAttributeValues(bar, kAXChildrenAttribute as CFString, 0, 64, &children) == .success,
                      let items = children as? [AXUIElement] else { continue }
                var appEntries: [MenuBarEntry] = []
                var complete = true
                for item in items {
                    guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < appDeadline else { complete = false; break }
                    AXUIElementSetMessagingTimeout(item, 0.035)
                    var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &positionValue) == .success,
                          AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &sizeValue) == .success,
                          let positionValue, let sizeValue,
                          CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { complete = false; break }
                    var point = CGPoint.zero, size = CGSize.zero
                    guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &point),
                          AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { complete = false; break }
                    guard point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
                          size.width > 0, size.height > 0 else { complete = false; break }
                    appEntries.append(.init(bundle: bundle, frame: CGRect(origin: point, size: size), element: item, pid: pid))
                }
                // Refuse to classify a bundle if a sibling item could not be read.
                if complete, items.count < 64 { entries += appEntries }
            }
            if compositor {
                let containers = Self.containers(token: token, deadline: deadline)
                entries = MenuBarContainerGeometry.reconcile(entries, containers: containers)
            }
            guard !token.isCancelled else { return }
            let result = entries
            DispatchQueue.main.async { if !token.isCancelled { completion(result) } }
        }
    }
    static func containers(token: MenuBarReadToken, deadline: TimeInterval) -> [MenuBarContainer] {
        var result: [MenuBarContainer] = []
        func children(_ element: AXUIElement, _ key: String) -> [AXUIElement] {
            guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return [] }
            AXUIElementSetMessagingTimeout(element, 0.035)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return [] }
            return Array((value as? [AXUIElement] ?? []).prefix(128))
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.035)
            var p: CFTypeRef?, s: CFTypeRef?, point = CGPoint.zero, size = CGSize.zero
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
                  AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { return nil }
            return CGRect(origin: point, size: size)
        }
        for agent in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").prefix(2) {
            let app = AXUIElementCreateApplication(agent.processIdentifier)
            for window in children(app, kAXWindowsAttribute) {
                guard let area = frame(window), area.height > 0, area.height <= 80 else { continue }
                for group in children(window, kAXChildrenAttribute) {
                    guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, result.count < 256 else { return result }
                    AXUIElementSetMessagingTimeout(group, 0.035)
                    guard let rect = frame(group), rect.width > 0, rect.width <= 320, rect.height > 0, rect.height <= 80, area.contains(rect) else { continue }
                    for child in children(group, kAXChildrenAttribute) {
                        var pid: pid_t = 0
                        guard AXUIElementGetPid(child, &pid) == .success, pid > 0, pid != agent.processIdentifier else { continue }
                        result.append(MenuBarContainer(pid: pid, frame: rect, surface: area)); break
                    }
                }
            }
        }
        return result
    }
}

/// One observer scoped to the currently opened real menu. Registration and
/// teardown AX messages stay off the UI thread. No menu-state polling.
final class MenuBarMenuWatch {
    private var observer: AXObserver?
    private let app: AXUIElement
    private let onClosed: () -> Void
    private static let cleanup = DispatchQueue(label: "cc.anjing.macos-x.menu-watch-cleanup")
    init?(pid: pid_t, onClosed: @escaping () -> Void) {
        guard pid > 0 else { return nil }
        app = AXUIElementCreateApplication(pid); self.onClosed = onClosed
        AXUIElementSetMessagingTimeout(app, 0.1)
        var raw: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let watch = Unmanaged<MenuBarMenuWatch>.fromOpaque(context).takeUnretainedValue()
            watch.onClosed()
        }, &raw) == .success, let raw else { return nil }
        observer = raw
        guard AXObserverAddNotification(raw, app, kAXMenuClosedNotification as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success else { observer = nil; return nil }
    }
    func attach() { if let observer { CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) } }
    func cancel() {
        guard let observer else { return }; self.observer = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let app = app
        Self.cleanup.async { AXObserverRemoveNotification(observer, app, kAXMenuClosedNotification as CFString) }
    }
    deinit { cancel() }
}
