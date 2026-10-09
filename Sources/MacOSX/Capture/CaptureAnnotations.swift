import AppKit
import CoreImage
import CoreText

enum CaptureTool: Int, CaseIterable {
    case rectangle, ellipse, arrow, pen, highlighter, text, mosaic, blur, eraser
}

struct CaptureInk {
    let red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat
    var cgColor: CGColor { CGColor(red: red, green: green, blue: blue, alpha: alpha) }
    static let red = CaptureInk(red: 0.96, green: 0.43, blue: 0.32, alpha: 1)
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
    func reframed(from old: CGRect, pixels oldPixels: CGSize, to new: CGRect, pixels newPixels: CGSize) -> CaptureAnnotation {
        let sx = newPixels.width / new.width, sy = newPixels.height / new.height
        var result = CaptureAnnotation(tool: tool, points: points.map { point in
            CGPoint(x: (old.minX + point.x * old.width / oldPixels.width - new.minX) * sx,
                    y: (old.minY + point.y * old.height / oldPixels.height - new.minY) * sy)
        }, ink: ink, width: width * old.width / oldPixels.width * sx)
        result.text = text; return result
    }
    var bounds: CGRect {
        guard let first = points.first else { return .null }
        if tool == .text {
            let size = max(18, width * 7)
            return CGRect(x: first.x, y: first.y, width: max(size, CGFloat(text.count) * size * 0.7), height: size * 1.2)
        }
        let minX = points.map(\.x).min() ?? first.x, maxX = points.map(\.x).max() ?? first.x
        let minY = points.map(\.y).min() ?? first.y, maxY = points.map(\.y).max() ?? first.y
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return tool == .mosaic ? rect.insetBy(dx: -width / 2, dy: -width / 2) : rect
    }
    var mosaicMask: CGPath? {
        guard tool == .mosaic, let first = points.first, width.isFinite, width > 0 else { return nil }
        let path = CGMutablePath(); path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        // A click is one circular dab, including a stationary down/up pair.
        if points.allSatisfy({ $0 == first }) {
            return CGPath(ellipseIn: CGRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width), transform: nil)
        }
        return path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }
}

/// Stateless export renderer. Rectangles are in image pixel coordinates with a
/// lower-left origin, the same geometry the editor uses. Every export operation
/// uses this renderer, so copy/save/pin cannot disagree about redaction.
enum CaptureAnnotationRenderer {
    static func render(base: CGImage, annotations: [CaptureAnnotation], effectsContext: CIContext? = nil, isCurrent: () -> Bool = { true }) -> CGImage? {
        guard isCurrent() else { return nil }
        if annotations.isEmpty { return base }
        guard let context = CaptureRaster.context(width: base.width, height: base.height) else { return nil }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // Most exports contain only vector marks. Allocate the effects engine
        // only when an actual redaction patch needs it, once per export.
        var effects = effectsContext
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
                    output = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: 10])
                } else {
                    output = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(6, annotation.width * 2)])
                }
                if effects == nil { effects = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]) }
                guard let image = effects?.createCGImage(output.cropped(to: source.extent), from: source.extent) else { return nil }
                context.saveGState()
                if annotation.tool == .mosaic, let mask = annotation.mosaicMask {
                    context.addPath(mask); context.clip()
                }
                context.draw(image, in: rect)
                context.restoreGState()
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
        case .rectangle:
            CaptureCrayonStroke.draw(segments: [(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)),
                (CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)),
                (CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)),
                (CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY))], ink: annotation.ink, width: annotation.width, in: context)
        case .ellipse: context.strokeEllipse(in: rect)
        case .arrow:
            guard let last = annotation.points.last else { return }
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = max(12, annotation.width * 4)
            let left = CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6))
            let right = CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6))
            CaptureCrayonStroke.draw(segments: [(first, last), (last, left), (last, right)], ink: annotation.ink, width: annotation.width, in: context)
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

/// Used exclusively on one canvas's serial brush queue. Lazily reused until close.
private final class CaptureBrushRenderer: @unchecked Sendable {
    private var effects: CIContext?
    func render(base: CGImage, annotation: CaptureAnnotation, ticket: CaptureImageService.Ticket) -> CGImage? {
        guard ticket.valid else { return nil }
        if effects == nil { effects = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]) }
        return CaptureAnnotationRenderer.render(base: base, annotations: [annotation], effectsContext: effects, isCurrent: { ticket.valid })
    }
    func clear() { effects = nil }
}

/// Fixed wax-pencil passes: native geometry, no white paint over screenshot pixels,
/// no random state, texture images, background allocation or main-thread-only APIs.
enum CaptureCrayonStroke {
    static func draw(segments: [(CGPoint, CGPoint)], ink: CaptureInk, width: CGFloat, in context: CGContext) {
        guard width.isFinite, width > 0 else { return }
        context.saveGState(); defer { context.restoreGState() }
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setStrokeColor(ink.cgColor)
        for lane in 0..<4 {
            context.setAlpha(lane == 0 ? 0.46 : 0.58)
            context.setLineWidth(lane == 0 ? width * 0.72 : max(0.35, width * 0.26))
            context.setLineDash(phase: CGFloat(lane) * 0.31, lengths: lane == 0 ? [] : [max(0.7, width * 0.67), 0.35, max(1, width * 0.9), 0.25])
            for (start, end) in segments {
                let dx = end.x - start.x, dy = end.y - start.y
                let length = hypot(dx, dy)
                guard length.isFinite, length > 0 else { continue }
                let steps = min(512, max(1, Int(min(length / 3, 512))))
                let nx = -dy / length, ny = dx / length
                for step in 0...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let distance = length * t
                    let grain = sin(distance * 1.37 + CGFloat(lane) * 2.1) * min(0.45, width * 0.13)
                    let offset = (CGFloat(lane) - 1.5) * width * 0.22 + grain
                    let point = CGPoint(x: start.x + dx * t + nx * offset, y: start.y + dy * t + ny * offset)
                    if step == 0 { context.move(to: point) } else { context.addLine(to: point) }
                }
            }
            context.strokePath()
        }
    }
}

@MainActor
final class CaptureCanvas: NSView {
    var base: CGImage
    var image: CGImage { didSet { needsDisplay = true } }
    var tool: CaptureTool? { didSet { updateBrushPosition(); needsDisplay = true } }
    var ink = CaptureInk.red
    var lineWidth: CGFloat = 3
    var mosaicDiameter: CGFloat = 32 { didSet { updateBrushPosition(); needsDisplay = true } }
    var imageInset: CGFloat = 12
    var onAnnotation: ((CaptureAnnotation) -> Void)?
    var onDraftBegan: (() -> Void)?
    var inputEnabled = true
    var onErase: ((CGPoint, CGFloat) -> Void)?
    var onText: ((CGPoint, CGFloat, CaptureInk) -> Void)?
    var onCopy: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    private var draft: CaptureAnnotation?
    private var brushPosition: CGPoint?
    private var brushTracking: NSTrackingArea?
    private var mosaicPreview: CGImage?
    private let brushQueue = DispatchQueue(label: "cc.anjing.macos-x.mosaic-preview", qos: .userInitiated)
    private let brushRenderer = CaptureBrushRenderer()
    private var brushBusy = false
    private var brushPending: (CGImage, CaptureAnnotation, UInt64)?
    private var brushGeneration: UInt64 = 0
    private var brushTicket: CaptureImageService.Ticket?
    func stopBrushPreview() {
        brushGeneration &+= 1; brushPending = nil; brushTicket?.cancel(); brushTicket = nil
        mosaicPreview = nil; brushPosition = nil
    }
    func closeBrushPreview() {
        stopBrushPreview()
        let renderer = brushRenderer
        brushQueue.async { renderer.clear() }
    }
    private func requestBrushPreview() {
        guard let draft, draft.tool == .mosaic else { return }
        brushPending = (image, draft, brushGeneration)
        drainBrushPreview()
    }
    private func drainBrushPreview() {
        guard !brushBusy, let (base, mark, generation) = brushPending else { return }
        brushPending = nil; brushBusy = true
        let ticket = CaptureImageService.Ticket(); brushTicket = ticket
        let renderer = brushRenderer
        brushQueue.async { [weak self] in
            let result = autoreleasepool {
                renderer.render(base: base, annotation: mark, ticket: ticket)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.brushBusy = false
                if self.brushGeneration == generation, ticket.valid, self.draft?.tool == .mosaic {
                    self.mosaicPreview = result; self.needsDisplay = true
                }
                self.drainBrushPreview()
            }
        }
    }
    @discardableResult func cancelDraft() -> Bool {
        guard draft != nil else { return false }
        draft = nil; stopBrushPreview(); needsDisplay = true; return true
    }
    @discardableResult func commitDraft() -> Bool {
        guard let mark = draft else { return false }
        draft = nil; stopBrushPreview(); needsDisplay = true
        if mark.tool == .pen || mark.tool == .highlighter || mark.tool == .mosaic || mark.bounds.width > 1 || mark.bounds.height > 1 { onAnnotation?(mark) }
        return true
    }
    override var acceptsFirstResponder: Bool { true }
    init(image: CGImage) { base = image; self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let brushTracking { removeTrackingArea(brushTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); brushTracking = area
    }
    private func updateBrushPosition() {
        guard tool == .mosaic, let window else { brushPosition = nil; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        brushPosition = imageRect.contains(point) ? point : nil
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        brushPosition = tool == .mosaic && imageRect.contains(point) ? point : nil
        if tool == .mosaic { needsDisplay = true }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { brushPosition = nil; needsDisplay = true }

    private var imageRect: CGRect {
        let scale = min((bounds.width - imageInset * 2) / CGFloat(base.width),
                        (bounds.height - imageInset * 2) / CGFloat(base.height))
        let size = CGSize(width: CGFloat(base.width) * max(scale, 0.01), height: CGFloat(base.height) * max(scale, 0.01))
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private var scale: CGFloat { imageRect.width / CGFloat(base.width) }
    func viewPoint(for point: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
    }
    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(CGFloat(base.width), max(0, (point.x - rect.minX) / scale)),
                       y: min(CGFloat(base.height), max(0, (point.y - rect.minY) / scale)))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill(); bounds.fill()
        if let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            let device = context.convertToDeviceSpace(imageRect)
            let nativePixels = abs(device.width-CGFloat(image.width)) < 0.01 && abs(device.height-CGFloat(image.height)) < 0.01
            context.interpolationQuality = nativePixels ? .none : .high
            context.draw(mosaicPreview ?? image,in:imageRect)
            context.restoreGState()
        }
        if let draft, draft.tool != .mosaic, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.translateBy(x: imageRect.minX, y: imageRect.minY); context.scaleBy(x: scale, y: scale)
            CaptureAnnotationRenderer.drawVector(draft, in: context)
            context.restoreGState()
        }
        if tool == .mosaic, let point = brushPosition, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState(); context.clip(to: imageRect)
            let diameter = draft?.tool == .mosaic ? (draft!.width * scale) : mosaicDiameter
            let circle = CGRect(x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.95)); context.setLineWidth(3); context.strokeEllipse(in: circle)
            context.setStrokeColor(CGColor(gray: 0.25, alpha: 0.9)); context.setLineWidth(1); context.strokeEllipse(in: circle)
            context.restoreGState()
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard inputEnabled else { return }
        window?.makeFirstResponder(self)
        guard let tool, imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        let point = imagePoint(event), width = (tool == .mosaic ? mosaicDiameter : lineWidth) / max(scale, 0.01)
        onDraftBegan?()
        if tool == .eraser { onErase?(point, 12 / scale); return }
        if tool == .text { onText?(point, width, ink); return }
        draft = CaptureAnnotation(tool: tool, points: [point, point], ink: ink, width: width)
        mouseMoved(with: event); requestBrushPreview(); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard inputEnabled else { return }
        if tool == .eraser { onErase?(imagePoint(event), 12 / scale); return }
        guard var draft else { return }
        if draft.tool == .pen || draft.tool == .highlighter || draft.tool == .mosaic {
            if draft.points.count < 4096 { draft.points.append(imagePoint(event)) }
        } else { draft.points[1] = imagePoint(event) }
        self.draft = draft; mouseMoved(with: event); requestBrushPreview(); needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard inputEnabled else { return }
        if var mark = draft, mark.tool == .mosaic, mark.points.count < 4096 { mark.points.append(imagePoint(event)); draft = mark }
        commitDraft(); mouseMoved(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 8 { onCopy?() }
        else if event.modifierFlags.contains(.command), event.keyCode == 6 {
            event.modifierFlags.contains(.shift) ? onRedo?() : onUndo?()
        } else if event.keyCode == 36 || event.keyCode == 76 { onConfirm?() }
        else if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }
}
