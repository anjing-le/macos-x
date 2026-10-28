import AppKit

/// Render semantic text once into a complete image. The ordinary image pin owns
/// presentation, dragging, zoom, copying, saving and recovery; no reader window.
enum CaptureTextPin {
    static let maximumPixels = CaptureRaster.maximumPixels
    static let maximumEdge = CaptureRaster.maximumDimension

    static func image(document: CaptureTextDocument, width proposedWidth: CGFloat = 880,
                      ticket: CaptureImageService.Ticket? = nil) -> CGImage? {
        guard ticket?.valid != false, proposedWidth.isFinite else { return nil }
        var width = min(880, max(120, proposedWidth))
        if document.attributed.length < 600 {
            var hasTable = false
            document.attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.attributed.length)) { value, _, stop in
                if (value as? NSParagraphStyle)?.textBlocks.isEmpty == false { hasTable = true; stop.pointee = true }
            }
            if !hasTable {
                let measured = document.attributed.boundingRect(with: CGSize(width: width - 28, height: .greatestFiniteMagnitude),
                                                               options: [.usesLineFragmentOrigin, .usesFontLeading])
                width = min(width, max(120, measured.width.rounded(.up) + 28))
            }
        }
        let storage = NSTextStorage(attributedString: document.attributed)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width - 28, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = max(32, layout.usedRect(for: container).maxY.rounded(.up) + 16)
        guard ticket?.valid != false, height.isFinite, height <= 16_000_000 else { return nil }
        // Keep the WHOLE layout. Reduce pixel density for exceptional lengths,
        // rather than clipping the last rows or allocating an unbounded bitmap.
        let scale = min(1, sqrt(CGFloat(maximumPixels) / (width * height)),
                        CGFloat(maximumEdge) / max(width, height))
        let pixelsWide = max(1, Int((width * scale).rounded(.down)))
        let pixelsHigh = max(1, Int((height * scale).rounded(.down)))
        guard pixelsWide <= maximumPixels / pixelsHigh,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: pixelsWide * 4, bitsPerPixel: 32),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh).fill()
        let context = graphics.cgContext
        context.translateBy(x: 0, y: CGFloat(pixelsHigh))
        // Use actual rounded dimensions so the complete bottom margin survives.
        context.scaleBy(x: CGFloat(pixelsWide) / width, y: -CGFloat(pixelsHigh) / height)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let glyphs = NSRange(location: 0, length: layout.numberOfGlyphs)
        layout.drawBackground(forGlyphRange: glyphs, at: CGPoint(x: 14, y: 8))
        layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: 14, y: 8))
        return ticket?.valid == false ? nil : bitmap.cgImage
    }

    static func initialFrame(image: CGImage, available: CGRect) -> CGRect {
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(1, max(1, available.width - 64) / size.width,
                        max(1, available.height - 64) / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: available.midX - fitted.width / 2, y: available.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    static func maximumZoom(image: CGImage, baseSize: CGSize) -> CGFloat {
        guard baseSize.width > 0, baseSize.height > 0 else { return 4 }
        // Long pins can reach their actual pixels, instead of stopping at 400%
        // of a tiny fit-to-screen thumbnail. Bound the floating window size.
        return max(1, min(max(4, CGFloat(image.width) / baseSize.width),
                          16_384 / max(baseSize.width, baseSize.height)))
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(target, image, nil)
        return CGImageDestinationFinalize(target) ? data as Data : nil
    }
}
