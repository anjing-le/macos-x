import AppKit
import ApplicationServices
import MacOSXCore

struct SwitcherWindow {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let applicationName: String
    let icon: NSImage?
    let element: AXUIElement
    let isMinimized: Bool
}

struct WindowInventorySnapshot {
    let windows: [SwitcherWindow]
    let focusedID: CGWindowID?
    let mappingAvailable: Bool
    let accessibilityTrusted: Bool
    static let empty = Self(windows: [], focusedID: nil, mappingAvailable: true, accessibilityTrusted: true)
}

/// Serial AX I/O, event-driven invalidation, no polling. Main-thread callbacks only publish caches.
final class WindowInventory {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.window-inventory", qos: .userInitiated)
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var scanTicket: UInt64 = 0
    private var focusTicket: UInt64 = 0
    private var active = false
    private var focusReadQueued = false
    private var pendingFocusedPID: pid_t?
    private var observers: [pid_t: Registration] = [:] // worker queue only
    private var cached: [pid_t: [SwitcherWindow]] = [:]
    private var recency = WindowRecency(capacity: 256)
    private var focusedID: CGWindowID?
    var onInvalidation: (() -> Void)? // configured before start, invoked on main
    var onConfirmedFocus: ((CGWindowID) -> Void)?

    private final class Registration {
        weak var inventory: WindowInventory?
        let pid: pid_t
        let epoch: UInt64
        let observer: AXObserver
        let application: AXUIElement
        var windows: [CGWindowID: AXUIElement] = [:]
        init(_ inventory: WindowInventory, _ pid: pid_t, _ epoch: UInt64, _ observer: AXObserver, _ app: AXUIElement) {
            self.inventory = inventory; self.pid = pid; self.epoch = epoch
            self.observer = observer; application = app
        }
    }

    deinit { Self.detach(Array(observers.values)) }

    func start() {
        lock.lock(); epoch &+= 1; active = true; focusReadQueued = false; pendingFocusedPID = nil; lock.unlock()
    }

    func stop() {
        lock.lock(); active = false; epoch &+= 1; scanTicket &+= 1; focusTicket &+= 1; pendingFocusedPID = nil; lock.unlock()
        queue.async { [self] in
            let old = Array(observers.values)
            observers.removeAll(); cached.removeAll(); recency = WindowRecency(); focusedID = nil
            Self.detach(old)
        }
    }

    func invalidateScans() {
        lock.lock(); scanTicket &+= 1; lock.unlock()
    }

    private func valid(_ expected: UInt64, scan: UInt64? = nil, focus: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && epoch == expected && (scan == nil || scanTicket == scan) && (focus == nil || focusTicket == focus)
    }

    func refresh(frontmostPID: pid_t?, completion: @escaping (WindowInventorySnapshot) -> Void) {
        lock.lock(); guard active else { lock.unlock(); return }
        let generation = epoch; scanTicket &+= 1; let ticket = scanTicket; lock.unlock()
        queue.async { [weak self] in
            guard let self, self.valid(generation, scan: ticket) else { return }
            let result = self.scan(frontmostPID: frontmostPID, generation: generation, ticket: ticket)
            guard self.valid(generation, scan: ticket) else { return }
            DispatchQueue.main.async { [weak self] in
                guard self?.valid(generation, scan: ticket) == true else { return }
                completion(result)
            }
        }
    }

    func applicationActivated(_ pid: pid_t) {
        lock.lock(); guard active else { lock.unlock(); return }
        pendingFocusedPID = pid
        guard !focusReadQueued else { lock.unlock(); return }
        focusReadQueued = true; let generation = epoch; lock.unlock()
        // At most one pending focus observation plus the one currently reading AX.
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            guard self.active, self.epoch == generation, let latestPID = self.pendingFocusedPID else { self.lock.unlock(); return }
            self.focusReadQueued = false; self.lock.unlock()
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == latestPID else { return }
            let app = AXUIElementCreateApplication(latestPID)
            AXUIElementSetMessagingTimeout(app, 0.15)
            if let element = self.elementAttribute(app, kAXFocusedWindowAttribute),
               let id = PrivateWindowBridge.windowID(of: element),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == latestPID {
                self.confirmFocus(id, generation: generation)
            }
        }
    }

    /// Public AX restore/raise plus application activation, then bounded actual-focus verification.
    func focus(_ window: SwitcherWindow, completion: @escaping (Bool) -> Void) {
        lock.lock(); guard active else { lock.unlock(); return }
        let generation = epoch; focusTicket &+= 1; scanTicket &+= 1; let ticket = focusTicket; lock.unlock()
        queue.async { [weak self] in
            guard let self, self.valid(generation, focus: ticket) else { return }
            guard AXIsProcessTrusted() else { self.deliverFocus(false, generation, ticket, completion); return }
            AXUIElementSetMessagingTimeout(window.element, 0.15)
            if self.attribute(window.element, kAXMinimizedAttribute) as? Bool == true {
                guard self.valid(generation, focus: ticket) else { return }
                guard AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                    self.deliverFocus(false, generation, ticket, completion); return
                }
            }
            guard self.valid(generation, focus: ticket), let application = NSRunningApplication(processIdentifier: window.pid), !application.isTerminated else {
                self.deliverFocus(false, generation, ticket, completion); return
            }
            _ = application.activate(options: [])
            let app = AXUIElementCreateApplication(window.pid)
            AXUIElementSetMessagingTimeout(app, 0.15)
            guard self.valid(generation, focus: ticket) else { return }
            _ = AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window.element)
            guard self.valid(generation, focus: ticket) else { return }
            _ = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            self.queue.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self, self.valid(generation, focus: ticket) else { return }
                let focused = self.elementAttribute(app, kAXFocusedWindowAttribute)
                let landed = focused.flatMap { PrivateWindowBridge.windowID(of: $0) } == window.id
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                if landed { self.confirmFocus(window.id, generation: generation) }
                self.deliverFocus(landed, generation, ticket, completion)
            }
        }
    }

    private func deliverFocus(_ result: Bool, _ generation: UInt64, _ ticket: UInt64, _ completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard self?.valid(generation, focus: ticket) == true else { return }
            completion(result)
        }
    }

    private func confirmFocus(_ id: CGWindowID, generation: UInt64) {
        guard valid(generation) else { return }
        focusedID = id; recency.recordFocus(id)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.valid(generation) else { return }
            self.onConfirmedFocus?(id)
        }
    }

    private func scan(frontmostPID: pid_t?, generation: UInt64, ticket: UInt64) -> WindowInventorySnapshot {
        guard AXIsProcessTrusted() else {
            return .init(windows: [], focusedID: nil, mappingAvailable: PrivateWindowBridge.isAvailable, accessibilityTrusted: false)
        }
        guard PrivateWindowBridge.isAvailable else {
            return .init(windows: [], focusedID: nil, mappingAvailable: false, accessibilityTrusted: true)
        }
        // Only WindowServer metadata; no pixels, screenshot APIs or screen-recording permission.
        let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var visible = Set<CGWindowID>(); var rank: [CGWindowID: Int] = [:]; var visiblePIDs = Set<pid_t>()
        for (index, info) in descriptions.prefix(2048).enumerated() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32 else { continue }
            visible.insert(id); rank[id] = index; visiblePIDs.insert(pid)
        }
        let applications = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated && !$0.isHidden

        }.sorted {
            if $0.processIdentifier == frontmostPID && $1.processIdentifier != frontmostPID { return true }
            if $1.processIdentifier == frontmostPID { return false }
            let l = visiblePIDs.contains($0.processIdentifier), r = visiblePIDs.contains($1.processIdentifier)
            return l == r ? $0.processIdentifier < $1.processIdentifier : l
        }
        let eligible = Array(applications.prefix(64))
        let pids = Set(eligible.map(\.processIdentifier))
        for pid in Set(observers.keys).subtracting(pids) { removeObserver(pid) }
        cached = cached.filter { pids.contains($0.key) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var currentFocusedID: CGWindowID?
        for application in eligible {
            guard valid(generation, scan: ticket), ProcessInfo.processInfo.systemUptime < deadline else { break }
            let pid = application.processIdentifier
            let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.15)
            guard let elements = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            var windows = [SwitcherWindow](); var observed = [CGWindowID: AXUIElement](); var complete = true
            for element in elements.prefix(40) {
                guard valid(generation, scan: ticket), ProcessInfo.processInfo.systemUptime < deadline else { complete = false; break }
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard let id = PrivateWindowBridge.windowID(of: element) else { continue }
                // One AX round trip for these window properties, rather than four on a slow app.
                var properties: CFArray?
                let names = [kAXSubroleAttribute, kAXRoleAttribute, kAXMinimizedAttribute, kAXTitleAttribute] as CFArray
                guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &properties) == .success,
                      let values = properties as? [Any], values.count == 4 else { continue }
                let subrole = values[0] as? String
                guard subrole == kAXStandardWindowSubrole || (subrole == nil && values[1] as? String == kAXWindowRole) else { continue }
                let minimized = values[2] as? Bool == true
                guard minimized || visible.contains(id) else { continue }
                observed[id] = element
                let rawTitle = values[3] as? String ?? ""
                let name = application.localizedName ?? "应用"
                windows.append(.init(id: id, pid: pid, title: String((rawTitle.isEmpty ? name : rawTitle).prefix(200)),
                    applicationName: name, icon: application.icon, element: element, isMinimized: minimized))
            }
            guard valid(generation, scan: ticket) else { break }
            if !complete {
                let discovered = Set(windows.map(\.id))
                windows += (cached[pid] ?? []).filter { !discovered.contains($0.id) }
                for window in windows { observed[window.id] = window.element }
            }
            cached[pid] = windows
            updateObserver(pid: pid, application: app, windows: observed, generation: generation)
            if pid == frontmostPID, let focused = elementAttribute(app, kAXFocusedWindowAttribute),
               let id = PrivateWindowBridge.windowID(of: focused),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                currentFocusedID = id
                if id != focusedID { confirmFocus(id, generation: generation) }
            }
        }
        let baseline = cached.values.flatMap { $0 }.sorted {
            let left = rank[$0.id] ?? Int.max, right = rank[$1.id] ?? Int.max
            return left == right ? $0.id < $1.id : left < right
        }
        let byID = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = Array(recency.ordered(availableIDs: baseline.map(\.id)).prefix(256))
        let live = Set(order)
        recency.retain(liveIDs: order)
        for pid in Array(cached.keys) {
            cached[pid] = cached[pid]?.filter { live.contains($0.id) }
            if let registration = observers[pid] {
                updateObserver(pid: pid, application: registration.application,
                    windows: registration.windows.filter { live.contains($0.key) }, generation: generation)
            }
        }
        return .init(windows: order.compactMap { byID[$0] }, focusedID: currentFocusedID, mappingAvailable: true, accessibilityTrusted: true)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func elementAttribute(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func updateObserver(pid: pid_t, application: AXUIElement, windows: [CGWindowID: AXUIElement], generation: UInt64) {
        if observers[pid]?.epoch != generation { removeObserver(pid) }
        if observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, element, notification, context in
                guard let context else { return }
                let registration = Unmanaged<Registration>.fromOpaque(context).takeUnretainedValue()
                guard let inventory = registration.inventory, inventory.valid(registration.epoch) else { return }
                inventory.received(element, notification as String, registration)

            }, &observer) == .success, let observer else { return }
            let registration = Registration(self, pid, generation, observer, application)
            observers[pid] = registration
            let context = Unmanaged.passUnretained(registration).toOpaque()
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                AXObserverAddNotification(observer, application, name as CFString, context)
            }
            DispatchQueue.main.async { [weak self, registration] in
                guard self?.valid(generation) == true else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
            }
        }
        guard let registration = observers[pid] else { return }
        let names = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
        for (id, element) in registration.windows where windows[id] == nil {
            guard valid(generation) else { return }
            for name in names { AXObserverRemoveNotification(registration.observer, element, name as CFString) }
        }
        let context = Unmanaged.passUnretained(registration).toOpaque()
        for (id, element) in windows where registration.windows[id] == nil {
            guard valid(generation) else { return }
            for name in names { AXObserverAddNotification(registration.observer, element, name as CFString, context) }
        }
        registration.windows = windows
    }

    private func received(_ element: AXUIElement, _ notification: String, _ registration: Registration) {
        if notification == kAXFocusedWindowChangedNotification || notification == kAXMainWindowChangedNotification {
            applicationActivated(registration.pid)
        }
        queue.async { [weak self, registration] in
            guard let self, self.valid(registration.epoch) else { return }
            if notification == kAXUIElementDestroyedNotification,
               let id = registration.windows.first(where: { CFEqual($0.value, element) })?.key {
                self.cached[registration.pid]?.removeAll { $0.id == id }
                let live = self.cached.values.flatMap { $0 }.map(\.id)
                self.recency.retain(liveIDs: live)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.valid(registration.epoch) else { return }
                self.onInvalidation?()
            }
        }
    }

    private func removeObserver(_ pid: pid_t) {
        guard let registration = observers.removeValue(forKey: pid) else { return }
        Self.detach([registration])
    }

    private static func detach(_ registrations: [Registration]) {
        DispatchQueue.main.async {
            for registration in registrations {
                let source = AXObserverGetRunLoopSource(registration.observer)
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                CFRunLoopSourceInvalidate(source)
            }
        }
    }
}
