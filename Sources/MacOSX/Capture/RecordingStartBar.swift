import MacOSXCore
import AppKit

/// One paper surface, genuine accessible buttons, quality presets without expert encoder settings.
@MainActor final class RecordingStartBar: NSView {
    let startButton: MinimalButton
    let cancelButton: MinimalButton
    let systemAudioButton = MinimalToggle(title: AppLanguage.text("系统声音"), target: nil, action: nil)
    let microphoneButton = MinimalToggle(title: AppLanguage.text("麦克风"), target: nil, action: nil)
    let qualityChoice = MinimalPopUpButton()
    private let qualityLabel = NSTextField(labelWithString: AppLanguage.text("清晰度"))
    private let defaults: UserDefaults
    private let label = NSTextField(labelWithString: AppLanguage.text("录屏"))
    init(target: AnyObject?, start: Selector, cancel: Selector, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startButton = MinimalButton(title: AppLanguage.text("开始录屏"), target: target, action: start, style: .primary)
        cancelButton = MinimalButton(title: AppLanguage.text("取消"), target: target, action: cancel, style: .quiet)
        super.init(frame: .zero)
        if AppLanguage.current == .english {
            startButton.font = .systemFont(ofSize: 13, weight: .medium)
            cancelButton.font = .systemFont(ofSize: 13)
        }
        label.font = SketchPalette.heading(16); label.textColor = SketchPalette.ink
        startButton.setAccessibilityLabel(AppLanguage.text("开始录屏"))
        cancelButton.setAccessibilityLabel(AppLanguage.text("取消录屏选区"))
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = []
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        startButton.toolTip = AppLanguage.text("Enter 开始"); cancelButton.toolTip = AppLanguage.text("Esc 取消")
        let options = RecordingAudioOptions(defaults: defaults)
        systemAudioButton.state = options.system ? .on : .off
        microphoneButton.state = options.microphone ? .on : .off
        systemAudioButton.toolTip = AppLanguage.text("录制电脑播放的声音；记住本次选择")
        microphoneButton.toolTip = AppLanguage.text("录制默认麦克风；开始录屏时才请求权限")
        for button in [systemAudioButton, microphoneButton] {
            button.target = self; button.action = #selector(audioChanged(_:))
            button.font = SketchPalette.heading(14)
        }
        qualityLabel.font = .systemFont(ofSize:13); qualityLabel.textColor = SketchPalette.ink
        qualityChoice.font = .systemFont(ofSize:14)
        qualityChoice.addItems(withTitles: RecordingQuality.allCases.map(\.title))
        qualityChoice.selectItem(at: RecordingQuality.allCases.firstIndex(of: RecordingQuality.load(from: defaults)) ?? 2)
        qualityChoice.target = self; qualityChoice.action = #selector(qualityChanged(_:))
        qualityChoice.setAccessibilityLabel(AppLanguage.text("录屏清晰度"))
        refreshQualityHelp()
        for view in [qualityLabel, qualityChoice, label, startButton, cancelButton, systemAudioButton, microphoneButton] { addSubview(view) }
        setAccessibilityLabel(AppLanguage.text("录屏控制"))
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
        if AppLanguage.current == .english {
            // Compact English names retain full meanings in the accessible labels and tooltips.
            systemAudioButton.title = bounds.width < 300 ? AppLanguage.text("系统") : AppLanguage.text("系统声音")
            microphoneButton.title = bounds.width < 300 ? AppLanguage.text("话筒") : AppLanguage.text("麦克风")
            systemAudioButton.setAccessibilityLabel(AppLanguage.text("系统声音"))
            microphoneButton.setAccessibilityLabel(AppLanguage.text("麦克风"))
            systemAudioButton.font = .systemFont(ofSize: 12)
            microphoneButton.font = .systemFont(ofSize: 12)
        }
        qualityLabel.frame = CGRect(x:14,y:50,width:64,height:28)
        qualityChoice.frame = CGRect(x:86,y:50,width:max(96,bounds.width-100),height:28)
        let half = (bounds.width - 28) / 2
        systemAudioButton.frame = CGRect(x: 14, y: 12, width: half, height: 30)
        microphoneButton.frame = CGRect(x: 14 + half, y: 12, width: half, height: 30)
    }
    private func refreshQualityHelp() {
        qualityChoice.toolTip = RecordingQuality.load(from: defaults).help
    }
    @objc private func qualityChanged(_ sender: Any?) {
        guard RecordingQuality.allCases.indices.contains(qualityChoice.indexOfSelectedItem) else { return }
        RecordingQuality.allCases[qualityChoice.indexOfSelectedItem].save(to: defaults)
        refreshQualityHelp()
    }
    @objc private func audioChanged(_ sender: NSButton) {
        RecordingAudioOptions(system: systemAudioButton.state == .on,
                              microphone: microphoneButton.state == .on).save(to: defaults)
    }
    override func draw(_ dirtyRect: NSRect) {
        MinimalSurface.draw(in: bounds.insetBy(dx: 1, dy: 1), fill: SketchPalette.paper, border: SketchPalette.line)
    }
}
