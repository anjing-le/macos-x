import AppKit
@preconcurrency import ScreenCaptureKit

struct CaptureScreen {
    let id: CGDirectDisplayID
    let frame: CGRect // AppKit global points, including negative display origins
    let scale: CGFloat
}

struct CaptureFrame {
    let screen: CaptureScreen
    let image: CGImage
    let windows: [CGRect]
    let sampler: CapturePixelSampler?

    init(screen: CaptureScreen, image: CGImage, windows: [CGRect] = [], sampler: CapturePixelSampler? = nil) {
        self.screen = screen; self.image = image; self.windows = windows; self.sampler = sampler
    }
}

enum CaptureFailure: LocalizedError {
    case permission, cancelled, unavailable, oversized, emptyClipboard
    case message(String)
    var errorDescription: String? {
        switch self {
        case .permission: return "需要屏幕录制权限；授权后再试。"
        case .cancelled: return "已取消。"
        case .unavailable: return "当前没有可捕获的显示器。"
        case .oversized: return "图像超过内存上限，请选择较小区域。"
        case .emptyClipboard: return "剪贴板没有可贴出的图像或文字。"
        case .message(let value): return value
        }
    }
}

/// Serial, latest-request-wins capture. Issued screenshot calls cannot be
/// cancelled by macOS 14, so their callback must return before another begins.
/// At most one screenshot request and 32 million desktop pixels are retained.
final class CaptureImageService {
    final class Ticket: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var valid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    }
    private struct Request {
        let screens: [CaptureScreen]
        let ticket: Ticket
        let completion: (Result<[CaptureFrame], Error>) -> Void
    }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.images", qos: .userInitiated)
    private var pending: Request?
    private var busy = false
    private var latest: Ticket?
    private let lock = NSLock()

    @discardableResult
    func capture(_ screens: [CaptureScreen], completion: @escaping (Result<[CaptureFrame], Error>) -> Void) -> Ticket {
        let ticket = Ticket()
        lock.lock(); latest?.cancel(); latest = ticket; lock.unlock()
        queue.async { [self] in
            pending = Request(screens: screens, ticket: ticket, completion: completion)
            beginNext()
        }
        return ticket
    }

    func cancel() {
        lock.lock(); latest?.cancel(); latest = nil; lock.unlock()
        queue.async { [self] in pending = nil }
    }

    private func beginNext() {
        guard !busy, let request = pending else { return }
        pending = nil
        guard request.ticket.valid else { beginNext(); return }
        busy = true
        guard CGPreflightScreenCaptureAccess() else { finish(request, .failure(CaptureFailure.permission)); return }
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            self?.queue.async { [weak self] in
                guard let self else { return }
                guard request.ticket.valid else { self.finish(request, .failure(CaptureFailure.cancelled)); return }
                guard let content else { self.finish(request, .failure(error ?? CaptureFailure.unavailable)); return }
                let totalPixels = request.screens.reduce(CGFloat(0)) { $0 + $1.frame.width * $1.frame.height * $1.scale * $1.scale }
                let reduction = min(1, sqrt(32_000_000 / max(1, totalPixels)))
                let windows = Self.windowRegions(primaryTop: request.screens.first?.frame.maxY ?? 0)
                self.captureDisplay(request, displays: content.displays, windows: windows,
                                    index: 0, reduction: reduction, frames: [])
            }
        }
    }

    private func captureDisplay(_ request: Request, displays: [SCDisplay], windows: [CGRect],
                                index: Int, reduction: CGFloat, frames: [CaptureFrame]) {
        guard request.ticket.valid else { finish(request, .failure(CaptureFailure.cancelled)); return }
        guard index < request.screens.count else { finish(request, frames.isEmpty ? .failure(CaptureFailure.unavailable) : .success(frames)); return }
        let screen = request.screens[index]
        guard let display = displays.first(where: { $0.displayID == screen.id }) else {
            finish(request, .failure(CaptureFailure.unavailable)); return
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((screen.frame.width * screen.scale * reduction).rounded(.down)))
        configuration.height = max(1, Int((screen.frame.height * screen.scale * reduction).rounded(.down)))
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, error in
            self?.queue.async { [weak self] in
                guard let self else { return }
                guard let image else { self.finish(request, .failure(error ?? CaptureFailure.unavailable)); return }
                guard request.ticket.valid else { self.finish(request, .failure(CaptureFailure.cancelled)); return }
                let sampler = CapturePixelSampler(image: image)
                self.captureDisplay(request, displays: displays, windows: windows, index: index + 1, reduction: reduction,
                                    frames: frames + [CaptureFrame(screen: screen, image: image,
                                                                 windows: windows, sampler: sampler)])
            }
        }
    }

    /// One ordered metadata snapshot per user capture, never an idle scan or AX query.
    private static func windowRegions(primaryTop: CGFloat) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                   kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.prefix(256).compactMap { item in
            guard (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { return nil }
            return CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    private func finish(_ request: Request, _ result: Result<[CaptureFrame], Error>) {
        busy = false
        if request.ticket.valid {
            DispatchQueue.main.async { if request.ticket.valid { request.completion(result) } }
        }
        beginNext()
    }

    static func composite(_ frames: [CaptureFrame], selection: CGRect) -> CGImage? {
        guard !frames.isEmpty,
              [selection.origin.x, selection.origin.y, selection.width, selection.height].allSatisfy(\.isFinite),
              frames.allSatisfy({ frame in
                  let rect = frame.screen.frame
                  return [rect.minX, rect.minY, rect.maxX, rect.maxY, rect.width, rect.height].allSatisfy(\.isFinite)
                      && rect.width > 0 && rect.height > 0 && frame.image.width > 0 && frame.image.height > 0
              }) else { return nil }
        let available = frames.map(\.screen.frame).reduce(CGRect.null) { $0.union($1) }
        let region = selection.standardized.intersection(available)
        let nativeScale = frames.map { CGFloat($0.image.width) / $0.screen.frame.width }.max() ?? 0
        let verticalScale = frames.map { CGFloat($0.image.height) / $0.screen.frame.height }.max() ?? 0
        // Match Selection.step's direct division: the reciprocal of the image
        // scale can round one ULP above an otherwise valid one-pixel region.
        let minimumWidth = frames.map { $0.screen.frame.width / CGFloat($0.image.width) }.min() ?? 0
        let minimumHeight = frames.map { $0.screen.frame.height / CGFloat($0.image.height) }.min() ?? 0
        guard !region.isNull,
              [region.minX, region.minY, region.maxX, region.maxY, region.width, region.height,
               nativeScale, verticalScale, minimumWidth, minimumHeight].allSatisfy(\.isFinite),
              nativeScale > 0, verticalScale > 0, minimumWidth > 0, minimumHeight > 0,
              region.width >= minimumWidth, region.height >= minimumHeight else { return nil }
        let area = region.width * region.height
        guard area.isFinite, area > 0 else { return nil }
        let scale = min(nativeScale, sqrt(CGFloat(CaptureRaster.maximumPixels) / area))
        let scaledWidth = region.width * scale, scaledHeight = region.height * scale
        guard scale.isFinite, scale > 0, scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth > 0, scaledHeight > 0, scaledWidth <= 16_000, scaledHeight <= 16_000 else { return nil }
        // Rounding upward could exceed the pixel ceiling by one output row.
        let width = max(1, Int(scaledWidth.rounded(.down)))
        let height = max(1, Int(scaledHeight.rounded(.down)))
        guard let context = CaptureRaster.context(width: width, height: height) else { return nil }
        for frame in frames {
            let overlap = region.intersection(frame.screen.frame)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let sx = CGFloat(frame.image.width) / frame.screen.frame.width
            let sy = CGFloat(frame.image.height) / frame.screen.frame.height
            let pixels = CGRect(x: (overlap.minX - frame.screen.frame.minX) * sx,
                                y: (frame.screen.frame.maxY - overlap.maxY) * sy,
                                width: overlap.width * sx, height: overlap.height * sy).integral
            guard let piece = frame.image.cropping(to: pixels) else { continue }
            context.draw(piece, in: CGRect(x: (overlap.minX - region.minX) * scale,
                                          y: (overlap.minY - region.minY) * scale,
                                          width: overlap.width * scale, height: overlap.height * scale))
        }
        return context.makeImage()
    }
}

enum CaptureRaster {
    static let maximumPixels = 16_000_000
    static func context(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0, width <= 16_000, height <= 16_000,
              width <= maximumPixels / height else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                         space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }
    static func downsample(_ image: CGImage, maximumPixels: Int) -> CGImage? {
        let total = image.width * image.height
        guard total > maximumPixels else { return image }
        let scale = sqrt(Double(maximumPixels) / Double(total))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = context(width: width, height: height) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
