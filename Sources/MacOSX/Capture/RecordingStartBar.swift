import AppKit

/// One paper surface, genuine accessible buttons, no embedded encoder settings.
@MainActor final class RecordingStartBar: NSView {
    let startButton: MinimalButton
    let cancelButton: MinimalButton
    let systemAudioButton = MinimalToggle(title: "系统声音", target: nil, action: nil)
    let microphoneButton = MinimalToggle(title: "麦克风", target: nil, action: nil)
    private let defaults: UserDefaults
    private let label = NSTextField(labelWithString: "录屏")
    init(target: AnyObject?, start: Selector, cancel: Selector, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startButton = MinimalButton(title: "开始录屏", target: target, action: start, style: .primary)
        cancelButton = MinimalButton(title: "取消", target: target, action: cancel, style: .quiet)
        super.init(frame: .zero)
        label.font = SketchPalette.heading(16); label.textColor = SketchPalette.ink
        startButton.setAccessibilityLabel("开始录屏")
        cancelButton.setAccessibilityLabel("取消录屏选区")
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = []
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        startButton.toolTip = "Enter 开始"; cancelButton.toolTip = "Esc 取消"
        let options = RecordingAudioOptions(defaults: defaults)
        systemAudioButton.state = options.system ? .on : .off
        microphoneButton.state = options.microphone ? .on : .off
        systemAudioButton.toolTip = "录制电脑播放的声音；记住本次选择"
        microphoneButton.toolTip = "录制默认麦克风；开始录屏时才请求权限"
        for button in [systemAudioButton, microphoneButton] {
            button.target = self; button.action = #selector(audioChanged(_:))
            button.font = SketchPalette.heading(14)
        }
        for view in [label, startButton, cancelButton, systemAudioButton, microphoneButton] { addSubview(view) }
        setAccessibilityLabel("录屏控制")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { window?.keyDown(with: event) }
    override func layout() {
        super.layout()
        let compact = bounds.width < 260
        label.isHidden = compact
        label.frame = CGRect(x: 14, y: bounds.height - 40, width: 66, height: 24)
        let x: CGFloat = compact ? 10 : 96
        startButton.frame = CGRect(x: x, y: bounds.height - 48, width: max(90, bounds.width - x - 72), height: 36)
        cancelButton.frame = CGRect(x: bounds.width - 62, y: bounds.height - 48, width: 52, height: 36)
        let half = (bounds.width - 28) / 2
        systemAudioButton.frame = CGRect(x: 14, y: 12, width: half, height: 30)
        microphoneButton.frame = CGRect(x: 14 + half, y: 12, width: half, height: 30)
    }
    @objc private func audioChanged(_ sender: NSButton) {
        RecordingAudioOptions(system: systemAudioButton.state == .on,
                              microphone: microphoneButton.state == .on).save(to: defaults)
    }
    override func draw(_ dirtyRect: NSRect) {
        MinimalSurface.draw(in: bounds.insetBy(dx: 1, dy: 1), fill: SketchPalette.paper, border: SketchPalette.line)
    }
}
