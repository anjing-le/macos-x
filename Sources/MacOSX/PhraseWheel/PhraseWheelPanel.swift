import AppKit
import MacOSXCore

@MainActor
final class PhraseWheelPanel: NSPanel, NSWindowDelegate {
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private let wheel: PhraseWheelView

    init(layout: PhraseWheelGeometry.Layout, phrases: [String]) {
        wheel = PhraseWheelView(layout: layout, phrases: phrases)
        let frame = layout.panelFrame
        super.init(contentRect: NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = true
        level = .popUpMenu
        collectionBehavior = [.transient, .fullScreenAuxiliary]
        contentView = wheel
        delegate = self
        wheel.onChoose = { [weak self] index in self?.onChoose?(index) }
        wheel.onCancel = { [weak self] in self?.onCancel?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func cancelOperation(_ sender: Any?) { wheel.cancelSelection() }

    func present() {
        acceptsMouseMovedEvents = true
        wheel.beginTracking()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(wheel)
    }

    func dismiss() {
        delegate = nil
        onChoose = nil
        onCancel = nil
        acceptsMouseMovedEvents = false
        wheel.endTracking()
        orderOut(nil)
        close()
    }

    func windowDidResignKey(_ notification: Notification) { wheel.cancelSelection() }
}

@MainActor
private final class PhraseWheelView: NSView {
    var onChoose: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    private let layout: PhraseWheelGeometry.Layout
    private let phrases: [String]
    private var cards: [NSButton] = []
    private let preview = NSTextField(wrappingLabelWithString: "1–9 · 0\nEsc 关闭")
    private var tracking: NSTrackingArea?
    private var trackingEnabled = false
    private var finished = false
    private var selected: Int?
    private var previousDistance = 0.0

    override var acceptsFirstResponder: Bool { true }

    init(layout: PhraseWheelGeometry.Layout, phrases: [String]) {
        self.layout = layout
        self.phrases = phrases
        let frame = layout.panelFrame
        super.init(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        focusRingType = .none
        setAccessibilityLabel("颜文字选择")
        for (index, slot) in layout.slots.enumerated() {
            let digit = index == 9 ? "0" : String(index + 1)
            let phrase = phrases.indices.contains(index) ? phrases[index] : ""
            let text = phrase.isEmpty ? "空" : String(phrase.prefix(12))
            let card = NSButton(title: "\(digit)  \(text)", target: self, action: #selector(cardPressed))
            card.tag = index
            card.isEnabled = !phrase.isEmpty
            card.bezelStyle = .rounded
            card.isBordered = false
            card.font = .systemFont(ofSize: 10, weight: .regular)
            card.lineBreakMode = .byTruncatingTail
            card.wantsLayer = true
            card.layer?.cornerRadius = 8
            card.layer?.borderWidth = 0.5
            card.setAccessibilityLabel("\(digit)：\(phrase.isEmpty ? "空位置" : phrase)")
            card.frame = NSRect(x: slot.frame.x - frame.x, y: slot.frame.y - frame.y,
                                width: slot.frame.width, height: slot.frame.height)
            addSubview(card)
            cards.append(card)
        }
        preview.font = .systemFont(ofSize: 10)
        preview.textColor = .secondaryLabelColor
        preview.alignment = .center
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        preview.setAccessibilityElement(false)
        let width = layout.isFan ? 88.0 : 132.0
        let height = 32.0
        let anchorX = layout.anchor.x - frame.x
        let anchorY = layout.anchor.y - frame.y
        preview.frame = NSRect(x: min(max(0, anchorX - width / 2), max(0, frame.width - width)),
                               y: min(max(0, anchorY - height / 2), max(0, frame.height - height)),
                               width: width, height: height)
        addSubview(preview)
        updateCards()
    }

    required init?(coder: NSCoder) { nil }

    func beginTracking() {
        trackingEnabled = true
        finished = false
        previousDistance = 0
        selected = nil
        updateCards()
        updateTrackingAreas()
    }

    func cancelSelection() { cancel() }

    func endTracking() {
        trackingEnabled = false
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        onChoose = nil
        onCancel = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard trackingEnabled else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard trackingEnabled, !finished, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let point = PhraseWheelGeometry.Point(x: mouse.x, y: mouse.y)
        let candidate = layout.selection(at: point)
        if candidate != selected {
            selected = candidate
            updateCards()
        }
        if let selected, cards[selected].isEnabled,
           layout.crossedCommitRadius(previousDistance: previousDistance, at: point, slot: selected) {
            choose(selected)
            return
        }
        previousDistance = layout.distance(to: point)
    }

    override func mouseExited(with event: NSEvent) {
        cancel()
    }

    override func mouseDown(with event: NSEvent) {
        guard trackingEnabled, !finished, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        if let index = layout.selection(at: .init(x: mouse.x, y: mouse.y)), cards[index].isEnabled {
            choose(index)
        } else {
            cancel()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard trackingEnabled, !finished, !event.isARepeat else { return }
        if event.keyCode == 53 { cancel(); return }
        if event.keyCode == 36, let selected, cards[selected].isEnabled { choose(selected); return }
        guard !event.modifierFlags.contains(.command),
              let text = event.charactersIgnoringModifiers, text.count == 1, let digit = Int(text) else { return }
        let index = digit == 0 ? 9 : digit - 1
        if cards.indices.contains(index), cards[index].isEnabled { choose(index) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCards()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let frame = layout.panelFrame
        NSColor.secondaryLabelColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(ovalIn: NSRect(x: layout.anchor.x - frame.x - 2, y: layout.anchor.y - frame.y - 2, width: 4, height: 4)).fill()
    }

    @objc private func cardPressed(_ sender: NSButton) {
        choose(sender.tag)
    }

    private func choose(_ index: Int) {
        guard trackingEnabled, !finished, cards.indices.contains(index), cards[index].isEnabled else { return }
        finished = true
        onChoose?(index)
    }

    private func cancel() {
        guard trackingEnabled, !finished else { return }
        finished = true
        onCancel?()
    }

    private func updateCards() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            for (index, card) in cards.enumerated() {
                let active = index == selected
                card.contentTintColor = .labelColor
                card.layer?.backgroundColor = (active
                    ? NSColor(srgbRed: dark ? 0.33 : 0.98, green: dark ? 0.24 : 0.90, blue: dark ? 0.27 : 0.92, alpha: 0.98)
                    : NSColor(srgbRed: dark ? 0.17 : 0.995, green: dark ? 0.15 : 0.98, blue: dark ? 0.16 : 0.985, alpha: 0.98)).cgColor
                card.layer?.borderColor = NSColor.labelColor.withAlphaComponent(active ? 0.2 : 0.1).cgColor
                card.layer?.opacity = card.isEnabled ? 1 : 0.45
            }
        }
        if let selected, phrases.indices.contains(selected) {
            preview.stringValue = phrases[selected].isEmpty ? "空位置" : String(phrases[selected].prefix(48))
        } else {
            preview.stringValue = "1–9 · 0\nEsc 关闭"
        }
    }
}
