import AppKit
import CoreText

@MainActor
enum SketchPalette {
    private static let registerFont: Void = {
        if let url = Bundle.main.url(forResource: "SketchFont", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()
    static func heading(_ size: CGFloat) -> NSFont {
        _ = registerFont
        return NSFont(name: "ZCOOLKuaiLe-Regular", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }
    static let paper = NSColor(calibratedRed: 0.998, green: 0.993, blue: 0.975, alpha: 1)
    static let ink = NSColor(calibratedWhite: 0.2, alpha: 1)
    static let muted = NSColor(calibratedWhite: 0.52, alpha: 1)
    static let line = NSColor(calibratedWhite: 0.40, alpha: 1)
    static let coral = NSColor(calibratedRed: 0.96, green: 0.43, blue: 0.32, alpha: 1)
    static let orange = NSColor(calibratedRed: 0.96, green: 0.64, blue: 0.32, alpha: 1)
    static let yellow = NSColor(calibratedRed: 0.96, green: 0.76, blue: 0.25, alpha: 1)
    static let blue = NSColor(calibratedRed: 0.35, green: 0.67, blue: 0.9, alpha: 1)
    static let green = NSColor(calibratedRed: 0.52, green: 0.74, blue: 0.43, alpha: 1)
    static let purple = NSColor(calibratedRed: 0.66, green: 0.54, blue: 0.84, alpha: 1)
    static func fill(_ path: NSBezierPath, color: NSColor) {
        color.setFill(); path.fill(); if color.alphaComponent > 0.08 { SketchPencil.fibers(in: path) }
    }
}

@MainActor
enum SketchPencil {
    static func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.withAlphaComponent(color.alphaComponent * 0.72).setStroke(); path.lineWidth = width * 0.8; path.stroke()
        let retrace = path.copy() as! NSBezierPath
        retrace.transform(using: AffineTransform(translationByX: 0.18, byY: -0.12))
        let marks: [CGFloat] = [2.3, 0.65, 3.7, 0.35, 1.4, 0.8]
        retrace.setLineDash(marks, count: marks.count, phase: 0.4)
        color.withAlphaComponent(color.alphaComponent * 0.9).setStroke(); retrace.lineWidth = width * 0.64; retrace.stroke()
        let grain = path.copy() as! NSBezierPath
        let gaps: [CGFloat] = [0.2, 1.3, 0.35, 2.1, 0.15, 0.9]
        grain.setLineDash(gaps, count: gaps.count, phase: 0.2)
        NSColor.white.withAlphaComponent(0.3).setStroke(); grain.lineWidth = max(0.25, width * 0.2); grain.stroke()
    }
    static func outline(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return path }
        let r = min(radius, rect.width / 2, rect.height / 2)
        var index = 0
        func point(_ p: CGPoint) {
            // Fixed subpixel irregularity, stable between redraws and window sizes.
            let t = CGFloat(index)
            let p = CGPoint(x: p.x + sin(t * 1.73) * 0.23, y: p.y + cos(t * 1.31) * 0.23)
            if index == 0 { path.move(to: p) } else { path.line(to: p) }
            index += 1
        }
        func edge(_ a: CGPoint, _ b: CGPoint) {
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                point(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        func corner(_ center: CGPoint, from angle: CGFloat) {
            for step in 0...8 {
                let a = angle + CGFloat(step) / 8 * .pi / 2
                point(CGPoint(x: center.x + cos(a) * r, y: center.y + sin(a) * r))
            }
        }
        edge(CGPoint(x: rect.minX + r, y: rect.minY), CGPoint(x: rect.maxX - r, y: rect.minY))
        corner(CGPoint(x: rect.maxX - r, y: rect.minY + r), from: -.pi / 2)
        edge(CGPoint(x: rect.maxX, y: rect.minY + r), CGPoint(x: rect.maxX, y: rect.maxY - r))
        corner(CGPoint(x: rect.maxX - r, y: rect.maxY - r), from: 0)
        edge(CGPoint(x: rect.maxX - r, y: rect.maxY), CGPoint(x: rect.minX + r, y: rect.maxY))
        corner(CGPoint(x: rect.minX + r, y: rect.maxY - r), from: .pi / 2)
        edge(CGPoint(x: rect.minX, y: rect.maxY - r), CGPoint(x: rect.minX, y: rect.minY + r))
        corner(CGPoint(x: rect.minX + r, y: rect.minY + r), from: .pi)
        path.close(); return path
    }
    static func fibers(in path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        path.addClip()
        let fibers = NSBezierPath(); fibers.lineWidth = 0.35
        let area = path.bounds
        for y in stride(from: area.minY, to: area.maxY, by: 3.3) {
            for x in stride(from: area.minX, to: area.maxX, by: 4.1) {
                fibers.move(to: CGPoint(x: x, y: y)); fibers.line(to: CGPoint(x: x + 1.7, y: y + 0.7))
            }
        }
        NSColor.white.withAlphaComponent(0.38).setStroke(); fibers.stroke()
    }
}

/// Paper and a reusable cached edge; no image resources or idle animations.
@MainActor
class SketchSurface: NSView {
    var fill = SketchPalette.paper { didSet { needsDisplay = true } }
    var edge: NSColor? = SketchPalette.line { didSet { needsDisplay = true } }
    var radius: CGFloat = 12 { didSet { outline = nil; needsDisplay = true } }
    private var outline: NSBezierPath?
    private var lastBounds = NSRect.zero
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 4, bounds.height > 4 else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
        fill.setFill(); shape.fill()
        if let texture = SketchPaper.image {
            NSGraphicsContext.saveGraphicsState(); shape.addClip()
            // Fixed 128-point tile: no stretched paper fibers on wide windows.
            for y in stride(from: bounds.minY, to: bounds.maxY, by: 128) {
                for x in stride(from: bounds.minX, to: bounds.maxX, by: 128) {
                    texture.draw(in: NSRect(x: x, y: y, width: 128, height: 128), from: .zero, operation: .multiply, fraction: 0.5)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if let edge {
            if outline == nil || lastBounds != bounds {
                lastBounds = bounds; outline = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: radius)
            }
            if let outline { SketchPencil.stroke(outline, color: edge, width: 1.6) }
        }
    }
}

@MainActor
private final class SketchInputCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: rect.insetBy(dx: 8, dy: 2))
    }
}

@MainActor
final class SketchTextField: NSTextField {
    var usesArtwork = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = SketchInputCell(textCell: "")
        isEditable = true; isSelectable = true
        isBezeled = false; isBordered = false; drawsBackground = false
        focusRingType = .none; textColor = SketchPalette.ink
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        if usesArtwork && currentEditor() == nil { super.draw(dirtyRect); return }
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 6)
        SketchPalette.paper.setFill(); path.fill()
        SketchPencil.stroke(path, color: currentEditor() == nil ? SketchPalette.line : SketchPalette.yellow, width: 1)
        super.draw(dirtyRect)
    }
}

@MainActor
private final class SketchSearchCell: NSSearchFieldCell {
    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var text = super.searchTextRect(forBounds: rect)
        let font = self.font ?? NSFont.systemFont(ofSize: 12)
        let height = ceil(font.ascender - font.descender + 2)
        text.origin.y = rect.midY - height/2; text.size.height = height
        return text
    }
}

@MainActor
final class SketchSearchField: NSSearchField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell = SketchSearchCell(textCell: "")
        isEditable = true; isSelectable = true
        isBezeled = false; isBordered = false; drawsBackground = false
        focusRingType = .none; textColor = SketchPalette.ink
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 10)
        SketchPalette.paper.setFill(); path.fill()
        SketchPencil.stroke(path, color: currentEditor() == nil ? SketchPalette.line : SketchPalette.yellow, width: 1)
        super.draw(dirtyRect)
    }
}

@MainActor
final class SketchScrollView: NSScrollView {
    var usesArtwork = false
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !usesArtwork, bounds.width > 4, bounds.height > 4 else { return }
        SketchPencil.stroke(SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 8), color: SketchPalette.line, width: 0.9)
    }
}

@MainActor
final class SketchTableRow: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        SketchPalette.fill(shape, color: SketchPalette.yellow.withAlphaComponent(0.18))
        SketchPencil.stroke(shape, color: SketchPalette.yellow, width: 0.9)
    }
}

@MainActor
enum SketchPaper {
    static let image: NSImage? = Bundle.main.url(forResource: "SketchPaper", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
}
