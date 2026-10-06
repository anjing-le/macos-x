import AppKit
import CoreGraphics
import Foundation
import ImageIO

@main
struct RasterFixture {
    static func main() {
        var checks = 0
        func check(_ ok: Bool, _ message: String) { precondition(ok, message); checks += 1 }
        let original = CGRect(x: -400, y: 30, width: 320, height: 180)
        var drag = CapturePinDrag(anchor: CGPoint(x: -300, y: 100), original: original)
        check(drag.frame(at: CGPoint(x: -300, y: 100)) == nil, "Focus click must not move a pin")
        check(drag.frame(at: CGPoint(x: -298, y: 101)) == nil, "Small click jitter must not start a move")
        check(drag.frame(at: CGPoint(x: -295, y: 104)) == original.offsetBy(dx: 5, dy: 4), "Drag uses original global anchor")
        check(drag.frame(at: CGPoint(x: -299, y: 100)) == original.offsetBy(dx: 1, dy: 0), "Active drag can return inside threshold")
        check(drag.frame(at: CGPoint(x: CGFloat.infinity, y: 100)) == nil, "Invalid drag points cannot reposition a window")
        let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255],
                                 [255,255,0,255], [255,0,255,255], [0,255,255,255]]
        let data = Data(colors.flatMap { $0 })
        let image = CGImage(width: 3, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 12,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        func pixels(_ image: CGImage) -> [[UInt8]] {
            let sampler = CapturePixelSampler(image: image)!
            return (0..<image.height).flatMap { y in (0..<image.width).map { x in
                let c = sampler.sample(x: x, y: y)!
                return [c.red, c.green, c.blue, 255]
            }}
        }
        check(pixels(image) == colors, "Fixture and sampler must agree on top-left pixel rows")
        func rotated(_ grid: [[UInt8]], width: Int, height: Int, clockwise: Bool) -> [[UInt8]] {
            var result = [[UInt8]](repeating: [], count: grid.count)
            for y in 0..<height { for x in 0..<width {
                let nx = clockwise ? height - 1 - y : y
                let ny = clockwise ? x : width - 1 - x
                result[ny * height + nx] = grid[y * width + x]
            }}
            return result
        }
        for turns in 0..<4 { for horizontal in [false, true] { for vertical in [false, true] {
            let transform = CapturePinTransform(turns: turns, horizontalFlip: horizontal, verticalFlip: vertical)
            let output = transform.render(image)!
            var expected = colors, width = 3, height = 2
            for _ in 0..<turns { expected = rotated(expected, width: width, height: height, clockwise: true); swap(&width, &height) }
            var mirrored = expected
            for y in 0..<height { for x in 0..<width {
                mirrored[y * width + x] = expected[(vertical ? height - 1 - y : y) * width + (horizontal ? width - 1 - x : x)]
            }}
            check(output.width == width && output.height == height, "Quarter turns preserve pixel size")
            check(pixels(output) == mirrored, "Display/export orientation differs for turns \(turns), h \(horizontal), v \(vertical)")
            let bounds = CGRect(x: -100, y: -75, width: width * 100, height: height * 100)
            for y in 0..<height { for x in 0..<width {
                let point = CGPoint(x: bounds.minX + (CGFloat(x) + 0.5) * 100,
                                    y: bounds.maxY - (CGFloat(y) + 0.5) * 100)
                let original = transform.pixel(at: point, in: bounds, image: image)!
                check(colors[Int(original.y) * 3 + Int(original.x)] == mirrored[y * width + x], "Inverse sample must match exported pixel")
            }}
            check(transform.pixel(at: CGPoint(x: bounds.minX - 1, y: bounds.midY), in: bounds, image: image) == nil, "Outside image cannot sample")
        }}}
        var transform = CapturePinTransform(horizontalFlip: true)
        let before = pixels(transform.render(image)!)
        transform.rotate(clockwise: true)
        check(pixels(transform.render(image)!) == rotated(before, width: 3, height: 2, clockwise: true), "Rotation must rotate the already-reflected display")
        for _ in 0..<3 { transform.rotate(clockwise: true) }
        check(pixels(transform.render(image)!) == before, "Four turns restore reflected content")
        transform.rotate(clockwise: false); transform.rotate(clockwise: true)
        check(pixels(transform.render(image)!) == before, "Clockwise and counterclockwise are inverse")

        for text in ["#A1B2C3", "#a1b2c3", "rgb(161, 178, 195)", " RGB(161,178,195)\n"] {
            let color = CaptureClipboardColor(text: text)!
            check(color.hex == "#A1B2C3" && color.rgb == "rgb(161, 178, 195)", "Parse hex/RGB")
            let card = color.card()!, sampler = CapturePixelSampler(image: card)!
            check(card.width == 320 && card.height == 160, "Color card stays bounded")
            check(sampler.sample(x: 100, y: 20)!.hex == "#A1B2C3", "Color clipboard renders a real swatch")
            check(sampler.sample(x: 5, y: 155)!.hex == "#FFFFFF", "Color card has a readable label area")
        }
        for invalid in ["#A1B2C", "#GGGGGG", "rgb(256,1,2)", "rgb(-1,1,2)", "rgb(1,2)", "rgb(1,2,3) suffix", "#123456 extra"] {
            check(CaptureClipboardColor(text: invalid) == nil, "Invalid color cannot masquerade as a swatch")
        }
        check(CaptureClipboard.text("short phrase") != nil, "Text clipboard card")
        let textCard = CaptureClipboard.text("Hello macos-x\n截图文字测试\n\nSecond paragraph")!
        let textPixels = CapturePixelSampler(image: textCard)!
        check(textCard.width == 622 && textCard.height >= 112, "Text card leaves generous bounded space")
        for point in [(2, 2), (20, 20), (textCard.width - 20, textCard.height - 20)] {
            check(textPixels.sample(x: point.0, y: point.1)!.hex == "#FFFFFF", "Text card background and padding stay white")
        }
        check(CaptureClipboard.text(String(repeating: "x", count: 4097)) == nil, "Text cap")
        // ImageIO creates the fixture input; decoding and transforms call production code.
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        check(CGImageDestinationFinalize(destination), "Encode PNG fixture input")
        let decoded = CaptureClipboard.image(from: encoded as Data)!
        check(decoded.width == 3 && decoded.height == 2 && pixels(decoded) == colors, "PNG fixture decodes without orientation/color loss")
        check(CaptureRaster.downsample(image, maximumPixels: 4)!.width * CaptureRaster.downsample(image, maximumPixels: 4)!.height <= 4, "Pin pixel budget")
        print("PASS: \(checks) raster/color/transform checks; no windows, clipboard writes or permissions")
    }
}
