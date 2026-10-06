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
    enum Glyph { case rectangle, arrow, pen, text, mosaic, recognition, color }
    let glyph: Glyph
    var ink = NSColor.systemRed { didSet { needsDisplay = true } }
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
            : selected ? NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.76, alpha: 1)
            : NSColor(calibratedWhite: hovered || cell?.isHighlighted == true ? 0.23 : 0.32, alpha: 1)
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
            let swatch = NSBezierPath(ovalIn: NSRect(x: 9, y: 9, width: 16, height: 16))
            ink.setFill(); swatch.fill(); SketchPencil.fibers(in: swatch)
            path.appendOval(in: NSRect(x: 8.7, y: 9.2, width: 16.5, height: 16))
        }
        SketchPencil.stroke(path, color: glyphColor, width: selected ? 2.7 : 1.65)
        if window?.firstResponder === self {
            glyphColor.setStroke()
            let focus = NSBezierPath(); focus.move(to: CGPoint(x: 13, y: 4)); focus.line(to: CGPoint(x: 21, y: 4))
            focus.lineWidth = 1; focus.stroke()
        }
    }
}
