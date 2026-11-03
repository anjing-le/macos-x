import MacOSXCore
import AppKit

/// A single start button at rest; one contiguous paper tray appears on hover or keyboard request.
@MainActor final class RecordingStartBar: NSView {
    static let collapsedSize = CGSize(width:136,height:40)
    static let expandedSize = CGSize(width:282,height:140)
    static func presentationFrame(expanded:Bool,in fullFrame:CGRect)->CGRect {
        guard !expanded else { return fullFrame }
        let width=min(collapsedSize.width,fullFrame.width)
        return CGRect(x:fullFrame.midX-width/2,y:fullFrame.maxY-collapsedSize.height,width:width,height:collapsedSize.height)
    }
    let startButton: MinimalButton
    let cancelButton: MinimalButton
    let systemAudioButton = MinimalToggle(title: AppLanguage.text("系统声音"), target: nil, action: nil)
    let microphoneButton = MinimalToggle(title: AppLanguage.text("麦克风"), target: nil, action: nil)
    let qualityButtons: [MinimalButton]
    private let defaults: UserDefaults
    private(set) var optionsExpanded = false
    var onExpansionChanged: ((Bool) -> Void)?
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }
    private var tracking: NSTrackingArea?
    private var collapseWork: DispatchWorkItem?
    private var keyboardOptions = false
    private var observers: [NSObjectProtocol] = []

    init(target: AnyObject?, start: Selector, cancel: Selector, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startButton = RecordingStartButton(title: AppLanguage.text("开始录屏"), target: target, action: start, style: .primary)
        cancelButton = MinimalButton(title: AppLanguage.text("取消"), target: target, action: cancel, style: .quiet)
        qualityButtons = RecordingQuality.allCases.map { MinimalButton(title:$0.title,target:nil,action:nil,style:.quiet) }
        super.init(frame: CGRect(origin:.zero,size:Self.collapsedSize))
        startButton.font = AppLanguage.current == .english ? .systemFont(ofSize:13,weight:.medium) : SketchPalette.heading(15)
        cancelButton.title = "×"
        cancelButton.font = .systemFont(ofSize:14)
        startButton.keyEquivalent = "\r"; startButton.keyEquivalentModifierMask = []
        cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        startButton.setAccessibilityLabel(AppLanguage.text("开始录屏"))
        cancelButton.setAccessibilityLabel(AppLanguage.text("取消录屏选区"))
        startButton.toolTip = AppLanguage.text("悬停调整画质和声音；Tab 或 ↓ 展开，Enter 开始，Esc 取消")
        startButton.setAccessibilityHelp(startButton.toolTip)
        cancelButton.toolTip = AppLanguage.text("Esc 取消")
        (startButton as? RecordingStartButton)?.onOptions = { [weak self] backwards in self?.focusOptions(backwards:backwards) }
        let options = RecordingAudioOptions(defaults:defaults)
        systemAudioButton.state = options.system ? .on : .off
        microphoneButton.state = options.microphone ? .on : .off
        systemAudioButton.toolTip = AppLanguage.text("录制电脑播放的声音；记住本次选择")
        microphoneButton.toolTip = AppLanguage.text("录制默认麦克风；开始录屏时才请求权限")
        for button in [systemAudioButton,microphoneButton] {
            button.target = self; button.action = #selector(audioChanged(_:))
            button.font = .systemFont(ofSize:12)
        }
        for (index,button) in qualityButtons.enumerated() {
            button.tag=index; button.font = .systemFont(ofSize:13,weight:.medium)
            button.setButtonType(.pushOnPushOff)
            button.target=self; button.action = #selector(qualityChanged(_:))
            button.setAccessibilityLabel(AppLanguage.text("录屏清晰度")+" "+button.title)
            button.toolTip=RecordingQuality.allCases[index].help
        }
        for view in [startButton,cancelButton,systemAudioButton,microphoneButton]+qualityButtons { addSubview(view) }
        refreshQuality()
        updateOptionsVisibility()
        // Explicit native key loop works independently of the system's full keyboard access preference.
        let order=[startButton]+qualityButtons+[systemAudioButton,microphoneButton,cancelButton]
        for index in order.indices { order[index].nextKeyView=order[(index+1)%order.count] }
        setAccessibilityLabel(AppLanguage.text("录屏控制"))
    }
    required init?(coder:NSCoder) { nil }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    override var acceptsFirstResponder:Bool { true }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 48 || event.keyCode == 125 { focusOptions(backwards:event.modifierFlags.contains(.shift)) }
        else { window?.keyDown(with:event) }
    }
    func focusOptions(backwards:Bool = false) {
        collapseWork?.cancel(); collapseWork=nil
        keyboardOptions=true; setOptionsExpanded(true)
        window?.makeFirstResponder(backwards ? cancelButton : qualityButtons[0])
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers.removeAll()
        resetPresentation()
        if let window {
            for name in [NSWindow.didResignKeyNotification,NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resetPresentation() }
                })
            }
        }
    }
    func resetPresentation() {
        collapseWork?.cancel(); collapseWork=nil; keyboardOptions=false
        setOptionsExpanded(false)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self)
        addTrackingArea(area); tracking=area
    }
    override func mouseEntered(with event:NSEvent) {
        collapseWork?.cancel(); collapseWork=nil; keyboardOptions=false
        setOptionsExpanded(true)
    }
    override func mouseExited(with event:NSEvent) { scheduleCollapse() }
    func scheduleCollapse() {
        collapseWork?.cancel(); collapseWork=nil
        guard optionsExpanded,!keyboardOptions else { return }
        let work=DispatchWorkItem { [weak self] in
            guard let self,!self.keyboardOptions else { return }
            self.collapseWork=nil
            // Old exit events caused by resizing must not close a tray under the pointer.
            if let window=self.window,window.frame.contains(self.pointerLocation()) { return }
            self.setOptionsExpanded(false)
        }
        collapseWork=work; DispatchQueue.main.asyncAfter(deadline:.now()+0.3,execute:work)
    }
    private func setOptionsExpanded(_ expanded:Bool) {
        guard expanded != optionsExpanded else { return }
        if !expanded,let responder=window?.firstResponder as? NSView,responder !== startButton,responder.isDescendant(of:self) {
            window?.makeFirstResponder(startButton)
        }
        optionsExpanded=expanded; updateOptionsVisibility()
        onExpansionChanged?(expanded)
        needsLayout=true; needsDisplay=true
    }
    private func updateOptionsVisibility() {
        for view in [cancelButton,systemAudioButton,microphoneButton]+qualityButtons { view.isHidden = !optionsExpanded }
    }
    override func layout() {
        super.layout()
        startButton.frame=CGRect(x:(bounds.width-Self.collapsedSize.width)/2,y:bounds.height-40,width:Self.collapsedSize.width,height:40)
        let compact = bounds.width < 260 || (AppLanguage.current == .english && bounds.width < 320)
        systemAudioButton.title = compact ? AppLanguage.text("系统") : AppLanguage.text("系统声音")
        microphoneButton.title = compact ? AppLanguage.text("话筒") : AppLanguage.text("麦克风")
        systemAudioButton.setAccessibilityLabel(AppLanguage.text("系统声音"))
        microphoneButton.setAccessibilityLabel(AppLanguage.text("麦克风"))
        let gap:CGFloat=6,inset:CGFloat=12
        let width=(bounds.width-2*inset-2*gap)/3
        for (index,button) in qualityButtons.enumerated() {
            button.frame=CGRect(x:inset+CGFloat(index)*(width+gap),y:bounds.height-81,width:width,height:28)
        }
        let audioWidth=(bounds.width-2*inset-20)/2
        systemAudioButton.frame=CGRect(x:inset,y:10,width:audioWidth,height:30)
        microphoneButton.frame=CGRect(x:inset+audioWidth,y:10,width:audioWidth,height:30)
        cancelButton.frame=CGRect(x:bounds.width-inset-20,y:10,width:20,height:30)
    }
    private func refreshQuality() {
        let quality=RecordingQuality.load(from:defaults)
        for (index,button) in qualityButtons.enumerated() { button.state=RecordingQuality.allCases[index] == quality ? .on : .off; button.needsDisplay=true }
    }
    @objc private func qualityChanged(_ sender:NSButton) {
        guard RecordingQuality.allCases.indices.contains(sender.tag) else { return }
        RecordingQuality.allCases[sender.tag].save(to:defaults); refreshQuality()
    }
    @objc private func audioChanged(_ sender:NSButton) {
        RecordingAudioOptions(system:systemAudioButton.state == .on,microphone:microphoneButton.state == .on).save(to:defaults)
    }
    override func draw(_ dirtyRect:NSRect) {
        if optionsExpanded {
            MinimalSurface.draw(in:CGRect(x:1,y:1,width:bounds.width-2,height:bounds.height-29),fill:SketchPalette.paper,border:SketchPalette.line)
        }
    }
}

@MainActor private final class RecordingStartButton: MinimalButton {
    var onOptions: ((Bool)->Void)?
    override func keyDown(with event:NSEvent) {
        if [48,125].contains(event.keyCode) { onOptions?(event.modifierFlags.contains(.shift)) }
        else { super.keyDown(with:event) }
    }
    override func accessibilityPerformShowMenu()->Bool { onOptions?(false); return true }
}
