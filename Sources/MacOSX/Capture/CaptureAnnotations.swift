import AppKit
import CoreImage
import CoreText

enum CaptureTool: Int, CaseIterable {
    case rectangle, ellipse, arrow, pen, highlighter, text, mosaic, blur, eraser
}

struct CaptureInk {
    let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    static let red = CaptureInk(red: 0.95, green: 0.2, blue: 0.25, alpha: 1)
    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    init(_ color: NSColor) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? .systemRed
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
    }
}

struct CaptureAnnotation {
    let tool: CaptureTool
    var points: [CGPoint]
    let ink: CaptureInk
    let width: CGFloat
    var text = ""
    var bounds: CGRect {
        guard let first = points.first else { return .null }
        if tool == .text {
            let size = max(18, width * 7)
            return CGRect(x: first.x, y: first.y, width: max(size, CGFloat(text.count) * size * 0.7), height: size * 1.2)
        }
        let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Stateless export renderer. Rectangles are in image pixel coordinates with a
/// lower-left origin, the same geometry the editor uses. Every export operation
/// uses this renderer, so copy/save/pin cannot disagree about redaction.
enum CaptureAnnotationRenderer {
    static func render(base: CGImage, annotations: [CaptureAnnotation], isCurrent: () -> Bool = { true }) -> CGImage? {
        guard isCurrent() else { return nil }
        guard let context = CaptureRaster.context(width: base.width, height: base.height) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        let effects = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
        for annotation in annotations {
            guard isCurrent() else { return nil }
            if annotation.tool == .mosaic || annotation.tool == .blur {
                let rect = annotation.bounds.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
                guard rect.width > 0, rect.height > 0 else { continue }
                guard let current = context.makeImage(),
                      let patch = current.cropping(to: CGRect(x: rect.minX, y: CGFloat(base.height) - rect.maxY,
                                                             width: rect.width, height: rect.height)) else { return nil }
                let source = CIImage(cgImage: patch)
                let output: CIImage
                if annotation.tool == .mosaic {
                    output = source.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(8, annotation.width * 4)])
                } else {
                    output = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6, annotation.width * 2)])
                }
                guard let image = effects.createCGImage(output.cropped(to: source.extent), from: source.extent) else { return nil }
                context.draw(image, in: rect)
            } else {
                drawVector(annotation, in: context)
            }
        }
        return context.makeImage()
    }

    static func drawVector(_ annotation: CaptureAnnotation, in context: CGContext) {
        guard let first = annotation.points.first else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setStrokeColor(annotation.ink.cgColor)
        context.setFillColor(annotation.ink.cgColor)
        context.setLineWidth(annotation.width)
        context.setLineCap(.round); context.setLineJoin(.round)
        let rect = annotation.bounds
        switch annotation.tool {
        case .rectangle: context.stroke(rect)
        case .ellipse: context.strokeEllipse(in: rect)
        case .arrow:
            guard let last = annotation.points.last else { return }
            context.move(to: first); context.addLine(to: last); context.strokePath()
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(12, annotation.width * 4)
            context.move(to: last)
            context.addLine(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
            context.move(to: last)
            context.addLine(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
            context.strokePath()
        case .pen, .highlighter:
            if annotation.tool == .highlighter { context.setAlpha(0.28); context.setBlendMode(.multiply); context.setLineWidth(annotation.width * 6) }
            context.move(to: first)
            for point in annotation.points.dropFirst() { context.addLine(to: point) }
            if annotation.points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            context.strokePath()
        case .text:
            let font = CTFontCreateWithName("Helvetica" as CFString, max(18, annotation.width * 7), nil)
            let text = NSAttributedString(string: annotation.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): annotation.ink.cgColor
            ])
            context.textMatrix = .identity
            context.textPosition = first
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        case .mosaic, .blur:
            context.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); context.setLineDash(phase: 0, lengths: [6, 4]); context.stroke(rect)
        case .eraser: break
        }
    }
}

@MainActor
final class CaptureCanvas: NSView {
    let base: CGImage
    var image: CGImage { didSet { needsDisplay = true } }
    var tool: CaptureTool = .rectangle
    var ink = CaptureInk.red
    var lineWidth: CGFloat = 3
    var onAnnotation: ((CaptureAnnotation) -> Void)?
    var onErase: ((CGPoint, CGFloat) -> Void)?
    var onText: ((CGPoint, CGFloat, CaptureInk) -> Void)?
    var onCopy: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    private var draft: CaptureAnnotation?
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage) { base = image; self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    private var imageRect: CGRect {
        let scale = min((bounds.width - 24) / CGFloat(base.width), (bounds.height - 24) / CGFloat(base.height))
        let size = CGSize(width: CGFloat(base.width) * max(scale, 0.01), height: CGFloat(base.height) * max(scale, 0.01))
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var scale: CGFloat { imageRect.width / CGFloat(base.width) }
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(CGFloat(base.width), max(0, (point.x - rect.minX) / scale)),
                       y: min(CGFloat(base.height), max(0, (point.y - rect.minY) / scale)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: imageRect)
        if let draft, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: imageRect.minX, y: imageRect.minY); context.scaleBy(x: scale, y: scale)
            CaptureAnnotationRenderer.drawVector(draft, in: context)
            context.restoreGState()
        }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let point = imagePoint(event), width = lineWidth / max(scale, 0.01)
        if tool == .eraser { onErase?(point, 12 / scale); return }
        if tool == .text { onText?(point, width, ink); return }
        draft = CaptureAnnotation(tool: tool, points: [point, point], ink: ink, width: width)
    }
    override func mouseDragged(with event: NSEvent) {
        if tool == .eraser { onErase?(imagePoint(event), 12 / scale); return }
        guard var draft else { return }
        if draft.tool == .pen || draft.tool == .highlighter {
            if draft.points.count < 4096 { draft.points.append(imagePoint(event)) }
        } else { draft.points[1] = imagePoint(event) }
        self.draft = draft; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard let annotation = draft else { return }
        draft = nil; needsDisplay = true
        if annotation.tool == .pen || annotation.tool == .highlighter || annotation.bounds.width > 1 || annotation.bounds.height > 1 {
            onAnnotation?(annotation)
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 8 { onCopy?() }
        else if event.modifierFlags.contains(.command), event.keyCode == 6 {
            event.modifierFlags.contains(.shift) ? onRedo?() : onUndo?()
        } else if event.keyCode == 36 || event.keyCode == 76 { onCopy?() }
        else if event.keyCode == 53 { window?.close() }
        else { super.keyDown(with: event) }
    }
}
