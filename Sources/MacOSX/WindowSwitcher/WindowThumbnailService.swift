import AppKit
@preconcurrency import ScreenCaptureKit

struct WindowThumbnailID: Hashable {
    let window: CGWindowID
    let process: pid_t
}

/// No streams, timers or idle captures. One issued SCK operation and one latest
/// pending page; cancellation discards late callbacks without issuing overlap.
/// Cache stays in memory only: <=16 images / 8 MB, 480×300 pixels each, 6s TTL.
final class WindowThumbnailService {
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var valid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    }
    private struct Job {
        let ticket: Ticket
        let ids: [WindowThumbnailID]
        let updated: (WindowThumbnailID, CGImage) -> Void
        let failed: (Error) -> Void
    }
    private struct Entry { let image: CGImage; let created: TimeInterval; var used: UInt64 }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.window-thumbnails", qos: .userInitiated)
    private var pending: Job?
    private var busy = false
    private var activeTicket: Ticket?
    private var cache: [WindowThumbnailID: Entry] = [:]
    private var clock: UInt64 = 0

    @discardableResult
    func request(_ ids: [WindowThumbnailID], updated: @escaping (WindowThumbnailID, CGImage) -> Void,
                 failed: @escaping (Error) -> Void) -> Ticket {
        let ticket = Ticket()
        let job = Job(ticket: ticket, ids: Array(ids.prefix(8)), updated: updated, failed: failed)
        queue.async { [self] in
            activeTicket?.cancel(); pending?.ticket.cancel(); pending = job
            drain()
        }
        return ticket
    }

    func retain(_ ids: Set<WindowThumbnailID>) {
        queue.async { [self] in cache = cache.filter { ids.contains($0.key) } }
    }
    func clear() {
        queue.async { [self] in activeTicket?.cancel(); pending?.ticket.cancel(); pending = nil; cache.removeAll() }
    }

    private func drain() {
        guard !busy, let job = pending else { return }
        pending = nil
        guard job.ticket.valid else { drain(); return }
        busy = true; activeTicket = job.ticket
        let now = ProcessInfo.processInfo.systemUptime
        var needed: [WindowThumbnailID] = []
        for id in job.ids {
            if var entry = cache[id], now - entry.created < 6 {
                clock &+= 1; entry.used = clock; cache[id] = entry
                deliver(entry.image, id, job)
            } else { needed.append(id) }
        }
        guard !needed.isEmpty else { finish(); return }
        // Called only after the owner checks access during an explicit held
        // switch/preview. Metadata and pixels never run on the event/UI thread.
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [self] content, error in
            queue.async { [self] in
                guard job.ticket.valid else { finish(); return }
                guard let content else { fail(error ?? CaptureFailure.unavailable, job); return }
                let wanted = Set(needed)
                var windows: [WindowThumbnailID: SCWindow] = [:]
                for window in content.windows {
                    guard let pid = window.owningApplication?.processID else { continue }
                    let id = WindowThumbnailID(window: window.windowID, process: pid)
                    if wanted.contains(id) { windows[id] = window }
                }
                capture(needed, windows, index: 0, job)
            }
        }
    }

    private func capture(_ ids: [WindowThumbnailID], _ windows: [WindowThumbnailID: SCWindow], index: Int, _ job: Job) {
        guard job.ticket.valid, index < ids.count else { finish(); return }
        let id = ids[index]
        guard let window = windows[id], window.frame.width.isFinite, window.frame.height.isFinite,
              window.frame.width > 0, window.frame.height > 0 else {
            capture(ids, windows, index: index + 1, job); return
        }
        let ratio = min(480 / window.frame.width, 300 / window.frame.height)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * ratio).rounded(.down)))
        configuration.height = max(1, Int((window.frame.height * ratio).rounded(.down)))
        configuration.showsCursor = false; configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                         configuration: configuration) { [self] image, error in
            queue.async { [self] in
                guard job.ticket.valid else { finish(); return }
                if let error, case CaptureFailure.permission = CaptureFailure.screenCaptureError(error) {
                    fail(error, job); return
                }
                if let image, image.width <= 480, image.height <= 300,
                   image.bytesPerRow <= 700_000 / max(1, image.height) {
                    clock &+= 1
                    cache[id] = Entry(image: image, created: ProcessInfo.processInfo.systemUptime, used: clock)
                    trim(); deliver(image, id, job)
                }
                // Missing, protected or minimized windows retain their icon.
                capture(ids, windows, index: index + 1, job)
            }
        }
    }
    private func trim() {
        func bytes() -> Int { cache.values.reduce(0) { $0 + $1.image.bytesPerRow * $1.image.height } }
        while cache.count > 16 || bytes() > 8_000_000 {
            guard let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key else { break }
            cache.removeValue(forKey: oldest)
        }
    }
    private func deliver(_ image: CGImage, _ id: WindowThumbnailID, _ job: Job) {
        DispatchQueue.main.async { if job.ticket.valid { job.updated(id, image) } }
    }
    private func fail(_ error: Error, _ job: Job) {
        DispatchQueue.main.async { if job.ticket.valid { job.failed(error) } }
        finish()
    }
    private func finish() { busy = false; activeTicket = nil; drain() }
}
