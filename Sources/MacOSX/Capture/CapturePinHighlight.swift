import CoreGraphics

/// Display-only, static light. Never part of the image/export transform.
enum CapturePinHighlight {
    static func draw(in context: CGContext, bounds: CGRect) {
        guard bounds.width > 2, bounds.height > 2 else { return }
        let edge = CGPath(roundedRect: bounds.insetBy(dx: 0.9, dy: 0.9), cornerWidth: 2, cornerHeight: 2, transform: nil)
        context.saveGState()
        defer { context.restoreGState() }
        // A quiet neutral keyline keeps the white light readable on white paper.
        context.addPath(edge)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.18))
        context.setLineWidth(2); context.strokePath()
        context.setShadow(offset: .zero, blur: 6, color: CGColor(gray: 1, alpha: 0.9))
        context.addPath(edge)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.96))
        context.setLineWidth(1.25); context.strokePath()
    }
}
