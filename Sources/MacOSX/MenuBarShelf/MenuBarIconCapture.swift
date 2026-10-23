import AppKit
@preconcurrency import ScreenCaptureKit

struct MenuBarIconPixels {
    let image: CGImage
    let size: CGSize
    var sourceFrame: CGRect? = nil
    var sourceSurface: CGRect? = nil
    var sourceSurfaceID: CGWindowID? = nil
}

/// Captures only the native menu-bar surface, never a full desktop. No stream,
/// polling or disk cache. One issued request and one latest pending request.
final class MenuBarIconCapture {
    private struct Job {
        let entries: [MenuBarEntry]
        let token: MenuBarReadToken
        let completion: ([String: MenuBarIconPixels]) -> Void
        var attempt = 0
    }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.menu-bar-pixels", qos: .userInitiated)
    private var pending: Job?
    private var current: MenuBarReadToken?
    private var busy = false
    func read(_ entries: [MenuBarEntry], token: MenuBarReadToken,
              completion: @escaping ([String: MenuBarIconPixels]) -> Void) {
        queue.async { [self] in
            current?.cancel(); pending?.token.cancel()
            pending = Job(entries: Array(entries.filter(\.visible).prefix(128)), token: token, completion: completion); drain()
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
                let entries = refreshed(job.entries, token: job.token)
                guard !job.token.isCancelled else { finish(); return }
                let pids = Set(entries.filter(\.visible).map(\.pid))
                let compositor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                let surfaces = content.windows.filter { window in
                    let owner = window.owningApplication
                    return (20...30).contains(window.windowLayer)
                        && window.frame.width > 0 && window.frame.width <= 16_384 && window.frame.height > 0 && window.frame.height <= 80
                        && (compositor ? owner?.bundleIdentifier == "com.apple.MenuBarAgent" : pids.contains(owner?.processID ?? -1))
                        && entries.contains { Self.matchesSurface($0, id: window.windowID, frame: window.frame, compositor: compositor) }
                }.prefix(8)
                let changed = zip(job.entries, entries).contains { $0.visible != $1.visible || $0.frame != $1.frame || $0.surface != $1.surface || $0.surfaceID != $1.surfaceID }
                capture(Array(surfaces), displays: content.displays, entries: entries, index: 0,
                        excluding: content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier },
                        pixels: [:], bytes: 0,
                        changed: changed, job: job)
            }
        }
    }
    private func capture(_ surfaces: [SCWindow], displays: [SCDisplay], entries: [MenuBarEntry], index: Int, excluding: [SCWindow], pixels: [String: MenuBarIconPixels], bytes: Int, changed: Bool, job: Job) {
        guard !job.token.isCancelled else { finish(); return }
        guard index < surfaces.count, pixels.count < 64 else {
            if changed, job.attempt == 0, pending == nil,
               !Set(job.entries.filter(\.visible).map(\.bundle)).isSubset(of: Set(pixels.keys)) {
                var retry = job; retry.attempt = 1; pending = retry
            } else { deliver(pixels, job) }
            finish(); return
        }
        let window = surfaces[index], frame = surfaces[index].frame
        let filter: SCContentFilter
        let display = displays.first { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }
        if let display, #available(macOS 14.2, *) {
            // An independent MenuBarAgent window capture can leave its surface
            // at 1x inside a larger canvas. Explicit display-local crop fixes it.
            filter = SCContentFilter(display: display, excludingWindows: excluding); filter.includeMenuBar = true
        } else { filter = SCContentFilter(desktopIndependentWindow: window) }
        let scale = max(1, min(3, CGFloat(filter.pointPixelScale)))
        let config = SCStreamConfiguration()
        config.width = max(1, Int((frame.width * scale).rounded()))
        config.height = max(1, Int((frame.height * scale).rounded()))
        guard config.width * config.height <= 4_000_000 else {
            capture(surfaces, displays: displays, entries: entries, index: index + 1, excluding: excluding, pixels: pixels, bytes: bytes, changed: changed, job: job); return
        }
        config.showsCursor = false; config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
        if let display, #available(macOS 14.2, *) { config.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) }
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [self] image, _ in
            queue.async { [self] in
                guard !job.token.isCancelled else { finish(); return }
                var next = pixels, used = bytes
                let after = refreshed(entries, token: job.token)
                let changedDuringCapture = zip(entries, after).contains { $0.visible != $1.visible || $0.frame != $1.frame || $0.surface != $1.surface || $0.surfaceID != $1.surfaceID }
                let stable = Self.stableEntries(entries, after: after)
                if let image {
                    let compositor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
                    for entry in stable where next[entry.bundle] == nil && Self.matchesSurface(entry, id: window.windowID, frame: frame, compositor: compositor) {
                        guard var glyph = Self.crop(image, surface: frame, item: entry.frame) else { continue }
                        glyph = Self.removeBarBackground(glyph)
                        glyph.sourceSurface = frame; glyph.sourceSurfaceID = window.windowID
                        let cost = glyph.image.bytesPerRow * glyph.image.height
                        guard next.count < 64, used + cost <= 4_000_000 else { continue }
                        next[entry.bundle] = glyph; used += cost
                    }
                }
                capture(surfaces, displays: displays, entries: entries, index: index + 1, excluding: excluding, pixels: next, bytes: used, changed: changed || changedDuringCapture, job: job)
            }
        }
    }
    /// AX and WindowServer finish menu-bar reflow asynchronously. Match the
    /// source bounds across the actual screenshot, not just the earlier scan.
    private func refreshed(_ entries: [MenuBarEntry], token: MenuBarReadToken) -> [MenuBarEntry] {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return entries }
        let containers = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.35)
        return MenuBarContainerGeometry.reconcile(entries, containers: containers)
    }
    static func stableEntries(_ before: [MenuBarEntry], after: [MenuBarEntry]) -> [MenuBarEntry] {
        before.filter { entry in
            entry.visible && after.contains { $0.visible && $0.bundle == entry.bundle && $0.pid == entry.pid && $0.frame == entry.frame && $0.surface == entry.surface && $0.surfaceID == entry.surfaceID }
        }
    }
    static func matchesSurface(_ entry: MenuBarEntry, id: CGWindowID, frame: CGRect, compositor: Bool) -> Bool {
        guard entry.visible, frame.contains(entry.frame) else { return false }
        return !compositor || (entry.surface == frame && entry.surfaceID == id)
    }
    /// Remove the photographed bar, preserving coloured ink. Neutral ink edges
    /// are unmatted against the local top/bottom background rather than tinted.
    /// An already-transparent native image is kept unchanged.
    static func removeBarBackground(_ glyph: MenuBarIconPixels) -> MenuBarIconPixels {
        let image = glyph.image, w = image.width, h = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard w > 0, w <= 960, h >= 8, h <= 240,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let raw = context.data else { return glyph }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let data = raw.assumingMemoryBound(to: UInt8.self)
        for x in 0..<w where data[(x + w) * 4 + 3] < 250 || data[(x + (h - 2) * w) * 4 + 3] < 250 { return glyph }
        let border = (0..<w).map { x -> ([Double], [Double]) in
            ((0..<3).map { Double(data[(w + x) * 4 + $0]) / 255 },
             (0..<3).map { Double(data[((h - 2) * w + x) * 4 + $0]) / 255 })
        }
        for y in 0..<h { for x in 0..<w {
            let offset = (y * w + x) * 4, t = Double(y) / Double(h - 1)
            let bg = (0..<3).map { border[x].0[$0] * (1 - t) + border[x].1[$0] * t }
            let pixel = (0..<3).map { Double(data[offset + $0]) / 255 }
            if zip(pixel, bg).map({ abs($0 - $1) }).max()! <= 4.0 / 255 { for c in 0..<4 { data[offset + c] = 0 }; continue }
            for light in [false, true] {
                // Remote template widgets on an inactive bar use vibrant
                // plus-darker/plus-lighter ink, not ordinary alpha-over. Their
                // equal channel delta otherwise survives as yellow wallpaper.
                let delta = (0..<3).map { light ? pixel[$0] - bg[$0] : bg[$0] - pixel[$0] }
                let strength = delta.reduce(0, +) / 3
                if strength > 0, strength <= 1, delta.allSatisfy({ abs($0 - strength) <= 2.0 / 255 }) {
                    let alpha = UInt8((strength * 255).rounded())
                    data[offset] = light ? alpha : 0; data[offset + 1] = light ? alpha : 0
                    data[offset + 2] = light ? alpha : 0; data[offset + 3] = alpha; break
                }
                let ratios = (0..<3).compactMap { c -> Double? in
                    let range = light ? 1 - bg[c] : bg[c]
                    guard range > 0.1 else { return nil }
                    return light ? (pixel[c] - bg[c]) / range : 1 - pixel[c] / range
                }
                guard !ratios.isEmpty else { continue }
                let alpha = min(1, max(0, ratios.reduce(0, +) / Double(ratios.count)))
                let error = (0..<3).map { abs(pixel[$0] - (bg[$0] * (1 - alpha) + (light ? alpha : 0))) }.max()!
                if error <= 2.0 / 255 {
                    let value = UInt8((alpha * 255).rounded())
                    data[offset] = light ? value : 0; data[offset + 1] = light ? value : 0
                    data[offset + 2] = light ? value : 0; data[offset + 3] = value; break
                }
            }
        } }
        guard let result = context.makeImage() else { return glyph }
        return MenuBarIconPixels(image: result, size: glyph.size, sourceFrame: glyph.sourceFrame,
                                 sourceSurface: glyph.sourceSurface, sourceSurfaceID: glyph.sourceSurfaceID)
    }
    static func crop(_ image: CGImage, surface: CGRect, item: CGRect) -> MenuBarIconPixels? {
        guard surface.width > 0, surface.height > 0, item.width > 0, item.width <= 320,
              item.height > 0, item.height <= 80, surface.contains(item),
              surface.minX.isFinite, surface.minY.isFinite, item.minX.isFinite, item.minY.isFinite else { return nil }
        let sx = CGFloat(image.width) / surface.width, sy = CGFloat(image.height) / surface.height
        // Reject a padded/letterboxed or differently scaled canvas rather
        // than stretching its coordinates into neighbouring native items.
        guard sx >= 0.99, sx <= 3.01, sy >= 0.99, sy <= 3.01,
              abs(sx - sy) <= 0.02 else { return nil }
        let rect = CGRect(x: (item.minX - surface.minX) * sx, y: (item.minY - surface.minY) * sy,
                          width: item.width * sx, height: item.height * sy).integral
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let cropped = image.cropping(to: rect), cropped.width <= 960, cropped.height <= 240,
              let copy = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGImage.cropping can retain the entire bar backing. Copy just the
        // small glyph so the cache's byte limit is a real memory bound.
        copy.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let result = copy.makeImage() else { return nil }
        return MenuBarIconPixels(image: result, size: CGSize(width: CGFloat(cropped.width) / sx, height: CGFloat(cropped.height) / sy), sourceFrame: item)
    }
    private func deliver(_ pixels: [String: MenuBarIconPixels], _ job: Job) {
        DispatchQueue.main.async { if !job.token.isCancelled { job.completion(pixels) } }
    }
    private func finish() { busy = false; current = nil; drain() }
}
