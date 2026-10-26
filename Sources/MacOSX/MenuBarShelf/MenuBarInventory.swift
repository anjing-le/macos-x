import AppKit
import ApplicationServices
import Darwin

struct MenuBarEntry {
    let bundle: String
    let frame: CGRect
    var element: AXUIElement? = nil
    var pid: pid_t = 0
    var visible = true
    // Geometry and pixels must come from the same compositor surface. The
    // owning app's AX coordinates alone cannot identify that surface on 27.
    var surface: CGRect? = nil
    var surfaceID: CGWindowID? = nil
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

final class MenuBarReadToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct MenuBarContainer {
    let pid: pid_t
    let frame: CGRect
    var surface: CGRect? = nil
    var surfaceID: CGWindowID? = nil
}

struct MenuBarContainerSnapshot {
    let entries: [MenuBarContainer]
    let complete: Bool
}

/// Same optional AX-to-window mapping used by the window switcher. Keeping it
/// local makes shelf capture independent of whether that module is installed.
private enum MenuBarSurfaceIdentity {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let function: GetWindow? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindow.self)
    }()
    static func windowID(_ element: AXUIElement) -> CGWindowID? {
        guard let function else { return nil }
        var id: CGWindowID = 0
        return function(element, &id) == .success && id != 0 ? id : nil
    }
}

/// On macOS 27 app-provided AX frames can survive native hiding/reflow.
/// MenuBarAgent's on-screen containers are authoritative for image geometry.
enum MenuBarContainerGeometry {
    static func reconcile(_ entries: [MenuBarEntry], containers: [MenuBarContainer], surfaceID: CGWindowID? = nil) -> [MenuBarEntry] {
        entries.map { entry in
            let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
            let matches = containers.filter {
                $0.pid == entry.pid && $0.frame.minX.isFinite && $0.frame.minY.isFinite
                    && $0.frame.width > 0 && $0.frame.width <= 320 && $0.frame.height > 0 && $0.frame.height <= 80
                    && (surfaceID != nil ? $0.surfaceID == surfaceID : ($0.surface?.contains(center) ?? (abs($0.frame.midY - entry.frame.midY) <= 80)))
            }
            // A PID may own several status items. Picking the nearest one from
            // stale AX coordinates can turn a neighbour into this app's icon.
            // Until individual items can be identified, leave ambiguity native.
            let unique = matches.reduce(into: [MenuBarContainer]()) { values, value in
                if !values.contains(where: { $0.frame == value.frame && $0.surface == value.surface && $0.surfaceID == value.surfaceID }) { values.append(value) }
            }
            guard unique.count == 1, let match = unique.first else {
                return MenuBarEntry(bundle: entry.bundle, frame: entry.frame, element: entry.element, pid: entry.pid, visible: false)
            }
            // Overflow proxies can report several remote owners in overlapping
            // rectangles. They are not the original widgets and must not be
            // cropped or treated as independent drag targets.
            guard !containers.contains(where: {
                $0.pid != match.pid && $0.surfaceID == match.surfaceID && $0.surface == match.surface
                    && $0.frame.intersection(match.frame).width > 0.5 && $0.frame.intersection(match.frame).height > 0.5
            }) else { return MenuBarEntry(bundle: entry.bundle, frame: entry.frame, element: entry.element, pid: entry.pid, visible: false) }
            return MenuBarEntry(bundle: entry.bundle, frame: match.frame, element: entry.element, pid: entry.pid, surface: match.surface, surfaceID: match.surfaceID)
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
            let watch = MenuBarMenuWatch(pid: entry.pid, item: element, onClosed: onClosed)
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
    static func containers(token: MenuBarReadToken, deadline: TimeInterval,
                           surfaceID requestedSurface: CGWindowID? = nil, owners: Set<pid_t>? = nil) -> [MenuBarContainer] {
        snapshot(token: token, deadline: deadline, surfaceID: requestedSurface, owners: owners).entries
    }
    static func snapshot(token: MenuBarReadToken, deadline: TimeInterval,
                         surfaceID requestedSurface: CGWindowID? = nil, owners: Set<pid_t>? = nil) -> MenuBarContainerSnapshot {
        var result: [MenuBarContainer] = []
        var complete = true
        func children(_ element: AXUIElement, _ key: String) -> [AXUIElement] {
            guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { complete = false; return [] }
            AXUIElementSetMessagingTimeout(element, 0.035)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
                  let values = value as? [AXUIElement] else { complete = false; return [] }
            if values.count >= 128 { complete = false }
            return Array(values.prefix(128))
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { complete = false; return nil }
            AXUIElementSetMessagingTimeout(element, 0.035)
            var p: CFTypeRef?, s: CFTypeRef?, point = CGPoint.zero, size = CGSize.zero
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID(),
                  AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point),
                  AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size),
                  point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite else { complete = false; return nil }
            return CGRect(origin: point, size: size)
        }
        for agent in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").prefix(2) {
            let app = AXUIElementCreateApplication(agent.processIdentifier)
            for window in children(app, kAXWindowsAttribute) {
                guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return .init(entries: result, complete: false) }
                AXUIElementSetMessagingTimeout(window, 0.035)
                let surfaceID = MenuBarSurfaceIdentity.windowID(window)
                if let requestedSurface, surfaceID != requestedSurface { continue }
                guard let area = frame(window), area.height > 0, area.height <= 80 else { continue }
                for group in children(window, kAXChildrenAttribute) {
                    guard !token.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, result.count < 256 else { return .init(entries: result, complete: false) }
                    AXUIElementSetMessagingTimeout(group, 0.035)
                    for child in children(group, kAXChildrenAttribute) {
                        var pid: pid_t = 0
                        guard AXUIElementGetPid(child, &pid) == .success, pid > 0, pid != agent.processIdentifier else { continue }
                        if let owners, !owners.contains(pid) { break }
                        guard let rect = frame(group), rect.width > 0, rect.width <= 320, rect.height > 0, rect.height <= 80, area.contains(rect) else { break }
                        result.append(MenuBarContainer(pid: pid, frame: rect, surface: area, surfaceID: surfaceID)); break
                    }
                }
            }
        }
        return .init(entries: result, complete: complete && !token.isCancelled && ProcessInfo.processInfo.systemUptime < deadline)
    }
}

/// A submenu closing cannot close its still-selected parent menu.
struct MenuBarMenuSelection {
    private(set) var sawSelected = false
    private var closed = false
    mutating func receive(_ selected: Bool?, closedNotification: Bool = false) -> Bool {
        guard !closed else { return false }
        if selected == true { sawSelected = true }
        if (sawSelected && selected == false) || (closedNotification && selected != true) { closed = true; return true }
        return false
    }
}

/// One scoped observer, with selection checks triggered only by menu/user events.
/// AX messages stay off the UI thread; no menu-state polling or hide timer.
final class MenuBarMenuWatch {
    private var observer: AXObserver?
    private let app: AXUIElement
    private let item: AXUIElement
    private let onClosed: () -> Void
    private let requireConfirmedDeselection: Bool
    private var notifications: [String] = []
    private var localMonitor: Any?, globalMonitor: Any?
    private var attached = false
    private let lock = NSLock()
    private var cancelled = false, notified = false, checking = false, closePending = false, selectionPending = false
    private var selection = MenuBarMenuSelection()
    private static let cleanup = DispatchQueue(label: "cc.anjing.macos-x.menu-watch-cleanup")
    init?(pid: pid_t, item: AXUIElement, requireConfirmedDeselection: Bool = false, onClosed: @escaping () -> Void) {
        guard pid > 0 else { return nil }
        self.requireConfirmedDeselection = requireConfirmedDeselection
        app = AXUIElementCreateApplication(pid); self.item = item; self.onClosed = onClosed
        AXUIElementSetMessagingTimeout(app, 0.1); AXUIElementSetMessagingTimeout(item, 0.1)
        var raw: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            let watch = Unmanaged<MenuBarMenuWatch>.fromOpaque(context).takeUnretainedValue()
            if notification as String == kAXMenuClosedNotification { watch.checkSelection(menuClosed: true) }
            else { watch.checkSelection() }
        }, &raw) == .success, let raw else { return nil }
        observer = raw
        for name in [kAXMenuClosedNotification, kAXMenuOpenedNotification, kAXSelectedChildrenChangedNotification] {
            if AXObserverAddNotification(raw, app, name as CFString, Unmanaged.passUnretained(self).toOpaque()) == .success { notifications.append(name) }
        }
        guard !notifications.isEmpty else { observer = nil; return nil }
    }
    func attach() {
        lock.lock(); let canAttach = !cancelled && !notified; lock.unlock()
        guard canAttach, let observer else { return }
        attached = true
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        checkSelection()
    }
    private func notifyClosed() {
        lock.lock(); let deliver = !cancelled && !notified; if deliver { notified = true }; lock.unlock()
        if deliver { onClosed() }
    }
    private func checkSelection(menuClosed: Bool = false) {
        lock.lock()
        closePending = closePending || menuClosed
        guard !cancelled, !notified else { lock.unlock(); return }
        if checking { selectionPending = true; lock.unlock(); return }
        checking = true; selectionPending = false
        let closeEvent = closePending; closePending = false; lock.unlock()
        Self.cleanup.async { [self] in
            lock.lock(); let canRead = !cancelled && !notified; lock.unlock()
            var value: CFTypeRef?
            let selected: Bool? = canRead && AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &value) == .success
                ? (value as? NSNumber)?.boolValue : nil
            lock.lock(); checking = false
            let closed = !cancelled && selection.receive(selected, closedNotification: closeEvent && !requireConfirmedDeselection)
            let repeatSelection = !cancelled && !notified && (closePending || selectionPending)
            let observedMenu = !cancelled && !notified && selection.sawSelected
            lock.unlock()
            if closed { notifyClosed() }
            else {
                if observedMenu { DispatchQueue.main.async { [weak self] in self?.installSelectionMonitors() } }
                if repeatSelection { checkSelection() }
            }
        }
    }
    /// Install only after AX confirmed a selected native menu. A custom popover
    /// with no selection signal never gains a keyboard/mouse watcher or timeout.
    private func installSelectionMonitors() {
        lock.lock(); let canWatch = !cancelled && !notified; lock.unlock()
        guard canWatch, attached, localMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .rightMouseUp, .keyUp]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.checkSelection(); return event }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.checkSelection() }
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock(); attached = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
        guard let observer else { return }; self.observer = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        let app = app, notifications = notifications
        Self.cleanup.async { for name in notifications { AXObserverRemoveNotification(observer, app, name as CFString) } }
    }
    deinit { cancel() }
}
