import AppKit

/// Neutral surfaces; AppKit still owns tracking, actions, keyboard activation and accessibility.
@MainActor
class MinimalButton: NSButton {
    enum Style { case standard, primary, quiet }
    var style: Style = .standard { didSet { updateTint() } }
    fileprivate var hovered = false
    private var hoverArea: NSTrackingArea?
    private var focusObserver: MinimalFocusObserver?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.momentaryPushIn)
        bezelStyle = .regularSquare
        isBordered = false
        focusRingType = .none
        font = SketchPalette.heading(15)
        imageScaling = .scaleProportionallyDown
        updateTint()
    }

    convenience init(title: String, target: AnyObject?, action: Selector?, style: Style) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action; self.style = style
    }
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
    }
    override var isEnabled: Bool { didSet { updateTint() } }
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: max(30, native.width + 16), height: max(30, native.height))
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        focusObserver = window == nil ? nil : MinimalFocusObserver(view: self) { [weak self] in self?.hovered = false }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isEnabled && cell?.isHighlighted == true
        let active = isEnabled && hovered && window?.isKeyWindow == true
        let selected = cell?.state == .on
        let fill: NSColor
        switch style {
        case .primary:
            fill = SketchPalette.yellow.withAlphaComponent(isEnabled ? (pressed ? 0.86 : active ? 0.74 : 0.62) : 0.08)
        case .standard:
            fill = SketchPalette.paper
        case .quiet:
            fill = SketchPalette.yellow.withAlphaComponent(pressed ? 0.2 : selected ? 0.14 : active ? 0.09 : 0)
        }
        MinimalSurface.draw(in: bounds, fill: fill,
            border: style == .quiet ? nil : SketchPalette.line.withAlphaComponent(isEnabled ? 1 : 0.4))
        super.draw(dirtyRect)
        MinimalSurface.drawFocus(for: self)
    }

    private func updateTint() {
        contentTintColor = !isEnabled ? .disabledControlTextColor : SketchPalette.ink
        needsDisplay = true
    }
}

/// A compact switch with the native NSButton switch state, action and checked accessibility value.
@MainActor
final class MinimalToggle: MinimalButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.switch)
        font = .systemFont(ofSize: 12)
    }
    required init?(coder: NSCoder) { nil }
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
    }

    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 12)]).width
        return NSSize(width: title.isEmpty ? 34 : 44 + ceil(width), height: 24)
    }
    override func draw(_ dirtyRect: NSRect) {
        let on = state != .off
        let pressed = isEnabled && cell?.isHighlighted == true
        let track = NSRect(x: 1, y: (bounds.height - 18) / 2, width: 32, height: 18)
        let fill: NSColor = on && isEnabled ? SketchPalette.green.withAlphaComponent(0.66) : SketchPalette.line.withAlphaComponent(isEnabled ? 0.12 : 0.05)
        let path = NSBezierPath(roundedRect: track, xRadius: 9, yRadius: 9)
        fill.withAlphaComponent(pressed && on ? 0.78 : fill.alphaComponent).setFill(); path.fill()
        NSColor.labelColor.withAlphaComponent(isEnabled && hovered && window?.isKeyWindow == true ? 0.30 : 0.14).setStroke()
        SketchPencil.stroke(path, color: SketchPalette.line, width: 0.85)
        let knobColor: NSColor = !isEnabled ? .disabledControlTextColor : on ? SketchPalette.paper : SketchPalette.muted
        knobColor.setFill()
        if state == .mixed {
            NSBezierPath(roundedRect: NSRect(x: track.midX - 5, y: track.midY - 1, width: 10, height: 2), xRadius: 1, yRadius: 1).fill()
        } else {
            NSBezierPath(ovalIn: NSRect(x: track.minX + (on ? 17 : 3), y: track.minY + 3, width: 12, height: 12)).fill()
        }
        if !title.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12),
                .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor, .paragraphStyle: paragraph]
            let height = (title as NSString).size(withAttributes: attributes).height
            (title as NSString).draw(in: NSRect(x: 42, y: (bounds.height - height) / 2, width: max(0, bounds.width - 44), height: height),
                withAttributes: attributes)
        }
        MinimalSurface.drawFocus(for: self)
    }
}

/// Keeps the system menu, selection semantics and arrow while removing the raised popup bezel.
@MainActor
final class MinimalPopUpButton: NSPopUpButton {
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    private var focusObserver: MinimalFocusObserver?

    override init(frame: NSRect, pullsDown: Bool) {
        super.init(frame: frame, pullsDown: pullsDown)
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        font = .systemFont(ofSize: 12)
        contentTintColor = SketchPalette.ink
    }
    convenience init() { self.init(frame: .zero, pullsDown: false) }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
    }
    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? SketchPalette.ink : .disabledControlTextColor; needsDisplay = true }
    }
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: max(44, native.width + 12), height: max(30, native.height))
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hovered = false
        focusObserver = window == nil ? nil : MinimalFocusObserver(view: self) { [weak self] in self?.hovered = false }
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        MinimalSurface.draw(in: bounds, fill: SketchPalette.paper,
            border: SketchPalette.line.withAlphaComponent(isEnabled ? 0.8 : 0.35))
        super.draw(dirtyRect)
        MinimalSurface.drawFocus(for: self)
    }
}

@MainActor
private enum MinimalSurface {
    static func draw(in bounds: NSRect, fill: NSColor, border: NSColor?) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 2, bounds.height > 2 else { return }
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 7)
        SketchPalette.fill(path, color: fill)
        if let border { SketchPencil.stroke(path, color: border, width: 0.9) }
    }
    static func drawFocus(for view: NSView) {
        let bounds = view.bounds
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 2, bounds.height > 2 else { return }
        guard view.window?.isKeyWindow == true, view.window?.firstResponder === view,
              (view as? NSControl)?.isEnabled != false else { return }
        SketchPalette.yellow.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        SketchPencil.stroke(path, color: SketchPalette.yellow, width: 1.5)
    }
}

@MainActor
private final class MinimalFocusObserver {
    private var tokens: [NSObjectProtocol] = []

    init(view: NSView, clearHover: @escaping () -> Void) {
        guard let window = view.window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak view] _ in
                MainActor.assumeIsolated { clearHover(); view?.needsDisplay = true }
            })
        }
    }
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}
