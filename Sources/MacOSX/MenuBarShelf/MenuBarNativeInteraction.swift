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
        count = Int64(event.clickCount); flags = event.cgEvent?.flags ?? []
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
    private var current: MenuBarReadToken?
    private var delivery: DispatchWorkItem?
    private var pressed: (CGPoint, MenuBarPointerSample)?
    private var returnPoint: CGPoint?
    private var relayPoint: CGPoint?
    private var cursorHidden = false
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.native-menu-input", qos: .userInitiated)
    var coverCount: Int { panels.count }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { if !token.isCancelled { completion(true) } }; return
        }
        let (frame, id, height) = screens[index]
        guard let display = content.displays.first(where: { $0.displayID == id }) else { completion(false); return }
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
                let view = NSImageView(frame: CGRect(origin: .zero, size: rect.size))
                view.image = NSImage(cgImage: image, size: rect.size); view.imageScaling = .scaleAxesIndependently
                panel.contentView = view; panel.orderFrontRegardless(); panel.displayIfNeeded(); self.panels.append(panel)
                self.capture(screens, content: content, index: index + 1, bytes: bytes + imageCost, token: token, completion: completion)
            }
        }
    }
    func replay(_ samples: [MenuBarPointerSample], entry: MenuBarEntry, display: CGRect,
                token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        guard MenuBarPointerSample.valid(samples), !token.isCancelled else { completion(false); return }
        guard NSRunningApplication(processIdentifier: entry.pid)?.bundleIdentifier == entry.bundle else { completion(false); return }
        queue.async {
            let containers = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.5)
            let frame = containers.first { $0.pid == entry.pid && display.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }?.frame
            DispatchQueue.main.async { [weak self] in
                guard let self, !token.isCancelled else { return }
                guard let frame else { completion(false); return }
                self.deliver(samples, point: CGPoint(x: frame.midX, y: frame.midY), token: token, completion: completion)
            }
        }
    }
    func deliver(_ samples: [MenuBarPointerSample], point: CGPoint, token: MenuBarReadToken, completion: @escaping (Bool) -> Void) {
        guard MenuBarPointerSample.valid(samples), !token.isCancelled else { completion(false); return }
        if sendOverride == nil {
            returnPoint = CGEvent(source: nil)?.location
            relayPoint = point
            cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        }
        post(.mouseMoved, point: point, sample: nil)
        let start = ProcessInfo.processInfo.systemUptime + 0.03, first = samples[0].timestamp
        func next(_ index: Int) {
            guard !token.isCancelled else { return }
            guard index < samples.count else {
                restoreCursor(); completion(true); return
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
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, start + sample.timestamp - first - ProcessInfo.processInfo.systemUptime), execute: work)
        }
        next(0)
    }
    private func post(_ type: CGEventType, point: CGPoint, sample: MenuBarPointerSample?) {
        if let sendOverride { sendOverride(type, point, sample); return }
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: sample?.button ?? .left)
        event?.flags = sample?.flags ?? []
        event?.setIntegerValueField(.mouseEventClickState, value: sample?.count ?? 0)
        event?.setIntegerValueField(.eventSourceUserData, value: MenuBarDrawerInput.eventMark)
        event?.post(tap: .cgSessionEventTap)
    }
    private func restoreCursor() {
        if let returnPoint, let relayPoint, sendOverride == nil, let currentPoint = CGEvent(source: nil)?.location,
           hypot(currentPoint.x - relayPoint.x, currentPoint.y - relayPoint.y) < 2 { CGWarpMouseCursorPosition(returnPoint) }
        returnPoint = nil; relayPoint = nil
        if cursorHidden { CGDisplayShowCursor(CGMainDisplayID()); cursorHidden = false }
    }
    func cancelInput() {
        current?.cancel(); current = nil; delivery?.cancel(); delivery = nil
        if let (point, sample) = pressed {
            let up: CGEventType = sample.type == .leftMouseDown ? .leftMouseUp : sample.type == .rightMouseDown ? .rightMouseUp : .otherMouseUp
            post(up, point: point, sample: sample)
        }
        pressed = nil; restoreCursor()
    }
    func cancel() {
        cancelInput()
        for panel in panels { panel.orderOut(nil); panel.contentView = nil; panel.close() }
        panels.removeAll()
    }
}
