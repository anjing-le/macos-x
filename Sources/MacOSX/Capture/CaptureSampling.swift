import AppKit

struct CapturePixelSample: Equatable {
    let pixelX: Int, pixelY: Int
    let red: UInt8, green: UInt8, blue: UInt8
    var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }
}

/// Initialise on the capture worker. Frozen desktop screenshots can retain the
/// immutable image and convert only a 64x64 sRGB tile, instead of delaying F1
/// with a full-screen colour conversion. Other image clients keep the full raster.
final class CapturePixelSampler: @unchecked Sendable {
    let width: Int, height: Int, byteCount: Int
    private let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>
    private let source: CGImage?
    private let rasterWidth: Int, rasterHeight: Int
    private var tileOrigin: CGPoint?
    private let lock = NSLock()

    init?(image: CGImage, maximumBytes: Int = 128_000_000, tiled: Bool = false) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_000, height <= 16_000,
              maximumBytes >= 4, width <= maximumBytes / 4 / height else { return nil }
        let rasterWidth = tiled ? min(64,width) : width, rasterHeight = tiled ? min(64,height) : height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: rasterWidth, height: rasterHeight, bitsPerComponent: 8,
                  bytesPerRow: rasterWidth * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .none
        if !tiled { context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
        self.width = width; self.height = height; byteCount = rasterWidth * rasterHeight * 4
        self.context = context; pixels = data.assumingMemoryBound(to: UInt8.self)
        source = tiled ? image : nil; tileOrigin = tiled ? nil : .zero
        self.rasterWidth = rasterWidth; self.rasterHeight = rasterHeight
    }

    /// The lock covers both tile replacement and reads. Cropping the immutable
    /// native screenshot limits conversion to a small region, including ICC and alpha.
    private func prepareTile(x: Int,y: Int,radius: Int = 16) -> Bool {
        guard let source else { return true }
        let wanted = CGRect(x: max(0,x-radius),y: max(0,y-radius),
            width: min(width-1,x+radius)-max(0,x-radius)+1,height: min(height-1,y+radius)-max(0,y-radius)+1)
        if let tileOrigin, CGRect(origin: tileOrigin,size: CGSize(width: rasterWidth,height: rasterHeight)).contains(wanted) { return true }
        let origin = CGPoint(x: min(max(0,x-rasterWidth/2),width-rasterWidth),y: min(max(0,y-rasterHeight/2),height-rasterHeight))
        guard let patch = source.cropping(to: CGRect(origin: origin,size: CGSize(width: rasterWidth,height: rasterHeight))) else { return false }
        let bounds = CGRect(x: 0,y: 0,width: rasterWidth,height: rasterHeight)
        context.clear(bounds); context.draw(patch,in: bounds)
        tileOrigin = origin
        return true
    }

    /// Coordinates use CGImage's top-left origin, including on negative-origin displays.
    static func pixelPosition(globalPoint: CGPoint, in frame: CGRect, width: Int, height: Int) -> CGPoint? {
        guard width > 0, height > 0, frame.width > 0, frame.height > 0,
              globalPoint.x.isFinite, globalPoint.y.isFinite, frame.contains(globalPoint) else { return nil }
        return CGPoint(x: min(width - 1, max(0, Int(floor((globalPoint.x - frame.minX) * CGFloat(width) / frame.width)))),
                       y: min(height - 1, max(0, Int(floor((frame.maxY - globalPoint.y) * CGFloat(height) / frame.height)))))
    }

    func sample(globalPoint: CGPoint, in frame: CGRect) -> CapturePixelSample? {
        guard let point = Self.pixelPosition(globalPoint: globalPoint, in: frame, width: width, height: height) else { return nil }
        return sample(x: Int(point.x), y: Int(point.y))
    }

    func sample(x: Int, y: Int) -> CapturePixelSample? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard prepareTile(x: x,y: y), let origin = tileOrigin else { return nil }
        let offset = ((y-Int(origin.y)) * rasterWidth + x-Int(origin.x)) * 4, alpha = Int(pixels[offset + 3])
        func channel(_ i: Int) -> UInt8 {
            alpha == 0 ? 0 : UInt8(min(255, (Int(pixels[offset + i]) * 255 + alpha / 2) / alpha))
        }
        return .init(pixelX: x, pixelY: y, red: channel(0), green: channel(1), blue: channel(2))
    }

    /// Fixed small patch, padded at display edges. The picked pixel stays in the centre.
    func magnifier(sample: CapturePixelSample, radius: Int = 5) -> CGImage? {
        guard radius >= 0, radius <= 16, sample.pixelX >= 0, sample.pixelX < width,
              sample.pixelY >= 0, sample.pixelY < height else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard prepareTile(x: sample.pixelX,y: sample.pixelY,radius: radius), let origin = tileOrigin else { return nil }
        let edge = radius * 2 + 1
        var patch = [UInt8](repeating: 0, count: edge * edge * 4)
        for y in 0..<edge {
            for x in 0..<edge {
                let sourceX = min(width - 1, max(0, sample.pixelX + x - radius))
                let sourceY = min(height - 1, max(0, sample.pixelY + y - radius))
                let source = ((sourceY-Int(origin.y)) * rasterWidth + sourceX-Int(origin.x)) * 4, target = (y * edge + x) * 4
                for c in 0..<4 { patch[target + c] = pixels[source + c] }
            }
        }
        guard let provider = CGDataProvider(data: Data(patch) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Selection adjustments are in screenshot pixels, converted to global AppKit points.
enum CaptureSelectionGeometry {
    /// Snap both edges to the frozen raster, so editor points map exactly to pixels.
    static func pixelAligned(_ rect:CGRect, in frame:CGRect, width:Int, height:Int) -> CGRect {
        guard width > 0, height > 0, frame.width > 0, frame.height > 0 else { return rect }
        let sx = CGFloat(width)/frame.width, sy = CGFloat(height)/frame.height
        let x0 = ((rect.minX-frame.minX)*sx).rounded(), x1 = ((rect.maxX-frame.minX)*sx).rounded()
        let y0 = ((rect.minY-frame.minY)*sy).rounded(), y1 = ((rect.maxY-frame.minY)*sy).rounded()
        guard x1>x0, y1>y0 else { return rect }
        return clamped(CGRect(x:frame.minX+x0/sx,y:frame.minY+y0/sy,width:(x1-x0)/sx,height:(y1-y0)/sy),to:frame)
    }
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              !bounds.isNull, !bounds.isInfinite, bounds.minX.isFinite, bounds.minY.isFinite, bounds.width.isFinite, bounds.height.isFinite else { return .null }
        let value = rect.standardized.intersection(bounds)
        return value.isNull || value.width <= 0 || value.height <= 0 ? .null : value
    }
    static func moved(_ rect: CGRect, dx: CGFloat, dy: CGFloat, in bounds: CGRect) -> CGRect {
        guard !rect.isNull else { return .null }
        return CGRect(x: min(max(bounds.minX, rect.minX + dx), bounds.maxX - rect.width),
                      y: min(max(bounds.minY, rect.minY + dy), bounds.maxY - rect.height),
                      width: rect.width, height: rect.height)
    }
    static func adjusted(_ rect: CGRect, key: UInt16, enlarge: Bool, step: CGSize, in bounds: CGRect) -> CGRect {
        guard !rect.isNull else { return .null }
        var x0 = rect.minX, x1 = rect.maxX, y0 = rect.minY, y1 = rect.maxY
        switch key {
        case 123: if enlarge { x0 -= step.width } else { x0 += step.width }
        case 124: if enlarge { x1 += step.width } else { x1 -= step.width }
        case 125: if enlarge { y0 -= step.height } else { y0 += step.height }
        case 126: if enlarge { y1 += step.height } else { y1 -= step.height }
        default: return rect
        }
        guard x1 - x0 >= step.width, y1 - y0 >= step.height else { return rect }
        return clamped(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), to: bounds)
    }
}
