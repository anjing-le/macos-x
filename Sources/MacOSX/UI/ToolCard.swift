import AppKit
import QuartzCore

/// A native, keyboard-accessible entry card. Its parent owns sizing and navigation.
@MainActor
final class ToolCard: NSControl {
    private let surface = SketchSurface()
    private let symbolView = NSImageView()
    private let titleLabel: NSTextField
    private let activate: () -> Void
    private var enableButton:ModuleEnableButton?
    private var accessibleEntry:CardAccessibleEntry?
    private var enabledChanged:((Bool)->Void)?
    func configureEnabled(_ enabled:Bool,onChange:@escaping (Bool)->Void) {
        enabledChanged=onChange
        if enableButton == nil {
            let button=ModuleEnableButton(title:titleLabel.stringValue,target:self,action:#selector(changeModuleEnabled))
            enableButton=button; addSubview(button)
            let entry=CardAccessibleEntry(card:self,title:titleLabel.stringValue)
            accessibleEntry=entry
            setAccessibilityRole(.group); setAccessibilityChildren([entry,button])
        }
        updateEnabled(enabled); needsLayout=true
    }
    func updateEnabled(_ enabled:Bool) { enableButton?.state=enabled ? .on : .off; enableButton?.needsDisplay=true }
    @objc private func changeModuleEnabled() {
        guard let button=enableButton else { return }
        enabledChanged?(button.state == .on)
    }
    private var hoverArea: NSTrackingArea?
    private var hovered = false
    private var keyboardFocused = false
    private var mousePressed = false
    private var pressedKey: UInt16?
    private var displayObserver: NSObjectProtocol?
    private var windowObservers: [NSObjectProtocol] = []

    override var intrinsicContentSize: NSSize { NSSize(width: 180, height: 140) }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool {
        acceptsFirstResponder && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { mousePressed = false; pressedKey = nil }
            enableButton?.isEnabled=isEnabled
            setAccessibilityEnabled(isEnabled)
            updateAppearance(animated: true)
        }
    }

    init(title: String, symbol: String, action: @escaping () -> Void) {
        titleLabel = NSTextField(labelWithString: title)
        activate = action
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 156))

        wantsLayer = true
        focusRingType = .none
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 12
        surface.layer?.borderWidth = 0
        surface.layer?.shadowOffset = NSSize(width: 0, height: -3)
        surface.layer?.shadowRadius = 8
        surface.layer?.masksToBounds = false

        symbolView.image = SketchCardArt.image(symbol) ?? SketchIcons.image(symbol, size: 128)
        symbolView.imageScaling = .scaleProportionallyUpOrDown
        symbolView.wantsLayer = true
        titleLabel.font = SketchPalette.heading(20)
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.wantsLayer = true

        addSubview(surface)
        surface.addSubview(symbolView)
        surface.addSubview(titleLabel)
        for view in [surface, symbolView, titleLabel] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            symbolView.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 128),
            symbolView.heightAnchor.constraint(equalToConstant: 128),
            titleLabel.centerYAnchor.constraint(equalTo: surface.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        symbolView.setAccessibilityElement(false)
        titleLabel.setAccessibilityElement(false)
        surface.setAccessibilityElement(false)

        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAppearance(animated: false) }
        }
        updateAppearance(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(title:symbol:action:)") }

    deinit {
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    }

    /// The decorative child views never take the click away from the control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit=super.hitTest(point) else { return nil }
        if let button=enableButton,hit === button || hit.isDescendant(of:button) { return button }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        mousePressed = false; pressedKey = nil
        keyboardFocused = window?.firstResponder === self
        if let window {
            for name in [NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if notification.name == NSWindow.didResignKeyNotification {
                            self.mousePressed = false; self.pressedKey = nil
                        }
                        self.updateAppearance(animated: false)
                    }
                })
            }
        } else {
            hovered = false
        }
        updateAppearance(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    override func layout() {
        super.layout()
        enableButton?.frame=CGRect(x:bounds.width-78,y:bounds.height-40,width:68,height:30)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.layer?.shadowPath = CGPath(roundedRect: surface.bounds,
            cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateAppearance(animated: true) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateAppearance(animated: true) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        mousePressed = true
        updateAppearance(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        mousePressed = isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        updateAppearance(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        let shouldActivate = mousePressed && isEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        mousePressed = false
        updateAppearance(animated: true)
        if shouldActivate { activate() }
    }

    override func becomeFirstResponder() -> Bool {
        guard isEnabled, super.becomeFirstResponder() else { return false }
        keyboardFocused = true
        updateAppearance(animated: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        keyboardFocused = false; pressedKey = nil
        updateAppearance(animated: true)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { super.keyDown(with: event); return }
        switch event.keyCode {
        case 36, 49, 76: // Return, Space, keypad Enter; fire once on release.
            if !event.isARepeat { pressedKey = event.keyCode; updateAppearance(animated: true) }
        case 48:
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        case 53:
            pressedKey = nil; mousePressed = false; updateAppearance(animated: true)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard pressedKey == event.keyCode else { super.keyUp(with: event); return }
        pressedKey = nil
        updateAppearance(animated: true)
        if isEnabled, keyboardFocused, window?.isKeyWindow == true { activate() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    private func updateAppearance(animated: Bool) {
        guard let cardLayer = surface.layer, let iconLayer = symbolView.layer,
              let textLayer = titleLabel.layer else { return }
        let focused = keyboardFocused && window?.isKeyWindow == true
        let revealed = isEnabled && (hovered || focused)
        enableButton?.emphasized=hovered || focused
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration = animated && !reducedMotion ? 0.25 : 0
        let pressed = mousePressed || pressedKey != nil
        let cardScale: CGFloat = reducedMotion ? 1 : (pressed ? 0.97 : (revealed ? 1.03 : 1))
        let iconScale: CGFloat = reducedMotion || !revealed ? 1 : 0.95

        surface.fill = SketchPalette.paper
        surface.edge = revealed ? SketchPalette.yellow : SketchPalette.line.withAlphaComponent(0.6)
        cardLayer.backgroundColor = NSColor.clear.cgColor
        cardLayer.borderColor = NSColor.clear.cgColor
        cardLayer.shadowColor = NSColor.black.cgColor
        symbolView.contentTintColor = nil
        titleLabel.textColor = SketchPalette.ink
        animate(cardLayer, "transform", NSValue(caTransform3D: CATransform3DMakeScale(cardScale, cardScale, 1)), duration)
        animate(cardLayer, "shadowOpacity", NSNumber(value: revealed ? 0.035 : 0), duration)
        animate(iconLayer, "opacity", NSNumber(value: revealed ? 0 : (isEnabled ? 1 : 0.3)), duration)
        animate(iconLayer, "transform", NSValue(caTransform3D: CATransform3DMakeScale(iconScale, iconScale, 1)), duration)
        animate(textLayer, "opacity", NSNumber(value: revealed ? 1 : 0), duration)
        animate(textLayer, "transform", NSValue(caTransform3D:
            CATransform3DMakeTranslation(0, revealed || reducedMotion ? 0 : -6, 0)), duration)
    }

    /// Explicit layer animations avoid depending on AppKit backing-layer actions.
    private func animate(_ layer: CALayer, _ key: String, _ value: Any, _ duration: TimeInterval) {
        let previous = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
        layer.removeAnimation(forKey: key)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: key)
        CATransaction.commit()
        guard duration > 0 else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = previous; animation.toValue = value
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        layer.add(animation, forKey: key)
    }
}

/// A permanent state label with a generous independent click target.
@MainActor final class ModuleEnableButton:MinimalButton {
    private let moduleTitle:String
    var emphasized=false { didSet { if emphasized != oldValue { needsDisplay=true } } }
    init(title:String,target:AnyObject?,action:Selector?) {
        moduleTitle=title
        super.init(frame:.zero)
        self.target=target; self.action=action
        setButtonType(.pushOnPushOff)
        setAccessibilityRole(.checkBox); setAccessibilityLabel("启用\(title)")
    }
    required init?(coder:NSCoder) { nil }
    override var intrinsicContentSize:NSSize { CGSize(width:68,height:30) }
    override var state:NSControl.StateValue { didSet {
        toolTip="\(state == .on ? "关闭" : "开启")\(moduleTitle)"
        setAccessibilityValue(state == .on ? 1 : 0); needsDisplay=true
    } }
    override func acceptsFirstMouse(for event:NSEvent?)->Bool { isEnabled }
    override func mouseDown(with event:NSEvent) {
        guard isEnabled,bounds.contains(convert(event.locationInWindow,from:nil)) else { return }
        window?.makeFirstResponder(self)
        state=state == .on ? .off : .on
        if let action { NSApp.sendAction(action,to:target,from:self) }
    }
    override func draw(_ dirtyRect:NSRect) {
        let on=state == .on
        let path=SketchPencil.outline(in:bounds.insetBy(dx:1,dy:1),radius:8)
        SketchPalette.fill(path,color:SketchPalette.paper)
        let active=emphasized || (isPointerInside && window?.isKeyWindow == true) || window?.firstResponder === self
        SketchPencil.stroke(path,color:active ? SketchPalette.ink.withAlphaComponent(0.65) : SketchPalette.line,width:active ? 1.3 : 0.8)
        (on ? SketchPalette.green : SketchPalette.muted.withAlphaComponent(0.55)).setFill()
        NSBezierPath(ovalIn:CGRect(x:10,y:bounds.midY-3,width:6,height:6)).fill()
        let text=on ? "开启" : "关闭"
        (text as NSString).draw(in:CGRect(x:23,y:bounds.midY-8,width:36,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:on ? .medium : .regular),.foregroundColor:SketchPalette.ink])
    }
}
@MainActor private final class CardAccessibleEntry:NSAccessibilityElement {
    weak var card:ToolCard?
    init(card:ToolCard,title:String) {
        self.card=card; super.init()
        setAccessibilityRole(.button); setAccessibilityLabel("打开\(title)设置"); setAccessibilityParent(card)
    }
    override func accessibilityFrame()->NSRect {
        guard let card,let window=card.window else { return .zero }
        return window.convertToScreen(card.convert(card.bounds,to:nil))
    }
    override func accessibilityPerformPress()->Bool { card?.accessibilityPerformPress() ?? false }
}
