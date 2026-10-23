import AppKit
@preconcurrency import ScreenCaptureKit

/// Keep the gesture the user performed, rather than substituting AXPress or
/// opening the application. A double click contains both down/up pairs.
struct MenuBarPointerSample {
    let type: CGEventType
    let button: CGMouseButton
    let count: Int64
    let flags: CGEventFlags
    let timestamp: TimeInterval
    init(_ event: NSEvent) {
        type = event.cgEvent?.type ?? .leftMouseUp
        button = CGMouseButton(rawValue: UInt32(max(0, event.buttonNumber))) ?? .left
        count = Int64(event.clickCount)
        flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue))
        timestamp = event.timestamp
    }
    init(type: CGEventType, button: CGMouseButton = .left, count: Int64 = 1,
         flags: CGEventFlags = [], timestamp: TimeInterval) {
        self.type = type; self.button = button; self.count = count; self.flags = flags; self.timestamp = timestamp
    }
    static var singleClick: [Self] {
        [.init(type: .leftMouseDown, timestamp: 0), .init(type: .leftMouseUp, timestamp: 0.04)]
    }
    static func valid(_ samples: [Self]) -> Bool {
        guard !samples.isEmpty, samples.count <= 8, samples.count.isMultiple(of: 2),
              let first = samples.first, let last = samples.last,
              first.timestamp.isFinite, first.timestamp >= 0, last.timestamp - first.timestamp <= 3 else { return false }
        var previous = first.timestamp
        for pair in stride(from: 0, to: samples.count, by: 2) {
            let down = samples[pair], up = samples[pair + 1]
            let expected: CGEventType = down.type == .leftMouseDown ? .leftMouseUp
                : down.type == .rightMouseDown ? .rightMouseUp : .otherMouseUp
            guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(down.type), up.type == expected,
                  down.button == up.button, down.count == up.count, down.count > 0,
                  down.timestamp.isFinite, up.timestamp.isFinite,
                  down.timestamp >= previous, up.timestamp >= down.timestamp else { return false }
            previous = up.timestamp
        }
        return true
    }
}

/// Only a user activation creates these short-lived stills. They cover the
/// menu-bar reflow while macOS briefly makes the real native input surface
/// available. No menu is mirrored; the owning app handles the original events.
@MainActor final class MenuBarNativeInteraction {
    private var panels: [NSPanel] = []
    private var baseline: [MenuBarContainer] = []
    private var originals: [(CGRect, CGImage)] = []
    private var current: MenuBarReadToken?
    private var delivery: DispatchWorkItem?
    private var pressed: (CGPoint, MenuBarPointerSample)?
    private var returnPoint: CGPoint?
    private var relayPoint: CGPoint?
    private var eventSource: CGEventSource?
    private var settling: MenuBarReadToken?
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.native-menu-input", qos: .userInitiated)
    var coverCount: Int { panels.count }
    var coverRects: [CGRect] {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return panels.map { CGRect(x: $0.frame.minX, y: top - $0.frame.maxY, width: $0.frame.width, height: $0.frame.height) }
    }
    var captureOverride: ((MenuBarReadToken, @escaping (Bool) -> Void) -> Void)?
    var sendOverride: ((CGEventType, CGPoint, MenuBarPointerSample?) -> Void)?
    func prepare(token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        cancel(); current = token
        if let captureOverride { captureOverride(token, completion); return }
        guard CGPreflightScreenCaptureAccess(), NSScreen.screens.count <= 8 else { completion(false); return }
        let screens = NSScreen.screens.map { screen in
            (screen.frame, (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
             max(24, min(80, screen.frame.maxY - screen.visibleFrame.maxY)))
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                guard let content else { completion(false); return }
                self.capture(screens, content: content, index: 0, bytes: 0, token: token, completion: completion)
            }
        }
    }
    private func capture(_ screens: [(CGRect, CGDirectDisplayID, CGFloat)], content: SCShareableContent,
                         index: Int, bytes: Int, token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        guard !token.isCancelled else { return }
        guard index < screens.count else {
            // Commit the opaque stills before allowing any native reflow.
            queue.async {
                let baseline = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.4)
                DispatchQueue.main.async { [weak self] in
                    guard let self, !token.isCancelled else { return }; self.baseline = baseline
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { if !token.isCancelled { completion(true) } }
                }
            }
            return
        }
        let (frame, id, nominalHeight) = screens[index]
        guard let display = content.displays.first(where: { $0.displayID == id }) else { completion(false); return }
        let nativeHeight = content.windows.filter {
            $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent"
                && (20...30).contains($0.windowLayer) && $0.frame.height > 0 && $0.frame.height <= 80
                && display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }.map(\.frame.height).max() ?? 0
        let height = max(nominalHeight, nativeHeight)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let scale = max(1, min(3, CGFloat(filter.pointPixelScale)))
        let config = SCStreamConfiguration(); config.showsCursor = false; config.capturesAudio = false
        config.sourceRect = CGRect(x: 0, y: 0, width: display.frame.width, height: height)
        config.width = max(1, Int(display.frame.width * scale)); config.height = max(1, Int(height * scale))
        let cost = config.width * config.height * 4
        guard config.width <= 49_152, bytes + cost <= 16_000_000 else { completion(false); return }
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, _ in
            DispatchQueue.main.async {
                guard let self, !token.isCancelled else { return }
                guard let image else { completion(false); return }
                let imageCost = image.bytesPerRow * image.height
                guard bytes + imageCost <= 16_000_000 else { completion(false); return }
                let rect = CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
                let panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                panel.isOpaque = true; panel.backgroundColor = .black; panel.ignoresMouseEvents = true
                panel.hasShadow = false; panel.animationBehavior = .none
                panel.isReleasedWhenClosed = false
                panel.setAccessibilityHidden(true)
                let view = NSImageView(frame: CGRect(origin: .zero, size: rect.size))
                view.setAccessibilityHidden(true)
                view.image = NSImage(cgImage: image, size: rect.size); view.imageScaling = .scaleAxesIndependently
                panel.contentView = view; panel.orderFrontRegardless(); panel.displayIfNeeded(); self.panels.append(panel)
                self.originals.append((rect, image))
                self.capture(screens, content: content, index: index + 1, bytes: bytes + imageCost, token: token, completion: completion)
            }
        }
    }
    func restoreFullCovers() -> [CGRect] {
        for (index, panel) in panels.enumerated() where index < originals.count {
            let (frame, image) = originals[index]
            if let view = panel.contentView as? NSImageView {
                view.image = NSImage(cgImage: image, size: frame.size); view.frame.size = frame.size
            }
            panel.setFrame(frame, display: true)
        }
        return coverRects
    }
    /// Once reflow is known, leave the unchanged right-hand system controls
    /// and clock native/live. Only the portion that actually changed is masked.
    func revealStableSuffix(owners: Set<pid_t>, token: MenuBarReadToken, completion: @escaping ([CGRect]) -> Void) {
        if captureOverride != nil { completion(coverRects); return }
        queue.async {
            let containers = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.4)
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { return }
                for (index, panel) in self.panels.enumerated() {
                    let area = self.coverRects[index]
                    guard let right = Self.coverRightEdge(before: self.baseline, after: containers, owners: owners, area: area),
                          right < area.maxX - 1, let view = panel.contentView as? NSImageView,
                          let image = view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                          let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: ceil((right - area.minX) * CGFloat(image.width) / area.width), height: CGFloat(image.height))) else { continue }
                    let size = CGSize(width: right - area.minX, height: area.height)
                    view.image = NSImage(cgImage: cropped, size: size); view.frame.size = size
                    panel.setFrame(CGRect(origin: panel.frame.origin, size: size), display: true)
                }
                completion(self.coverRects)
            }
        }
    }
    static func coverRightEdge(before: [MenuBarContainer], after: [MenuBarContainer], owners: Set<pid_t>, area: CGRect) -> CGFloat? {
        let current = after.filter { area.contains($0.frame) }
        let selected = current.filter { owners.contains($0.pid) }
        guard !owners.isEmpty, owners.isSubset(of: Set(selected.map(\.pid))), var edge = selected.map(\.frame.maxX).max() else { return nil }
        for old in before where area.contains(old.frame) && !owners.contains(old.pid) {
            let matches = current.filter { $0.pid == old.pid }
            if matches.isEmpty { edge = max(edge, old.frame.maxX); continue }
            guard matches.count == 1, let new = matches.first else { return nil }
            if old.frame != new.frame { edge = max(edge, old.frame.maxX, new.frame.maxX) }
        }
        return min(area.maxX, ceil(edge + 4))
    }
    func replay(_ samples: [MenuBarPointerSample], entry: MenuBarEntry, display: CGRect,
                token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        replay(samples, entry: entry, display: display, token: token, didActivateBar: false, completion: completion)
    }
    private func replay(_ samples: [MenuBarPointerSample], entry: MenuBarEntry, display: CGRect,
                        token: MenuBarReadToken, didActivateBar: Bool, completion: @escaping (Bool) -> Void) {
        guard MenuBarPointerSample.valid(samples), !token.isCancelled else { completion(false); return }
        guard NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier == entry.bundle else { completion(false); return }
        let targetScreen = NSScreen.screens.first { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayBounds(id) == display
        }
        let targetID = (targetScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
        let needsActivation = !didActivateBar && MenuBarSourceDisplay.current(fallback: targetID) != targetID
        let safeLeft = targetScreen?.auxiliaryTopRightArea.map { $0.minX } ?? (display.midX + 40)
        queue.asyncAfter(deadline: .now() + 0.2) {
            let containers = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.5)
            let local = containers.filter { display.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            let frames = Set(local.filter { $0.pid == entry.pid }.map { NSValue(rect: $0.frame) })
            let frame = frames.count == 1 ? frames.first?.rectValue : nil
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { completion(false); return }
                guard let frame else { completion(false); return }
                if needsActivation {
                    // An inactive screen consumes the first bar click just to
                    // activate that bar. Use verified empty space to its left,
                    // then resolve the owner's new container again. Never
                    // spend the user's first click on this screen handover.
                    guard let edge = local.map(\.frame.minX).min(), edge - safeLeft >= 16 else { completion(false); return }
                    let point = CGPoint(x: edge - 8, y: frame.midY)
                    self.deliver(MenuBarPointerSample.singleClick, point: point, token: token) { [weak self] ok in
                        guard let self, ok, !token.isCancelled else { completion(false); return }
                        self.replay(samples, entry: entry, display: display, token: token, didActivateBar: true, completion: completion)
                    }
                    return
                }
                self.deliver(samples, point: CGPoint(x: frame.midX, y: frame.midY), token: token, completion: completion)
            }
        }
    }
    func deliver(_ samples: [MenuBarPointerSample], point: CGPoint, token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        guard MenuBarPointerSample.valid(samples), !token.isCancelled else { completion(false); return }
        if sendOverride == nil {
            eventSource = CGEventSource(stateID: .hidSystemState)
            returnPoint = CGEvent(source: nil)?.location
            relayPoint = point
        }
        post(.mouseMoved, point: point, sample: nil)
        let start = ProcessInfo.processInfo.systemUptime + 0.03, first = samples[0].timestamp
        var offsets: [TimeInterval] = []
        for (index, sample) in samples.enumerated() {
            let minimum = index == 0 ? 0 : offsets[index - 1] + (index.isMultiple(of: 2) ? 0.02 : 0.04)
            offsets.append(max(sample.timestamp - first, minimum))
        }
        func next(_ index: Int) {
            guard !token.isCancelled else { return }
            guard index < samples.count else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !token.isCancelled else { return }; self.delivery = nil
                    self.restoreCursor(); completion(true)
                }
                delivery = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work); return
            }
            let sample = samples[index]
            let work = DispatchWorkItem { [weak self] in
                guard let self, !token.isCancelled else { return }; self.delivery = nil
                if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(sample.type) { self.pressed = (point, sample) }
                self.post(sample.type, point: point, sample: sample)
                if [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(sample.type) { self.pressed = nil }
                next(index + 1)
            }
            delivery = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start + offsets[index] - ProcessInfo.processInfo.systemUptime), execute: work)
        }
        next(0)
    }
    private func post(_ type: CGEventType, point: CGPoint, sample: MenuBarPointerSample?) {
        if let sendOverride { sendOverride(type, point, sample); return }
        let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: sample?.button ?? .left)
        event?.flags = sample?.flags ?? []
        event?.setIntegerValueField(.mouseEventClickState, value: sample?.count ?? 1)
        event?.setIntegerValueField(.eventSourceUserData, value: MenuBarDrawerInput.eventMark)
        event?.post(tap: .cghidEventTap)
    }
    private func restoreCursor() {
        if let returnPoint, let relayPoint, sendOverride == nil, let currentPoint = CGEvent(source: nil)?.location,
           hypot(currentPoint.x - relayPoint.x, currentPoint.y - relayPoint.y) < 2 { post(.mouseMoved, point: returnPoint, sample: nil) }
        returnPoint = nil; relayPoint = nil
    }
    /// Native activation acknowledges the request before compositor reflow has
    /// necessarily finished. Bound this operation-local wait; never expose the
    /// still's removal to an arbitrary 150 ms guess or add an idle poller.
    func waitForHidden(_ pids: Set<pid_t>, completion: @escaping (Bool) -> Void) {
        if captureOverride != nil || pids.isEmpty { completion(true); return }
        let token = MenuBarReadToken(); settling?.cancel(); settling = token
        let deadline = ProcessInfo.processInfo.systemUptime + 1.25
        func check(_ absent: Int) {
            queue.async {
                guard !token.isCancelled else { return }
                let snapshot = MenuBarInventory.snapshot(token: token, deadline: min(deadline, ProcessInfo.processInfo.systemUptime + 0.2))
                let missing = Self.confirmsHidden(snapshot, owners: pids)
                let count = missing ? absent + 1 : 0
                let done = count >= 2, expired = ProcessInfo.processInfo.systemUptime >= deadline
                if done || expired {
                    DispatchQueue.main.async { if !token.isCancelled { completion(done) } }
                } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { check(count) } }
            }
        }
        check(0)
    }
    nonisolated static func confirmsHidden(_ snapshot: MenuBarContainerSnapshot, owners: Set<pid_t>) -> Bool {
        snapshot.complete && !snapshot.entries.isEmpty && snapshot.entries.allSatisfy { !owners.contains($0.pid) }
    }
    func cancelInput() {
        current?.cancel(); current = nil; delivery?.cancel(); delivery = nil
        if let (point, sample) = pressed {
            let up: CGEventType = sample.type == .leftMouseDown ? .leftMouseUp : sample.type == .rightMouseDown ? .rightMouseUp : .otherMouseUp
            post(up, point: point, sample: sample)
        }
        pressed = nil; restoreCursor()
        eventSource = nil
    }
    func cancel() {
        cancelInput()
        settling?.cancel(); settling = nil
        for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        panels.removeAll()
        baseline.removeAll()
        originals.removeAll()
    }
}
