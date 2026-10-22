import AppKit
@preconcurrency import ScreenCaptureKit

struct MenuBarIconPixels {
    let image: CGImage
    let size: CGSize
}

/// Captures only the native menu-bar surface, never a full desktop. No stream,
/// polling or disk cache. One issued request and one latest pending request.
final class MenuBarIconCapture {
    private struct Job {
        let entries: [MenuBarEntry]
        let token: MenuBarReadToken
        let completion: ([String: MenuBarIconPixels]) -> Void
    }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.menu-bar-pixels", qos: .userInitiated)
    private var pending: Job?
    private var current: MenuBarReadToken?
    private var busy = false
    func read(_ entries: [MenuBarEntry], token: MenuBarReadToken,
              completion: @escaping ([String: MenuBarIconPixels]) -> Void) {
        queue.async { [self] in
            current?.cancel(); pending?.token.cancel()
            pending = Job(entries: Array(entries.prefix(128)), token: token, completion: completion); drain()
        }
    }
    func clear() {
        queue.async { [self] in current?.cancel(); pending?.token.cancel(); pending = nil }
    }
    private func drain() {
        guard !busy, let job = pending else { return }; pending = nil
        guard !job.token.isCancelled else { drain(); return }
        guard CGPreflightScreenCaptureAccess(), !job.entries.isEmpty else { deliver([:], job); drain(); return }
        busy = true; current = job.token
        // macOS 27 reports the visible MenuBarAgent surface as isOnScreen=false.
        // Enumerate all windows, then strictly select the small menu surface.
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [self] content, _ in
            queue.async { [self] in
                guard !job.token.isCancelled else { finish(); return }
                guard let content else { deliver([:], job); finish(); return }
                let pids = Set(job.entries.map(\.pid))
                let surfaces = content.windows.filter { window in
                    let owner = window.owningApplication
                    return (20...30).contains(window.windowLayer)
                        && window.frame.width > 0 && window.frame.width <= 16_384 && window.frame.height > 0 && window.frame.height <= 80
                        && (owner?.bundleIdentifier == "com.apple.MenuBarAgent" || pids.contains(owner?.processID ?? -1))
                        && job.entries.contains { window.frame.contains($0.frame) }
                }.prefix(8)
                capture(Array(surfaces), displays: content.displays, index: 0, pixels: [:], bytes: 0, job: job)
            }
        }
    }
    private func capture(_ surfaces: [SCWindow], displays: [SCDisplay], index: Int, pixels: [String: MenuBarIconPixels], bytes: Int, job: Job) {
        guard !job.token.isCancelled else { finish(); return }
        guard index < surfaces.count, pixels.count < 64 else { deliver(pixels, job); finish(); return }
        let window = surfaces[index], frame = surfaces[index].frame
        let filter: SCContentFilter
        let display = displays.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        if let display, #available(macOS 14.2, *) {
            // An independent MenuBarAgent window capture can leave its surface
            // at 1x inside a larger canvas. Explicit display-local crop fixes it.
            filter = SCContentFilter(display: display, including: [window]); filter.includeMenuBar = true
        } else { filter = SCContentFilter(desktopIndependentWindow: window) }
        let scale = max(1, min(3, CGFloat(filter.pointPixelScale)))
        let config = SCStreamConfiguration()
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        guard config.width * config.height <= 4_000_000 else {
            capture(surfaces, displays: displays, index: index + 1, pixels: pixels, bytes: bytes, job: job); return
        }
        config.showsCursor = false; config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
        if let display, #available(macOS 14.2, *) { config.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [self] image, _ in
            queue.async { [self] in
                guard !job.token.isCancelled else { finish(); return }
                var next = pixels, used = bytes
                if let image {
                    for entry in job.entries where next[entry.bundle] == nil && frame.contains(entry.frame) {
                        guard let glyph = Self.crop(image, surface: frame, item: entry.frame) else { continue }
                        let cost = glyph.image.bytesPerRow * glyph.image.height
                        guard next.count < 64, used + cost <= 4_000_000 else { continue }
                        next[entry.bundle] = glyph; used += cost
                    }
                }
                capture(surfaces, displays: displays, index: index + 1, pixels: next, bytes: used, job: job)
            }
        }
    }
    static func crop(_ image: CGImage, surface: CGRect, item: CGRect) -> MenuBarIconPixels? {
        guard surface.width > 0, surface.height > 0, item.width > 0, item.width <= 320,
              item.height > 0, item.height <= 80, surface.contains(item),
              surface.minX.isFinite, surface.minY.isFinite, item.minX.isFinite, item.minY.isFinite else { return nil }
        let sx = CGFloat(image.width) / surface.width, sy = CGFloat(image.height) / surface.height
        let rect = CGRect(x: (item.minX - surface.minX) * sx, y: (item.minY - surface.minY) * sy,
                          width: item.width * sx, height: item.height * sy).integral
        guard let cropped = image.cropping(to: rect), cropped.width <= 960, cropped.height <= 240,
              let copy = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGImage.cropping can retain the entire bar backing. Copy just the
        // small glyph so the cache's byte limit is a real memory bound.
        copy.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let result = copy.makeImage() else { return nil }
        return MenuBarIconPixels(image: result, size: CGSize(width: CGFloat(cropped.width) / sx, height: CGFloat(cropped.height) / sy))
    }
    private func deliver(_ pixels: [String: MenuBarIconPixels], _ job: Job) {
        DispatchQueue.main.async { if !job.token.isCancelled { job.completion(pixels) } }
    }
    private func finish() { busy = false; current = nil; drain() }
}
