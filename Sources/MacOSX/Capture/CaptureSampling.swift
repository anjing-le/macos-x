import AppKit

struct CapturePixelSample: Equatable {
    let pixelX: Int, pixelY: Int
    let red: UInt8, green: UInt8, blue: UInt8
    var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }
}

/// Initialise on the capture worker. Afterwards sampling reads a bounded, immutable
/// sRGB raster; mouse movement never decodes the full screenshot again.
final class CapturePixelSampler: @unchecked Sendable {
    let width: Int, height: Int, byteCount: Int
    private let context: CGContext
    private let pixels: UnsafeMutablePointer<UInt8>

    init?(image: CGImage, maximumBytes: Int = 128_000_000) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 16_000, height <= 16_000,
              maximumBytes >= 4, width <= maximumBytes / 4 / height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width; self.height = height; byteCount = width * height * 4
        self.context = context; pixels = data.assumingMemoryBound(to: UInt8.self)
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
        let offset = (y * width + x) * 4, alpha = Int(pixels[offset + 3])
        func channel(_ i: Int) -> UInt8 {
            alpha == 0 ? 0 : UInt8(min(255, (Int(pixels[offset + i]) * 255 + alpha / 2) / alpha))
        }
        return .init(pixelX: x, pixelY: y, red: channel(0), green: channel(1), blue: channel(2))
    }

    /// Fixed small patch, padded at display edges. The picked pixel stays in the centre.
    func magnifier(sample: CapturePixelSample, radius: Int = 5) -> CGImage? {
        guard radius >= 0, radius <= 16 else { return nil }
        let edge = radius * 2 + 1
        var patch = [UInt8](repeating: 0, count: edge * edge * 4)
        for y in 0..<edge {
            for x in 0..<edge {
                let sourceX = min(width - 1, max(0, sample.pixelX + x - radius))
                let sourceY = min(height - 1, max(0, sample.pixelY + y - radius))
                let source = (sourceY * width + sourceX) * 4, target = (y * edge + x) * 4
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
