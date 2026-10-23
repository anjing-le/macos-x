import AppKit
@preconcurrency import ScreenCaptureKit

/// Only an open drawer runs this small, single-flight rendering loop. Resolve
/// the native surface once; no window-list timer, desktop, audio or disk cache.
final class MenuBarLivePixels {
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.live-bar-pixels", qos: .userInitiated)
    private var token: MenuBarReadToken?
    private var epoch: UInt64 = 0
    private var scheduled: DispatchWorkItem?
    func start(displayID: CGDirectDisplayID, entries: [MenuBarEntry], token: MenuBarReadToken,
               receive: @escaping ([String: MenuBarIconPixels]) -> Void, failure: @escaping () -> Void) {
        queue.async { [self] in
            epoch &+= 1; let expected = epoch; self.token = token
            scheduled?.cancel(); scheduled = nil
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
                guard let self else { return }
                self.queue.async {
                    guard self.valid(token, expected) else { return }
                    let containers = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.4, owners: Set(entries.map(\.pid)))
                    let ids = Set(containers.compactMap(\.surfaceID))
                    guard let content, let display = content.displays.first(where: { $0.displayID == displayID }),
                          let window = content.windows.first(where: {
                              $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent"
                                  && ids.contains($0.windowID)
                                  && (20...30).contains($0.windowLayer) && $0.frame.height > 0 && $0.frame.height <= 80
                                  && display.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                          }) else { self.failed(token, expected, failure); return }
                    // Remote status-item layers are not included by an
                    // Agent-window-only filter. Composite the real bar, while
                    // excluding our covers and drawer from the photograph.
                    let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                    let filter = SCContentFilter(display: display, excludingWindows: own)
                    if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                    let scale = max(1, min(3, CGFloat(filter.pointPixelScale)))
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int((window.frame.width * scale).rounded()))
                    config.height = max(1, Int((window.frame.height * scale).rounded()))
                    guard config.width * config.height <= 4_000_000 else { self.failed(token, expected, failure); return }
                    config.sourceRect = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    config.showsCursor = false; config.capturesAudio = false
                    config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
                    self.frame(entries: Array(entries.prefix(64)), window: window, filter: filter, config: config,
                               token: token, expected: expected, receive: receive, failure: failure)
                }
            }
        }
    }
    private func valid(_ token: MenuBarReadToken, _ expected: UInt64) -> Bool {
        self.token === token && epoch == expected && !token.isCancelled
    }
    private func failed(_ token: MenuBarReadToken, _ expected: UInt64, _ failure: @escaping () -> Void) {
        guard valid(token, expected) else { return }
        self.token = nil; scheduled?.cancel(); scheduled = nil
        DispatchQueue.main.async { if !token.isCancelled { failure() } }
    }
    private func frame(entries: [MenuBarEntry], window: SCWindow, filter: SCContentFilter, config: SCStreamConfiguration,
                       token: MenuBarReadToken, expected: UInt64, receive: @escaping ([String: MenuBarIconPixels]) -> Void,
                       failure: @escaping () -> Void) {
        guard valid(token, expected) else { return }; scheduled = nil
        let started = ProcessInfo.processInfo.systemUptime, owners = Set(entries.map(\.pid))
        let before = MenuBarInventory.containers(token: token, deadline: started + 0.2, surfaceID: window.windowID, owners: owners)
        let resolved = MenuBarContainerGeometry.reconcile(entries, containers: before, surfaceID: window.windowID)
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { [weak self] image, error in
            guard let self else { return }
            self.queue.async {
                guard self.valid(token, expected) else { return }
                guard let image, error == nil else { self.failed(token, expected, failure); return }
                let after = MenuBarInventory.containers(token: token, deadline: ProcessInfo.processInfo.systemUptime + 0.2, surfaceID: window.windowID, owners: owners)
                let stable = MenuBarIconCapture.stableEntries(resolved, after: MenuBarContainerGeometry.reconcile(entries, containers: after, surfaceID: window.windowID))
                var pixels: [String: MenuBarIconPixels] = [:], bytes = 0
                for entry in stable where pixels[entry.bundle] == nil && entry.surface == window.frame {
                    guard var glyph = MenuBarIconCapture.crop(image, surface: window.frame, item: entry.frame) else { continue }
                    glyph = MenuBarIconCapture.removeBarBackground(glyph)
                    let cost = glyph.image.bytesPerRow * glyph.image.height
                    guard pixels.count < 64, bytes + cost <= 4_000_000 else { continue }
                    glyph.sourceSurface = window.frame; glyph.sourceSurfaceID = window.windowID
                    pixels[entry.bundle] = glyph; bytes += cost
                }
                let result = pixels
                DispatchQueue.main.async { if !token.isCancelled { receive(result) } }
                let work = DispatchWorkItem { [weak self] in
                    self?.frame(entries: entries, window: window, filter: filter, config: config, token: token,
                                expected: expected, receive: receive, failure: failure)
                }
                self.scheduled = work
                self.queue.asyncAfter(deadline: .now() + max(0.05, 0.5 - (ProcessInfo.processInfo.systemUptime - started)), execute: work)
            }
        }
    }
    func stop() { queue.async { [self] in epoch &+= 1; token = nil; scheduled?.cancel(); scheduled = nil } }
}
