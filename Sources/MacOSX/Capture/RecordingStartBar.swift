import AppKit

/// One paper surface, genuine accessible buttons, no embedded encoder settings.
@MainActor final class RecordingStartBar: NSView {
    let startButton: MinimalButton
    let cancelButton: MinimalButton
    private let label = NSTextField(labelWithString: "录屏")
    init(target: AnyObject?, start: Selector, cancel: Selector) {
        startButton = MinimalButton(title: "开始录屏", target: target, action: start, style: .primary)
        cancelButton = MinimalButton(title: "取消", target: target, action: cancel, style: .quiet)
        super.init(frame: .zero)
        label.font = SketchPalette.heading(16); label.textColor = SketchPalette.ink
        startButton.setAccessibilityLabel("开始录屏")
        cancelButton.setAccessibilityLabel("取消录屏选区")
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = []
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        startButton.toolTip = "Enter 开始"; cancelButton.toolTip = "Esc 取消"
        for view in [label, startButton, cancelButton] { addSubview(view) }
        setAccessibilityLabel("录屏控制")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { window?.keyDown(with: event) }
    override func layout() {
        super.layout()
        let compact = bounds.width < 260
        label.isHidden = compact
        label.frame = CGRect(x: 14, y: (bounds.height - 24) / 2, width: 66, height: 24)
        let x: CGFloat = compact ? 10 : 96
        startButton.frame = CGRect(x: x, y: 10, width: max(90, bounds.width - x - 72), height: bounds.height - 20)
        cancelButton.frame = CGRect(x: bounds.width - 62, y: 10, width: 52, height: bounds.height - 20)
    }
    override func draw(_ dirtyRect: NSRect) {
        MinimalSurface.draw(in: bounds.insetBy(dx: 1, dy: 1), fill: SketchPalette.paper, border: SketchPalette.line)
    }
}
