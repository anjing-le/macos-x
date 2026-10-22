import AppKit
import CoreText

@main struct InstallerArtwork {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw CocoaError(.fileReadInvalidFileName) }
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: CommandLine.arguments[1]), layoutURL = URL(fileURLWithPath: CommandLine.arguments[2]), output = URL(fileURLWithPath: CommandLine.arguments[3])
        let layout = try JSONSerialization.jsonObject(with: Data(contentsOf: layoutURL)) as! [String: Any]
        let width = layout["width"] as! Int, height = layout["height"] as! Int, iconSize = layout["iconSize"] as! Int
        let app = layout["app"] as! [Int], applications = layout["applications"] as! [Int]
        CTFontManagerRegisterFontsForURL(resources.appendingPathComponent("SketchFont.ttf") as CFURL, .process, nil)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let paper = NSImage(contentsOf: resources.appendingPathComponent("SketchPaper.png"))
        func render(scale: Int, preview: Bool = false) throws -> Data {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: width, height: height)
            NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            context.cgContext.translateBy(x: 0, y: CGFloat(height)); context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            SketchPalette.paper.setFill(); bounds.fill()
            paper?.draw(in: bounds, from: .zero, operation: .multiply, fraction: 0.10, respectFlipped: true, hints: nil)
            func text(_ value: String, y: CGFloat, size: CGFloat, heading: Bool = false, color: NSColor? = nil) {
                let style = NSMutableParagraphStyle(); style.alignment = .center
                (value as NSString).draw(in: CGRect(x: 36, y: y, width: CGFloat(width) - 72, height: size * 1.6), withAttributes: [.font: heading ? SketchPalette.heading(size) : NSFont.systemFont(ofSize: size), .foregroundColor: color ?? SketchPalette.ink, .paragraphStyle: style])
            }
            text("macos-x", y: 24, size: 21, heading: true, color: SketchPalette.muted)
            text("拖进应用程序，即可安装", y: 75, size: 29, heading: true)
            let line = NSBezierPath(); line.move(to: CGPoint(x: 70, y: 128)); line.line(to: CGPoint(x: width - 70, y: 128))
            SketchPencil.stroke(line, color: SketchPalette.line.withAlphaComponent(0.15), width: 1)
            let middleY = CGFloat(app[1]), start = CGFloat(app[0] + iconSize / 2 + 30), end = CGFloat(applications[0] - iconSize / 2 - 30)
            let arrow = NSBezierPath(); arrow.move(to: CGPoint(x: start, y: middleY + 2))
            arrow.curve(to: CGPoint(x: end, y: middleY - 1), controlPoint1: CGPoint(x: start + 40, y: middleY - 22), controlPoint2: CGPoint(x: end - 44, y: middleY + 18))
            SketchPencil.stroke(arrow, color: SketchPalette.blue, width: 3)
            let head = NSBezierPath(); head.move(to: CGPoint(x: end - 14, y: middleY - 11)); head.line(to: CGPoint(x: end, y: middleY - 1)); head.line(to: CGPoint(x: end - 14, y: middleY + 10))
            SketchPencil.stroke(head, color: SketchPalette.blue, width: 3)
            text("复制完成后，从「应用程序」打开。", y: 348, size: 15)
            text("以后可直接在应用里更新", y: 378, size: 12, color: SketchPalette.muted)
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
        try render(scale: 1).write(to: output.appendingPathComponent("background.png"))
        try render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
        try render(scale: 1, preview: true).write(to: output.appendingPathComponent("preview.png"))
    }
}
