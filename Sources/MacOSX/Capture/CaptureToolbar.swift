import AppKit

/// Small native controls: handmade outlines are drawn once per UI redraw,
/// never baked into captured pixels or animated on an idle timer.
@MainActor
final class CaptureToolbarSurface: NSView {
    private var outline: NSBezierPath?
    private var outlineBounds = NSRect.zero
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.995, alpha: 1).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.fill()
        if outline == nil || outlineBounds != bounds {
            outlineBounds = bounds; outline = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 10)
        }
        if let outline { SketchPencil.stroke(outline, color: NSColor(calibratedWhite: 0.45, alpha: 1), width: 0.95) }
    }
}

@MainActor
final class CaptureToolButton: NSButton {
    enum Glyph { case rectangle, arrow, pen, text, mosaic, recognition, color, swatch }
    let glyph: Glyph
    var ink = SketchPalette.coral { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?
    init(_ glyph: Glyph, title: String, target: AnyObject?, action: Selector) {
        self.glyph = glyph
        super.init(frame: .zero)
        self.title = ""; self.target = target; self.action = action
        isBordered = false; setButtonType(.momentaryChange); focusRingType = .none
        toolTip = title; setAccessibilityLabel(title)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 34).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    // NSButton normally flips its drawing coordinates. These hand-drawn glyphs
    // use a lower-left origin so the T and arrow retain their intended direction.
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let glyphColor: NSColor = !isEnabled ? NSColor(calibratedWhite: 0.65, alpha: 1)
            : selected ? ink
            : glyph == .arrow ? SketchPalette.coral : glyph == .rectangle ? SketchPalette.blue : NSColor(calibratedWhite: hovered || cell?.isHighlighted == true ? 0.23 : 0.32, alpha: 1)
        glyphColor.setStroke()
        let path = NSBezierPath(); path.lineWidth = selected ? 2.7 : 1.65
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        func line(_ points: [CGPoint]) {
            guard let first = points.first else { return }
            path.move(to: first); for point in points.dropFirst() { path.line(to: point) }
        }
        switch glyph {
        case .rectangle:
            line([CGPoint(x: 8, y: 10), CGPoint(x: 26, y: 9.7), CGPoint(x: 25.7, y: 24), CGPoint(x: 8.3, y: 24.3), CGPoint(x: 8, y: 10)])
        case .arrow:
            line([CGPoint(x: 9, y: 9), CGPoint(x: 25, y: 25)])
            line([CGPoint(x: 14, y: 24.7), CGPoint(x: 25, y: 25), CGPoint(x: 24.7, y: 14)])
        case .pen:
            line([CGPoint(x: 8, y: 9), CGPoint(x: 10, y: 16), CGPoint(x: 22, y: 27), CGPoint(x: 27, y: 22), CGPoint(x: 15, y: 11), CGPoint(x: 8, y: 9)])
            line([CGPoint(x: 10, y: 16), CGPoint(x: 15, y: 11)])
        case .text:
            line([CGPoint(x: 8, y: 25), CGPoint(x: 26, y: 25)])
            line([CGPoint(x: 17, y: 25), CGPoint(x: 17, y: 8)])
        case .mosaic:
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 18, height: 18), xRadius: 4, yRadius: 4).addClip()
            for y in 0..<3 { for x in 0..<3 {
                let tile = NSRect(x: 8 + CGFloat(x) * 6, y: 8 + CGFloat(y) * 6, width: 6, height: 6).insetBy(dx: 0.35, dy: 0.35)
                let block = NSBezierPath(rect: tile)
                glyphColor.withAlphaComponent((x + y) % 2 == 0 ? 0.8 : 0.32).setFill(); block.fill()
                SketchPencil.fibers(in: block)
                SketchPencil.stroke(block, color: glyphColor, width: selected ? 1 : 0.55)
            }}
            NSGraphicsContext.restoreGraphicsState()
        case .recognition:
            for (x, y, dx, dy) in [(8.0, 8.0, 5.0, 5.0), (26, 8, -5, 5), (8, 26, 5, -5), (26, 26, -5, -5)] {
                line([CGPoint(x: x, y: y + dy), CGPoint(x: x, y: y), CGPoint(x: x + dx, y: y)])
            }
            line([CGPoint(x: 12, y: 21), CGPoint(x: 22, y: 21)])
            line([CGPoint(x: 17, y: 21), CGPoint(x: 17, y: 12)])
        case .color:
            let palette = CapturePaletteShape.path(in: NSRect(x: 5, y: 5, width: 24, height: 24))
            SketchPalette.paper.setFill(); palette.fill(); path.append(palette)
            for (x, y, color) in [(10.0, 19.0, SketchPalette.coral), (13, 25, SketchPalette.yellow),
                                  (20, 25, SketchPalette.green), (24, 19, SketchPalette.blue), (14, 11, ink)] {
                let paint = CapturePaletteShape.daub(in: NSRect(x: x - 2, y: y - 2, width: 4.5, height: 4))
                SketchPalette.fill(paint, color: color)
            }
            path.appendOval(in: NSRect(x: 19, y: 12, width: 3.5, height: 4))
        case .swatch:
            let paint = CapturePaletteShape.daub(in: NSRect(x: 6, y: 8, width: 22, height: 18))
            SketchPalette.fill(paint, color: ink); path.append(paint)

        }
        SketchPencil.stroke(path, color: glyphColor, width: selected ? 2.7 : 1.65)
        if window?.firstResponder === self {
            glyphColor.setStroke()
            let focus = NSBezierPath(); focus.move(to: CGPoint(x: 13, y: 4)); focus.line(to: CGPoint(x: 21, y: 4))
            focus.lineWidth = 1; focus.stroke()
        }
    }
}

/// Stable organic curves shared by the small icon and the full colour palette.
@MainActor enum CapturePaletteShape {
    static func path(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.move(to: p(0.77, 0.08))
        path.curve(to: p(0.05, 0.35), controlPoint1: p(0.44, -0.08), controlPoint2: p(-0.04, 0.07))
        path.curve(to: p(0.55, 0.98), controlPoint1: p(-0.06, 0.72), controlPoint2: p(0.20, 1.07))
        path.curve(to: p(0.97, 0.61), controlPoint1: p(0.85, 1.02), controlPoint2: p(1.05, 0.83))
        path.curve(to: p(0.72, 0.46), controlPoint1: p(0.98, 0.43), controlPoint2: p(0.75, 0.61))
        path.curve(to: p(0.77, 0.08), controlPoint1: p(0.61, 0.28), controlPoint2: p(0.94, 0.24))
        path.close(); return path
    }
    static func daub(in rect: CGRect) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.37, yRadius: rect.height * 0.44)
        return SketchPencil.outline(in: path.bounds, radius: min(rect.width, rect.height) * 0.36)
    }
}

@MainActor final class CaptureColorPalette: NSView {
    init(colors: [NSColor], selected: NSColor, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 154))
        let points: [CGPoint] = [CGPoint(x: 35, y: 67), CGPoint(x: 45, y: 105), CGPoint(x: 83, y: 126),
            CGPoint(x: 129, y: 128), CGPoint(x: 177, y: 110), CGPoint(x: 157, y: 38), CGPoint(x: 121, y: 29), CGPoint(x: 70, y: 33)]
        for (index, color) in colors.enumerated() {
            let button = CaptureToolButton(.swatch, title: ["黑", "红", "橙", "黄", "绿", "蓝", "紫", "白"][index], target: target, action: action)
            button.ink = color; button.tag = index; button.setButtonType(.momentaryPushIn)
            button.frame = CGRect(x: points[index].x - 17, y: points[index].y - 17, width: 34, height: 34)
            button.setAccessibilityValue(color.isEqual(selected) ? "当前颜色" : "")
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let shape = CapturePaletteShape.path(in: bounds.insetBy(dx: 8, dy: 7))
        SketchPalette.fill(shape, color: SketchPalette.yellow.withAlphaComponent(0.12))
        SketchPencil.stroke(shape, color: SketchPalette.line, width: 1)
        let hole = NSBezierPath(ovalIn: NSRect(x: 140, y: 70, width: 20, height: 24))
        SketchPalette.paper.setFill(); hole.fill()
        SketchPencil.stroke(hole, color: SketchPalette.line.withAlphaComponent(0.5), width: 0.8)
    }
}
