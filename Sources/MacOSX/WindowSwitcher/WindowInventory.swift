import AppKit
import ApplicationServices

struct SwitcherWindow {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    let applicationName: String
    let icon: NSImage?
    let element: AXUIElement
    let bounds: CGRect
}

struct WindowInventorySnapshot {
    let windows: [SwitcherWindow]
    let focusedID: CGWindowID?
    let mappingAvailable: Bool
}

/// All cross-application AX reads run on this one queue. Observers invalidate the
/// inventory; they never scan from their main-run-loop callback. No polling timer.
final class WindowInventory {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.window-inventory", qos: .userInitiated)
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var scanRevision: UInt64 = 0
    private var focusRevision: UInt64 = 0
    private var active = false
    private var observers: [pid_t: ObserverRegistration] = [:] // queue only
    private var recency: [CGWindowID: UInt64] = [:] // queue only, capped
    private var counter: UInt64 = 0
    var onInvalidation: (() -> Void)? // configured before start, read on main

    private final class ObserverRegistration {
        weak var inventory: WindowInventory?
        let pid: pid_t
        let epoch: UInt64
        let observer: AXObserver
        let application: AXUIElement
        var windows: [CGWindowID: AXUIElement] = [:]
        init(inventory: WindowInventory, pid: pid_t, epoch: UInt64, observer: AXObserver, application: AXUIElement) {
            self.inventory = inventory; self.pid = pid; self.epoch = epoch
            self.observer = observer; self.application = application
        }
    }

    func start() {
        lock.lock(); epoch &+= 1; active = true; lock.unlock()
    }

    func stop() {
        lock.lock(); active = false; epoch &+= 1; scanRevision &+= 1; focusRevision &+= 1; lock.unlock()
        queue.async { [self] in
            let old = Array(observers.values)
            observers.removeAll(); recency.removeAll(); counter = 0
            DispatchQueue.main.async {
                for registration in old {
                    CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
                }
                // `old` retains observer contexts through removal from their run loop.
            }
        }
    }

    private func currentEpoch() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return active ? epoch : nil
    }

    private func isCurrent(_ expectedEpoch: UInt64, revision: UInt64? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && epoch == expectedEpoch && (revision == nil || scanRevision == revision)
    }

    func invalidateScans() {
        lock.lock(); scanRevision &+= 1; focusRevision &+= 1; lock.unlock()
    }

    private func isCurrentFocus(_ expectedEpoch: UInt64, _ revision: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active && epoch == expectedEpoch && focusRevision == revision
    }

    func refresh(frontmostPID: pid_t?, completion: @escaping (WindowInventorySnapshot) -> Void) {
        lock.lock()
        guard active else { lock.unlock(); return }
        let expectedEpoch = epoch
        scanRevision &+= 1
        let revision = scanRevision
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrent(expectedEpoch, revision: revision) else { return }
            let snapshot = self.scan(frontmostPID: frontmostPID, expectedEpoch: expectedEpoch, revision: revision)
            guard self.isCurrent(expectedEpoch, revision: revision) else { return }
            DispatchQueue.main.async { [weak self] in
                guard self?.isCurrent(expectedEpoch, revision: revision) == true else { return }
                completion(snapshot)
            }
        }
    }

    func focus(_ window: SwitcherWindow, completion: @escaping (Bool) -> Void) {
        lock.lock()
        guard active else { lock.unlock(); return }
        let expectedEpoch = epoch
        focusRevision &+= 1
        scanRevision &+= 1 // interrupt a scan before its next AX window read
        let revision = focusRevision
        lock.unlock()
        queue.async { [weak self] in
            guard let self, self.isCurrentFocus(expectedEpoch, revision) else { return }
            // Raise THIS AX element. Application activation is an OS request and
            // may be refused; success here is not proof of foreground focus.
            let raise = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            guard self.isCurrentFocus(expectedEpoch, revision) else { return }
            let activation = NSRunningApplication(processIdentifier: window.pid)?.activate(options: []) ?? false
            // One delayed verification allows the advisory activation request to
            // land. This is a bounded follow-up, not a foreground polling loop.
            self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.isCurrentFocus(expectedEpoch, revision) else { return }
                let app = AXUIElementCreateApplication(window.pid)
                AXUIElementSetMessagingTimeout(app, 0.15)
                let focused = self.attribute(app, kAXFocusedWindowAttribute) as! AXUIElement?
                let focusedID = focused.flatMap { PrivateWindowBridge.windowID(of: $0) }
                let landed = raise == .success && activation && focusedID == window.id
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                DispatchQueue.main.async { [weak self] in
                    guard self?.isCurrentFocus(expectedEpoch, revision) == true else { return }
                    completion(landed)
                }
            }
        }
    }

    func applicationActivated(_ pid: pid_t) {
        guard let expectedEpoch = currentEpoch() else { return }
        recordApplicationFocus(pid, expectedEpoch)
    }

    private func recordApplicationFocus(_ pid: pid_t, _ expectedEpoch: UInt64) {
        queue.async { [weak self] in
            guard let self, self.isCurrent(expectedEpoch) else { return }
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.15)
            if let focused = self.attribute(application, kAXFocusedWindowAttribute),
               let id = PrivateWindowBridge.windowID(of: focused as! AXUIElement) { self.recordFocus(id) }
        }
    }

    private func scan(frontmostPID: pid_t?, expectedEpoch: UInt64, revision: UInt64) -> WindowInventorySnapshot {
        guard PrivateWindowBridge.isAvailable else {
            return WindowInventorySnapshot(windows: [], focusedID: nil, mappingAvailable: false)
        }
        let descriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var visible: [CGWindowID: CGRect] = [:]
        var rank: [CGWindowID: Int] = [:]
        var pids = Set<pid_t>()
        for (index, info) in descriptions.enumerated() {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 0, bounds.height > 0 else { continue }
            visible[id] = bounds; rank[id] = index; pids.insert(pid)
        }
        var result: [SwitcherWindow] = []
        var focusedID: CGWindowID?
        for pid in pids.sorted() {
            guard isCurrent(expectedEpoch, revision: revision) else { break }
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.15)
            let application = NSRunningApplication(processIdentifier: pid)
            let elements = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
            if pid == frontmostPID, let focused = attribute(appElement, kAXFocusedWindowAttribute) {
                focusedID = PrivateWindowBridge.windowID(of: focused as! AXUIElement)
            }
            var observedWindows: [CGWindowID: AXUIElement] = [:]
            for element in elements {
                guard isCurrent(expectedEpoch, revision: revision) else { break }
                AXUIElementSetMessagingTimeout(element, 0.15)
                guard let id = PrivateWindowBridge.windowID(of: element), let bounds = visible[id],
                      attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole,
                      (attribute(element, kAXMinimizedAttribute) as? Bool) != true else { continue }
                observedWindows[id] = element
                let title = attribute(element, kAXTitleAttribute) as? String ?? ""
                result.append(SwitcherWindow(id: id, pid: pid, title: title.isEmpty ? "无标题窗口" : title,
                    applicationName: application?.localizedName ?? "应用", icon: application?.icon,
                    element: element, bounds: bounds))
            }
            updateObserver(pid: pid, application: appElement, windows: observedWindows, expectedEpoch: expectedEpoch)
        }
        if let focusedID, recency[focusedID] == nil { recordFocus(focusedID) }
        result.sort {
            let left = recency[$0.id] ?? 0, right = recency[$1.id] ?? 0
            return left == right ? (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) : left > right
        }
        let absent = Set(observers.keys).subtracting(pids)
        for pid in absent { removeObserver(pid: pid) }
        let liveIDs = Set(result.map(\.id))
        if recency.count > 256 {
            recency = recency.filter { liveIDs.contains($0.key) }
        }
        return WindowInventorySnapshot(windows: result, focusedID: focusedID, mappingAvailable: true)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value
    }

    private func recordFocus(_ id: CGWindowID) {
        counter &+= 1; recency[id] = counter
        if recency.count > 256, let oldest = recency.min(by: { $0.value < $1.value })?.key { recency.removeValue(forKey: oldest) }
    }

    private func updateObserver(pid: pid_t, application: AXUIElement, windows: [CGWindowID: AXUIElement], expectedEpoch: UInt64) {
        if observers[pid]?.epoch != expectedEpoch { removeObserver(pid: pid) }
        if observers[pid] == nil {
            var observer: AXObserver?
            let error = AXObserverCreate(pid, { _, element, notification, context in
                guard let context else { return }
                let registration = Unmanaged<ObserverRegistration>.fromOpaque(context).takeUnretainedValue()
                registration.inventory?.received(element, notification as String, registration.pid, registration.epoch)
            }, &observer)
            guard error == .success, let observer else { return }
            let registration = ObserverRegistration(inventory: self, pid: pid, epoch: expectedEpoch, observer: observer, application: application)
            observers[pid] = registration
            let context = Unmanaged.passUnretained(registration).toOpaque()
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                AXObserverAddNotification(observer, application, name as CFString, context)
            }
            DispatchQueue.main.async { [weak self, registration] in
                guard self?.isCurrent(expectedEpoch) == true else { return }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
            }
        }
        guard let registration = observers[pid] else { return }
        let names = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]
        for (id, element) in registration.windows where windows[id] == nil {
            for name in names { AXObserverRemoveNotification(registration.observer, element, name as CFString) }
        }
        let context = Unmanaged.passUnretained(registration).toOpaque()
        for (id, element) in windows where registration.windows[id] == nil {
            for name in names { AXObserverAddNotification(registration.observer, element, name as CFString, context) }
        }
        registration.windows = windows
    }

    private func removeObserver(pid: pid_t) {
        guard let registration = observers.removeValue(forKey: pid) else { return }
        DispatchQueue.main.async { [registration] in
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(registration.observer), .commonModes)
        }
    }

    private func received(_ element: AXUIElement, _ notification: String, _ pid: pid_t, _ expectedEpoch: UInt64) {
        // An application-level focused-window notification can carry the app
        // element, not the focused window. Read the app attribute off-main.
        if notification == kAXFocusedWindowChangedNotification { recordApplicationFocus(pid, expectedEpoch) }
        queue.async { [weak self] in
            guard let self, self.isCurrent(expectedEpoch) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(expectedEpoch) else { return }
                self.onInvalidation?()
            }
        }
    }
}
