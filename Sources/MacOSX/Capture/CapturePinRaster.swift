import CoreGraphics
import AppKit
import CoreText
import Foundation
import ImageIO

/// A focus click must never start a window move. Coordinates are global points,
/// so the anchor stays stable while the window itself moves between events.
struct CapturePinDrag {
    let anchor: CGPoint
    let original: CGRect
    private(set) var moving = false
    mutating func frame(at point: CGPoint) -> CGRect? {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        guard dx.isFinite, dy.isFinite else { return nil }
        if !moving { moving = hypot(dx, dy) >= 3 }
        return moving ? original.offsetBy(dx: dx, dy: dy) : nil
    }
}

/// Rotation and reflections are expressed in the displayed image's axes.
/// The same matrix is used by the view, export and inverse pixel sampling.
struct CapturePinTransform: Equatable {
    var turns = 0
    var horizontalFlip = false
    var verticalFlip = false

    mutating func rotate(clockwise: Bool) {
        turns = (turns + (clockwise ? 1 : 3)) % 4
        swap(&horizontalFlip, &verticalFlip)
    }
    func outputSize(for image: CGImage) -> CGSize {
        turns % 2 == 0 ? CGSize(width: image.width, height: image.height)
            : CGSize(width: image.height, height: image.width)
    }
    func matrix(in bounds: CGRect, image: CGImage) -> CGAffineTransform {
        let size = outputSize(for: image)
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
            .scaledBy(x: horizontalFlip ? -scale : scale, y: verticalFlip ? -scale : scale)
            .rotated(by: -CGFloat(turns) * .pi / 2)
            .translatedBy(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2)
    }
    /// Returns CGImage coordinates with a top-left origin, or nil in letterboxing.
    func pixel(at point: CGPoint, in bounds: CGRect, image: CGImage) -> CGPoint? {
        let mapped = point.applying(matrix(in: bounds, image: image).inverted())
        guard mapped.x >= 0, mapped.y >= 0, mapped.x < CGFloat(image.width), mapped.y < CGFloat(image.height) else { return nil }
        return CGPoint(x: floor(mapped.x), y: CGFloat(image.height - 1) - floor(mapped.y))
    }
    func render(_ image: CGImage) -> CGImage? {
        if self == CapturePinTransform(), image.width > 0, image.height > 0,
           image.width <= 4_000_000 / image.height { return image }
        let size = outputSize(for: image)
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0, width <= 4_000_000 / height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.concatenate(matrix(in: CGRect(origin: .zero, size: size), image: image))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

struct CaptureClipboardColor: Equatable {
    let red: UInt8, green: UInt8, blue: UInt8
    var hex: String { String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue)) }
    var rgb: String { "rgb(\(red), \(green), \(blue))" }

    init?(text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 64 else { return nil }
        if value.count == 7, value.first == "#", let number = UInt32(value.dropFirst(), radix: 16) {
            red = UInt8((number >> 16) & 255); green = UInt8((number >> 8) & 255); blue = UInt8(number & 255)
            return
        }
        guard value.lowercased().hasPrefix("rgb("), value.hasSuffix(")") else { return nil }
        let parts = value.dropFirst(4).dropLast().split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let components = parts.compactMap { part -> UInt8? in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt8(trimmed) else { return nil }
            return value
        }
        guard components.count == 3 else { return nil }
        red = components[0]; green = components[1]; blue = components[2]
    }
    func card() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let color = CGColor(colorSpace: space, components: [CGFloat(red) / 255, CGFloat(green) / 255,
                                                               CGFloat(blue) / 255, 1]) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 54, width: 320, height: 106))
        CaptureClipboard.drawText(hex, size: 18, in: CGRect(x: 16, y: 27, width: 288, height: 24), context: context)
        CaptureClipboard.drawText(rgb, size: 12, in: CGRect(x: 16, y: 8, width: 288, height: 18), context: context)
        return context.makeImage()
    }
}

enum CaptureClipboard {
    static func image(from data: Data) -> CGImage? {
        guard data.count <= 64_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return CaptureRaster.downsample(image, maximumPixels: 4_000_000)
    }
    static func text(_ value: String) -> CGImage? {
        guard !value.isEmpty, value.count <= 4096 else { return nil }
        if let color = CaptureClipboardColor(text: value) { return color.card() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        paragraph.paragraphSpacing = 6
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(attributedString: attributedText(value, size: 24))
        attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: 680, height: CGFloat.greatestFiniteMagnitude), nil)
        guard size.height <= 1800, let context = CaptureRaster.context(width: 760, height: max(144, Int(size.height.rounded(.up)) + 80)) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        let path = CGPath(rect: CGRect(x: 40, y: 40, width: 680, height: context.height - 80), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
        return context.makeImage()
    }
    static func drawText(_ text: String, size: CGFloat, in rect: CGRect, context: CGContext) {
        let path = CGPath(rect: rect, transform: nil)
        let setter = CTFramesetterCreateWithAttributedString(attributedText(text, size: size))
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil), context)
    }
    private static func attributedText(_ value: String, size: CGFloat) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.12, alpha: 1)])
    }
}
