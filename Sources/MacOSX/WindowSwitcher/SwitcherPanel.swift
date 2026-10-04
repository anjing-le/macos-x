import AppKit

/// Icons only: selecting windows never requires screen-recording permission.
@MainActor final class SwitcherPanel {
    private final class Panel: NSPanel {
        var acceptsPreviewKeyboard = false
        var onMove: ((Int) -> Void)?
        var onConfirm: (() -> Void)?
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { acceptsPreviewKeyboard }
        override var canBecomeMain: Bool { false }

        override func keyDown(with event: NSEvent) {
            guard acceptsPreviewKeyboard else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 53: onCancel?()
            case 36, 76: onConfirm?()
            case 123, 126: onMove?(-1)
            case 124, 125: onMove?(1)
            default: super.keyDown(with: event)
            }
        }

        override func cancelOperation(_ sender: Any?) {
            if acceptsPreviewKeyboard { onCancel?() } else { super.cancelOperation(sender) }
        }

        override func resignKey() {
            super.resignKey()
            // A preview closes when the user clicks back into another window.
            if acceptsPreviewKeyboard { onCancel?() }
        }
    }
    private let panel: Panel
    private let canvas = SwitcherCanvas()
    var onChoose: ((CGWindowID) -> Void)? { didSet { canvas.onChoose = onChoose } }
    var onMove: ((Int) -> Void)? { didSet { panel.onMove = onMove } }
    var onConfirm: (() -> Void)? { didSet { panel.onConfirm = onConfirm } }
    var onCancel: (() -> Void)? { didSet { panel.onCancel = onCancel } }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 148),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = canvas; panel.isReleasedWhenClosed = false
    }

    func show(windows: [SwitcherWindow], selectedID: CGWindowID?, preview: Bool) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let capacity = max(1, min(8, Int((area.width - 72) / 108)))
        canvas.configure(windows, selectedID, capacity)
        let width = CGFloat(min(capacity, max(1, windows.count))) * 108 + 32
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.midY - 74, width: width, height: 148), display: true)
        panel.acceptsPreviewKeyboard = preview
        if preview {
            // Preview is an explicit local UI action. Normal Cmd+Tab never takes key focus.
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(nil)
        } else { panel.orderFrontRegardless() }
    }

    func hide() { panel.acceptsPreviewKeyboard = false; panel.orderOut(nil) }
    func clear() { hide(); canvas.configure([], nil, 8) }
}

@MainActor private final class SwitcherCanvas: NSView {
    private var windows = [SwitcherWindow]()
    private var selectedID: CGWindowID?
    private var capacity = 8
    var onChoose: ((CGWindowID) -> Void)?
    override var isFlipped: Bool { true }
    private var pageStart: Int { (windows.firstIndex { $0.id == selectedID } ?? 0) / capacity * capacity }
    private var page: [SwitcherWindow] { Array(windows.dropFirst(pageStart).prefix(capacity)) }

    func configure(_ windows: [SwitcherWindow], _ selectedID: CGWindowID?, _ capacity: Int) {
        self.windows = windows; self.selectedID = selectedID; self.capacity = max(1, capacity)
        needsDisplay = true
        setAccessibilityLabel("窗口切换")
        setAccessibilityValue(windows.first { $0.id == selectedID }.map { $0.applicationName + "，" + $0.title })
    }

    private func cell(_ index: Int) -> NSRect { NSRect(x: 16 + CGFloat(index) * 108, y: 12, width: 100, height: 100) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
        for (index, window) in page.enumerated() {
            let rect = cell(index)
            if window.id == selectedID {
                NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            }
            if let icon = window.icon {
                icon.draw(in: NSRect(x: rect.midX - 24, y: rect.minY + 10, width: 48, height: 48),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            text(window.title, rect: NSRect(x: rect.minX + 5, y: rect.minY + 65, width: 90, height: 17),
                 font: .systemFont(ofSize: 11, weight: window.id == selectedID ? .medium : .regular), color: .labelColor)
            text(window.isMinimized ? "已最小化" : window.applicationName,
                 rect: NSRect(x: rect.minX + 5, y: rect.minY + 83, width: 90, height: 14),
                 font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
        }
        let selected = windows.first { $0.id == selectedID }
        let index = windows.firstIndex { $0.id == selectedID }.map { $0 + 1 } ?? 0
        text(selected?.title ?? "", rect: NSRect(x: 20, y: 123, width: max(0, bounds.width - 90), height: 16),
             font: .systemFont(ofSize: 11), color: .secondaryLabelColor, centered: false)
        text("\(index)/\(windows.count)", rect: NSRect(x: bounds.width - 64, y: 123, width: 44, height: 16),
             font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: .tertiaryLabelColor)
    }

    private func text(_ string: String, rect: NSRect, font: NSFont, color: NSColor, centered: Bool = true) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        style.alignment = centered ? .center : .left
        (string as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, window) in page.enumerated() where cell(index).contains(point) { onChoose?(window.id); return }
    }
}
