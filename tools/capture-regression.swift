import AppKit

// Standalone: compile with CaptureSampling.swift; no app launch, screen access,
// pasteboard writes, or permission requests. Expected colors and rectangles are
// fixtures, not computed by the sampling/geometry functions under test.
private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

private struct Checks {
    var assertions = 0
    mutating func require(_ value: @autoclosure () -> Bool, _ description: String) throws {
        assertions += 1
        guard value() else { throw RegressionFailure(description: description) }
    }
    mutating func color(_ sample: CapturePixelSample?, _ expected: (Int, Int, Int),
                        tolerance: Int = 0, _ description: String) throws {
        guard let sample else { throw RegressionFailure(description: "\(description): no sample") }
        try require(abs(Int(sample.red) - expected.0) <= tolerance &&
                    abs(Int(sample.green) - expected.1) <= tolerance &&
                    abs(Int(sample.blue) - expected.2) <= tolerance,
                    "\(description): got \(sample.hex), expected \(expected) ±\(tolerance)")
    }
    mutating func rect(_ actual: CGRect, _ expected: CGRect, _ description: String) throws {
        let epsilon: CGFloat = 0.000_001
        try require(abs(actual.minX - expected.minX) < epsilon &&
                    abs(actual.minY - expected.minY) < epsilon &&
                    abs(actual.width - expected.width) < epsilon &&
                    abs(actual.height - expected.height) < epsilon,
                    "\(description): got \(actual), expected \(expected)")
    }
}

@main
private struct CaptureRegression {
    static func main() {
        do {
            var checks = Checks()
            try orientationAndMagnifier(&checks)
            try colorSpaceAndAlpha(&checks)
            try globalMappingAndLimits(&checks)
            try selectionGeometry(&checks)
            print("PASS capture regression: \(checks.assertions) assertions; orientation, sRGB/P3, alpha, Retina/negative origins, downsample mapping, edge patches, byte limits, and pixel geometry")
        } catch {
            FileHandle.standardError.write(Data("FAIL capture regression: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func image(width: Int, height: Int, rgba: [UInt8], space: CGColorSpace) -> CGImage {
        precondition(rgba.count == width * height * 4)
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private static func bitmapPixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) -> [UInt] {
        var channels = [UInt](repeating: 0, count: bitmap.samplesPerPixel)
        channels.withUnsafeMutableBufferPointer { bitmap.getPixel($0.baseAddress!, atX: x, y: y) }
        return channels
    }

    // Quartz drawing uses a lower-left origin. This fixture visibly places red
    // at top-left and blue at bottom-right; an inverted sampler fails these
    // assertions even if its coordinate mapper and magnifier share that bug.
    private static func quadrantImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                bytesPerRow: 16, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        for (rect, components) in [
            (CGRect(x: 0, y: 2, width: 2, height: 2), [CGFloat(1), 0, 0, 1]),
            (CGRect(x: 2, y: 2, width: 2, height: 2), [CGFloat(0), 1, 0, 1]),
            (CGRect(x: 0, y: 0, width: 2, height: 2), [CGFloat(1), 1, 0, 1]),
            (CGRect(x: 2, y: 0, width: 2, height: 2), [CGFloat(0), 0, 1, 1])
        ] {
            context.setFillColor(CGColor(colorSpace: space, components: components)!)
            context.fill(rect)
        }
        return context.makeImage()!
    }

    private static func orientationAndMagnifier(_ checks: inout Checks) throws {
        let source = quadrantImage(), sampler = CapturePixelSampler(image: source)!
        for y in 0..<4 {
            for x in 0..<4 {
                let expected = y < 2 ? (x < 2 ? (255, 0, 0) : (0, 255, 0))
                                     : (x < 2 ? (255, 255, 0) : (0, 0, 255))
                try checks.color(sampler.sample(x: x, y: y), expected, "visual quadrant (\(x),\(y))")
            }
        }
        let bitmap = NSBitmapImageRep(cgImage: source)
        let topColor = bitmapPixel(bitmap, x: 0, y: 0)
        let bottom = bitmapPixel(bitmap, x: 3, y: 3)
        try checks.require(topColor[0] == 255 && topColor[1] == 0 && topColor[2] == 0,
                           "independent bitmap reader must see red top-left")
        try checks.require(bottom[0] == 0 && bottom[1] == 0 && bottom[2] == 255,
                           "independent bitmap reader must see blue bottom-right, got \(bottom)")
        for (x, y, expected) in [(0, 0, (255, 0, 0)), (3, 3, (0, 0, 255))] {
            let sample = sampler.sample(x: x, y: y)!
            let patch = sampler.magnifier(sample: sample, radius: 2)!
            try checks.require(patch.width == 5 && patch.height == 5, "edge patch is always 5×5")
            let patchBitmap = NSBitmapImageRep(cgImage: patch)
            // Read the patch through AppKit, independently of CapturePixelSampler.
            for py in (y == 0 ? 0...2 : 2...4) {
                for px in (x == 0 ? 0...2 : 2...4) {
                    let color = bitmapPixel(patchBitmap, x: px, y: py)
                    try checks.require(Int(color[0]) == expected.0 && Int(color[1]) == expected.1 && Int(color[2]) == expected.2,
                                       "edge padding preserves center/edge color at \(px),\(py)")
                }
            }
        }
        let top = sampler.sample(x: 0, y: 0)!
        try checks.require(sampler.magnifier(sample: top, radius: -1) == nil, "negative radius rejected")
        try checks.require(sampler.magnifier(sample: top, radius: 17) == nil, "oversized radius rejected")
        let largest = sampler.magnifier(sample: top, radius: 16)!
        try checks.require(largest.width == 33 && largest.height == 33, "maximum patch remains bounded")
        let smallest = CapturePixelSampler(image: sampler.magnifier(sample: top, radius: 0)!)!
        try checks.color(smallest.sample(x: 0, y: 0), (255, 0, 0), "radius zero retains picked pixel")
        print("PASS orientation: red top-left / blue bottom-right; fixed centered edge patches")
    }

    private static func colorSpaceAndAlpha(_ checks: inout Checks) throws {
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!, p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        // Independent colorimetric golden values, derived from W3C CSS Color 4
        // Display-P3 → D65 XYZ → sRGB matrices and transfer curves, not the
        // sampler's CGContext raster or byte access. Allow 2 levels for ICC
        // profile/8-bit rounding. The first two must differ from raw P3 bytes.
        // https://www.w3.org/TR/css-color-4/#color-conversion-code
        for (source, expected) in [([UInt8(153), 77, 51, 255], (164, 72, 43)),
                                   ([UInt8(64), 128, 192, 255], (32, 130, 197)),
                                   ([UInt8(128), 128, 128, 255], (128, 128, 128))] {
            let srgb = CapturePixelSampler(image: image(width: 1, height: 1, rgba: source, space: rgb))!
            let converted = CapturePixelSampler(image: image(width: 1, height: 1, rgba: source, space: p3))!
            try checks.color(srgb.sample(x: 0, y: 0), (Int(source[0]), Int(source[1]), Int(source[2])), "sRGB byte preservation")
            try checks.color(converted.sample(x: 0, y: 0), expected, tolerance: 2, "Display-P3 converted to sRGB")
            if source[0] != 128 {
                try checks.require(converted.sample(x: 0, y: 0) != srgb.sample(x: 0, y: 0), "P3 must not be interpreted as raw sRGB bytes")
            }
        }
        let translucent = image(width: 2, height: 1, rgba: [128, 64, 32, 128, 200, 100, 50, 0], space: rgb)
        let sampler = CapturePixelSampler(image: translucent)!
        try checks.color(sampler.sample(x: 0, y: 0), (128, 64, 32), tolerance: 1, "premultiplication must be undone for color value")
        try checks.color(sampler.sample(x: 1, y: 0), (0, 0, 0), "zero alpha is defined black without divide-by-zero")
        let red = CapturePixelSampler(image: quadrantImage())!.sample(x: 0, y: 0)!
        try checks.require(red.hex == "#FF0000" && red.rgb == "rgb(255, 0, 0)", "RGB and uppercase HEX formatting")
        print("PASS color: sRGB bytes, independent Display-P3 conversion goldens, and transparent alpha")
    }

    private static func globalMappingAndLimits(_ checks: inout Checks) throws {
        let sampler = CapturePixelSampler(image: quadrantImage())!
        let retina = CGRect(x: -400, y: -200, width: 2, height: 2)
        let upperLeft = sampler.sample(globalPoint: CGPoint(x: -399.75, y: -198.25), in: retina)
        try checks.color(upperLeft, (255, 0, 0), "negative-origin 2× Retina upper-left")
        try checks.require(upperLeft?.pixelX == 0 && upperLeft?.pixelY == 0, "2× top-left actual pixel identity")
        let lowerRight = sampler.sample(globalPoint: CGPoint(x: -398.25, y: -199.75), in: retina)
        try checks.color(lowerRight, (0, 0, 255), "negative-origin 2× Retina lower-right")
        try checks.require(lowerRight?.pixelX == 3 && lowerRight?.pixelY == 3, "2× bottom-right actual pixel identity")
        try checks.color(sampler.sample(globalPoint: CGPoint(x: -400, y: -200), in: retina), (255, 255, 0), "bottom/left edge clamps to last/first pixel")
        for point in [CGPoint(x: -401, y: -199), CGPoint(x: -399, y: -197),
                      CGPoint(x: CGFloat.nan, y: -199), CGPoint(x: -399, y: CGFloat.infinity)] {
            try checks.require(sampler.sample(globalPoint: point, in: retina) == nil, "outside/nonfinite coordinates rejected")
        }
        for (x, y) in [(-1, 0), (0, -1), (4, 0), (0, 4)] {
            try checks.require(sampler.sample(x: x, y: y) == nil, "out-of-raster pixel rejected")
        }
        let downsampled = CGRect(x: -1200, y: 300, width: 400, height: 600)
        // A captured 800×1200 display reduced to 100×150 has one output pixel
        // per 4 global points, regardless of the original 2× screen scale.
        try checks.require(CapturePixelSampler.pixelPosition(globalPoint: CGPoint(x: -1198, y: 898), in: downsampled, width: 100, height: 150) == CGPoint(x: 0, y: 0), "downsampled top-left maps with image dimensions")
        try checks.require(CapturePixelSampler.pixelPosition(globalPoint: CGPoint(x: -802, y: 302), in: downsampled, width: 100, height: 150) == CGPoint(x: 99, y: 149), "downsampled bottom-right maps with image dimensions")
        try checks.require(CapturePixelSampler.pixelPosition(globalPoint: CGPoint(x: -1000, y: 600), in: downsampled, width: 100, height: 150) == CGPoint(x: 50, y: 75), "downsampled center pixel identity")
        var reducedPixels = [UInt8](repeating: 255, count: 100 * 150 * 4)
        reducedPixels.replaceSubrange(0..<4, with: [255, 0, 0, 255])
        reducedPixels.replaceSubrange((reducedPixels.count - 4)..<reducedPixels.count, with: [0, 0, 255, 255])
        let reduced = CapturePixelSampler(image: image(width: 100, height: 150, rgba: reducedPixels, space: CGColorSpace(name: CGColorSpace.sRGB)!))!
        try checks.color(reduced.sample(globalPoint: CGPoint(x: -1198, y: 898), in: downsampled), (255, 0, 0), "reduced raster actual top-left pixel")
        try checks.color(reduced.sample(globalPoint: CGPoint(x: -802, y: 302), in: downsampled), (0, 0, 255), "reduced raster actual bottom-right pixel")
        try checks.color(reduced.sample(globalPoint: CGPoint(x: -1000, y: 600), in: downsampled), (255, 255, 255), "reduced raster actual center pixel")
        try checks.require(CapturePixelSampler.pixelPosition(globalPoint: .zero, in: .zero, width: 100, height: 150) == nil, "empty frame rejected")
        let source = image(width: 3, height: 2, rgba: [UInt8](repeating: 255, count: 24), space: CGColorSpace(name: CGColorSpace.sRGB)!)
        try checks.require(CapturePixelSampler(image: source, maximumBytes: 24)?.byteCount == 24, "exact byte ceiling accepted")
        try checks.require(CapturePixelSampler(image: source, maximumBytes: 23) == nil, "one byte below required ceiling rejected")
        try checks.require(CapturePixelSampler(image: source, maximumBytes: 0) == nil, "zero byte ceiling rejected")
        let tooWide = image(width: 16001, height: 1, rgba: [UInt8](repeating: 255, count: 64004), space: CGColorSpace(name: CGColorSpace.sRGB)!)
        try checks.require(CapturePixelSampler(image: tooWide) == nil, "dimension cap enforced independently of byte cap")
        print("PASS mapping: 2× Retina, negative origins, reduced-image coordinates, edges, and byte ceiling")
    }

    private static func selectionGeometry(_ checks: inout Checks) throws {
        let bounds = CGRect(x: -200, y: -100, width: 80, height: 60)
        let rect = CGRect(x: -190, y: -90, width: 20, height: 10), step = CGSize(width: 0.5, height: 0.5)
        try checks.rect(CaptureSelectionGeometry.clamped(CGRect(x: -205, y: -110, width: 15, height: 20), to: bounds), CGRect(x: -200, y: -100, width: 10, height: 10), "clamp negative-origin overlap")
        try checks.require(CaptureSelectionGeometry.clamped(CGRect(x: 0, y: 0, width: 2, height: 2), to: bounds).isNull, "disjoint clamp is null")
        try checks.require(CaptureSelectionGeometry.clamped(.null, to: bounds).isNull, "null clamp is null")
        try checks.rect(CaptureSelectionGeometry.moved(rect, dx: 0.5, dy: -0.5, in: bounds), CGRect(x: -189.5, y: -90.5, width: 20, height: 10), "move exactly one 2× screenshot pixel")
        try checks.rect(CaptureSelectionGeometry.moved(rect, dx: 1000, dy: 1000, in: bounds), CGRect(x: -140, y: -50, width: 20, height: 10), "move clamps at upper-right")
        try checks.rect(CaptureSelectionGeometry.moved(rect, dx: -1000, dy: -1000, in: bounds), CGRect(x: -200, y: -100, width: 20, height: 10), "move clamps at lower-left")
        let cases: [(UInt16, CGRect, CGRect)] = [
            (123, CGRect(x: -190.5, y: -90, width: 20.5, height: 10), CGRect(x: -189.5, y: -90, width: 19.5, height: 10)),
            (124, CGRect(x: -190, y: -90, width: 20.5, height: 10), CGRect(x: -190, y: -90, width: 19.5, height: 10)),
            (125, CGRect(x: -190, y: -90.5, width: 20, height: 10.5), CGRect(x: -190, y: -89.5, width: 20, height: 9.5)),
            (126, CGRect(x: -190, y: -90, width: 20, height: 10.5), CGRect(x: -190, y: -90, width: 20, height: 9.5))
        ]
        for (key, enlarged, shrunk) in cases {
            try checks.rect(CaptureSelectionGeometry.adjusted(rect, key: key, enlarge: true, step: step, in: bounds), enlarged, "enlarge key \(key) by one actual pixel")
            try checks.rect(CaptureSelectionGeometry.adjusted(rect, key: key, enlarge: false, step: step, in: bounds), shrunk, "shrink key \(key) by one actual pixel")
            try checks.rect(CaptureSelectionGeometry.adjusted(bounds, key: key, enlarge: true, step: step, in: bounds), bounds, "enlarge remains inside bounds")
            let onePixel = CGRect(x: -190, y: -90, width: 0.5, height: 0.5)
            try checks.rect(CaptureSelectionGeometry.adjusted(onePixel, key: key, enlarge: false, step: step, in: bounds), onePixel, "cannot shrink below one actual pixel")
        }
        try checks.rect(CaptureSelectionGeometry.adjusted(rect, key: 36, enlarge: true, step: step, in: bounds), rect, "unrelated key leaves geometry unchanged")
        try checks.rect(CaptureSelectionGeometry.adjusted(rect, key: 124, enlarge: true, step: CGSize(width: 4, height: 4), in: bounds), CGRect(x: -190, y: -90, width: 24, height: 10), "reduced capture adjusts by one output pixel, four global points")
        print("PASS selection: clamp/move and all four enlarge/shrink directions by one actual pixel")
    }
}
