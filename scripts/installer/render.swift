import AppKit

@main struct InstallerArtwork {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), layoutURL = URL(fileURLWithPath: CommandLine.arguments[2]), output = URL(fileURLWithPath: CommandLine.arguments[3])
        let layout = try JSONSerialization.jsonObject(with: Data(contentsOf: layoutURL)) as! [String: Any]
        let width = layout["width"] as! Int, height = layout["height"] as! Int, iconSize = layout["iconSize"] as! Int
        let app = layout["app"] as! [Int], applications = layout["applications"] as! [Int]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard let background = NSImage(contentsOf: layoutURL.deletingLastPathComponent().appendingPathComponent("Background.png")) else { throw CocoaError(.fileReadCorruptFile) }
        func render(scale: Int, preview: Bool = false) throws -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: width, height: height)
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = context
            // NSGraphicsContext already maps rep.size to the backing pixels.
            // Applying scale again doubles Retina geometry.
            context.cgContext.translateBy(x: 0, y: CGFloat(height)); context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            background.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            if preview {
                let appImage = NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns"))
                let folder = NSWorkspace.shared.icon(forFile: "/Applications")
                for (image, point, label) in [(appImage!, app, "MacOSX"), (folder, applications, "Applications")] {
                    let rect = CGRect(x: point[0] - iconSize / 2, y: point[1] - iconSize / 2, width: iconSize, height: iconSize)
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    let style = NSMutableParagraphStyle(); style.alignment = .center
                    (label as NSString).draw(in: CGRect(x: point[0] - 90, y: point[1] + iconSize / 2 + 8, width: 180, height: 24), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
                }
            }
            context.flushGraphics()
            return rep.representation(using: .png, properties: [:])!
        }
        func arrowBounds(_ data: Data) -> CGRect {
            let bitmap = NSBitmapImageRep(data: data)!, image = bitmap.cgImage!
            let rgba = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            rgba.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let bytes = rgba.data!.assumingMemoryBound(to: UInt8.self)
            var left = image.width, right = -1, top = image.height, bottom = -1
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = y * rgba.bytesPerRow + x * 4
                    if Int(bytes[offset + 2]) - Int(bytes[offset]) > 20 && Int(bytes[offset + 2]) - Int(bytes[offset + 1]) > 8 {
                        left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
        let standard = try render(scale: 1), retina = try render(scale: 2)
        let a = arrowBounds(standard), raw = arrowBounds(retina)
        let b = CGRect(x: raw.minX / 2, y: raw.minY / 2, width: raw.width / 2, height: raw.height / 2)
        guard abs(a.minX - b.minX) <= 2, abs(a.minY - b.minY) <= 2, abs(a.width - b.width) <= 3, abs(a.height - b.height) <= 3,
              a.minX > CGFloat(app[0] + iconSize / 2), a.maxX < CGFloat(applications[0] - iconSize / 2),
              abs(NSImage(data: retina)!.size.width - CGFloat(width)) < 1 else {
            throw NSError(domain: "Installer backgrounds must align with native icon points at 1x and 2x", code: 1)
        }
        try standard.write(to: output.appendingPathComponent("background.png"))
        try retina.write(to: output.appendingPathComponent("background@2x.png"))
        try render(scale: 1, preview: true).write(to: output.appendingPathComponent("preview.png"))
    }
}
