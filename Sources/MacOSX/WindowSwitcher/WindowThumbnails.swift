import AppKit
// The macOS 14 SDK API hands read-only SCWindow snapshots across completion
// queues; we never mutate them. Older SDKs lack the corresponding annotations.
@preconcurrency import ScreenCaptureKit

/// One visible panel page, at most 12 images and two in-flight captures. Closing
/// the panel cancels queued work and discards late OS callbacks. Nothing captures
/// while the module is idle, and this class never requests permission implicitly.
@MainActor
final class WindowThumbnails {
    // The only mutable state is guarded by `lock`, including every read.
    private final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isValid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.window-thumbnails", qos: .userInitiated)
    private var ticket: Ticket?
    private var pending: [SCWindow] = []
    private var requestedIDs: [CGWindowID] = []
    private var discoveryInFlight = false
    private var inFlight = 0
    private(set) var images: [CGWindowID: NSImage] = [:]
    var onUpdate: (() -> Void)?
    var onPermissionMissing: (() -> Void)?

    func load(_ windows: [SwitcherWindow]) {
        cancel(clearImages: false)
        let ids = Array(windows.prefix(12).map(\.id))
        let live = Set(ids)
        images = images.filter { live.contains($0.key) }
        guard !ids.isEmpty else { return }
        let newTicket = Ticket(); ticket = newTicket
        requestedIDs = ids
        startDiscovery()
    }

    private func startDiscovery() {
        guard !discoveryInFlight, let newTicket = ticket, newTicket.isValid else { return }
        let ids = requestedIDs
        discoveryInFlight = true
        queue.async { [weak self] in
            guard newTicket.isValid else {
                DispatchQueue.main.async { self?.finishDiscovery(newTicket, windows: [], permissionMissing: false) }
                return
            }
            guard CGPreflightScreenCaptureAccess() else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishDiscovery(newTicket, windows: [], permissionMissing: true)
                }
                return
            }
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
                let byID = Dictionary(uniqueKeysWithValues: (content?.windows ?? []).map { ($0.windowID, $0) })
                DispatchQueue.main.async { [weak self] in
                    self?.finishDiscovery(newTicket, windows: ids.compactMap { byID[$0] }, permissionMissing: false)
                }
            }
        }
    }

    private func finishDiscovery(_ expected: Ticket, windows: [SCWindow], permissionMissing: Bool) {
        discoveryInFlight = false
        guard expected.isValid, ticket === expected else { startDiscovery(); return }
        if permissionMissing { onPermissionMissing?(); return }
        pending = windows
        pump(expected)
    }

    func cancel(clearImages: Bool = true) {
        ticket?.cancel(); ticket = nil
        pending.removeAll(); requestedIDs.removeAll()
        // Already-issued OS requests cannot be cancelled. Keep their global
        // budget occupied until they return, even across panel sessions/pages.
        if clearImages { images.removeAll() }
    }

    private func pump(_ expected: Ticket) {
        guard expected.isValid, ticket === expected else { return }
        while inFlight < 2, !pending.isEmpty {
            let window = pending.removeFirst(); inFlight += 1
            queue.async { [weak self] in
                guard expected.isValid else {
                    DispatchQueue.main.async { self?.finishCapture(expected, windowID: window.windowID, image: nil) }
                    return
                }
                let configuration = SCStreamConfiguration()
                let aspect = window.frame.height / max(window.frame.width, 1)
                configuration.width = 420
                configuration.height = max(1, min(280, Int(420 * aspect)))
                configuration.showsCursor = false
                configuration.scalesToFit = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.finishCapture(expected, windowID: window.windowID, image: image)
                    }
                }
            }
        }
    }

    private func finishCapture(_ expected: Ticket, windowID: CGWindowID, image: CGImage?) {
        inFlight = max(0, inFlight - 1)
        if expected.isValid, ticket === expected, let image {
            images[windowID] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            onUpdate?()
        }
        if let current = ticket { pump(current) }
    }
}
