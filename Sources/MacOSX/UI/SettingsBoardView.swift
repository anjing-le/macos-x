import AppKit

/// Native settings controls with bounded, shared artwork. Images explain the action;
/// the button state and saved values remain native and accessible.
@MainActor final class IllustratedSettingChoice: MinimalButton {
    private static var images: [String: NSImage] = [:]
    static func artwork(_ name: String) -> NSImage? {
        if images[name] == nil, let url=Bundle.main.url(forResource:name,withExtension:"png") { images[name]=NSImage(contentsOf:url) }
        return images[name]
    }
    private let asset: String
    private let slice: CGRect
    var pinGlow: Bool?
    var promptList: Bool?
    var backdropOnly = false
    var checkOnly = false
    init(title: String, asset: String, slice: CGRect, target: AnyObject?, action: Selector?) {
        self.asset = asset; self.slice = slice
        super.init(frame: .zero)
        self.title=title; self.target=target; self.action=action; self.style = .quiet
        setButtonType(.radio); setAccessibilityLabel(title)
        _ = Self.artwork(asset)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 156) }
    override func draw(_ dirtyRect: NSRect) {
        if backdropOnly {
            if state == .on {
                if !checkOnly { SketchPencil.stroke(SketchPencil.outline(in:bounds.insetBy(dx:2,dy:2),radius:10),color:SketchPalette.yellow,width:1.8) }
                let dot=CGRect(x:bounds.width-18,y:2,width:16,height:16)
                (checkOnly ? SketchPalette.blue : SketchPalette.yellow).setFill(); NSBezierPath(ovalIn:dot).fill()
                let tick=NSBezierPath(); tick.move(to:CGPoint(x:dot.minX+4,y:dot.midY)); tick.line(to:CGPoint(x:dot.minX+7,y:dot.midY+3)); tick.line(to:CGPoint(x:dot.maxX-3,y:dot.minY+4))
                NSColor.white.setStroke(); tick.lineWidth=1.4; tick.stroke()
            }
            if window?.firstResponder === self { SketchPencil.stroke(SketchPencil.outline(in:bounds.insetBy(dx:1,dy:1),radius:8),color:SketchPalette.yellow,width:1.4) }
            return
        }
        let box = bounds.insetBy(dx: 3, dy: 3)
        SketchPalette.paper.setFill(); NSBezierPath(roundedRect: box, xRadius: 16, yRadius: 16).fill()
        let border = SketchPencil.outline(in:box,radius:16)
        (state == .on ? SketchPalette.yellow : SketchPalette.muted.withAlphaComponent(0.3)).setStroke()
        SketchPencil.stroke(border, color: state == .on ? SketchPalette.yellow : SketchPalette.muted.withAlphaComponent(0.3), width: state == .on ? 1.8 : 0.85)
        if let list=promptList {
            let center=NSPoint(x:22,y:bounds.height/2)
            SketchPalette.purple.withAlphaComponent(0.25).setFill()
            SketchPalette.ink.setStroke()
            if list {
                for row in -1...1 {
                    let rect=CGRect(x:9,y:center.y+CGFloat(row)*8-2,width:26,height:5)
                    let path=NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2); path.fill(); path.lineWidth=0.7; path.stroke()
                }
            } else {
                for index in 0..<8 {
                    let angle=CGFloat(index)*CGFloat.pi/4
                    let rect=CGRect(x:center.x+cos(angle)*12-3,y:center.y+sin(angle)*12-3,width:6,height:6)
                    let path=NSBezierPath(roundedRect:rect,xRadius:2,yRadius:2); path.fill(); path.lineWidth=0.6; path.stroke()
                }
            }
        } else if let glow = pinGlow {
            let tile = CGRect(x: bounds.width*0.2, y: 40, width: bounds.width*0.6, height: bounds.height-55)
            SketchPalette.muted.withAlphaComponent(0.12).setFill(); NSBezierPath(roundedRect:tile.insetBy(dx:-8,dy:-6),xRadius:8,yRadius:8).fill()
            NSGraphicsContext.saveGraphicsState()
            if glow { let shadow=NSShadow(); shadow.shadowColor = .white; shadow.shadowBlurRadius=8; shadow.set() }
            SketchPalette.blue.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect:tile,xRadius:6,yRadius:6).fill()
            if glow { NSColor.white.setStroke(); let edge=NSBezierPath(roundedRect:tile.insetBy(dx:-2,dy:-2),xRadius:7,yRadius:7); edge.lineWidth=2; edge.stroke() }
            NSGraphicsContext.restoreGraphicsState()
        } else if let image = Self.images[asset] {
            let source = CGRect(x: slice.minX * image.size.width, y: slice.minY * image.size.height,
                                width: slice.width * image.size.width, height: slice.height * image.size.height)
            image.draw(in: bounds.height < 70 ? CGRect(x:6,y:8,width:32,height:bounds.height-16) : CGRect(x:12,y:36,width:bounds.width-24,height:bounds.height-48),
                       from: source, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: SketchPalette.heading(15), .foregroundColor: SketchPalette.ink]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: bounds.height < 70 ? 42 : (bounds.width-size.width)/2, y: bounds.height < 70 ? (bounds.height-size.height)/2 : 10), withAttributes: attributes)
        if state == .on {
            let check = NSBezierPath(); check.move(to: NSPoint(x: bounds.width-25,y:20))
            check.line(to:NSPoint(x:bounds.width-21,y:24)); check.line(to:NSPoint(x:bounds.width-14,y:15))
            SketchPalette.ink.setStroke(); check.lineWidth = 1.8; check.stroke()
        }
        if window?.firstResponder === self { NSFocusRingPlacement.only.set(); border.stroke() }
    }
}

/// Keep shortcut names and their editable keycaps inside the corresponding
/// feature column. Spatial grouping is the association; no decorative arrows.
@MainActor final class ShortcutSettingsRow: NSView {
    let control: NSView
    override var isFlipped: Bool { true }
    init(_ control: NSView) {
        self.control = control
        super.init(frame: .zero)
        addSubview(control)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: max(220, control.fittingSize.width), height: max(42, control.fittingSize.height))
    }
    override func layout() {
        super.layout()
        control.frame = control is NSTextField ? CGRect(x:0,y:(bounds.height-24)/2,width:bounds.width,height:24) : bounds
    }
}

@MainActor final class SettingsBoardView: NSView {
    private let kind: String
    private let settings: NSView
    private let settingsWidth: NSLayoutConstraint
    private let shortcuts: [NSView]
    private var art: [NSView] = []
    private var selectors: [IllustratedSettingChoice] = []
    private var sourceToggle: NSButton?
    private var sourceMode: NSPopUpButton?
    private let backdrop: NSImage?
    private let captureHints = [NSTextField(labelWithString:"按上方快捷键开始截图"),NSTextField(labelWithString:"框选后 Enter 开始录屏")]
    var usesBackdrop: Bool { backdrop != nil && !compact }
    func slot(_ rect: CGRect) -> CGRect { CGRect(x:rect.minX*bounds.width,y:rect.minY*(usesBackdrop ? backdropHeight : bounds.height),width:rect.width*bounds.width,height:rect.height*(usesBackdrop ? backdropHeight : bounds.height)) }
    static let captureKeySlots = [CGRect(x:0.148,y:0.13,width:0.07,height:0.09),CGRect(x:0.465,y:0.13,width:0.07,height:0.09),CGRect(x:0.39,y:0.73,width:0.068,height:0.074),CGRect(x:0.783,y:0.13,width:0.09,height:0.09)]
    private var backdropHeight: CGFloat { bounds.width * (kind == "capture" ? 0.5 : 635.0/1774.0) }
    private var wasCompact=false
    private var lastLayoutWidth: CGFloat = 0
    private var lastSettingsHeight: CGFloat = 0
    private var compact: Bool { bounds.width < 740 }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { if usesBackdrop { return NSSize(width:840,height:kind == "capture" ? max(backdropHeight,backdropHeight*0.838+settings.fittingSize.height) : backdropHeight) }; return NSSize(width:840,height:kind == "kaomoji" ? (compact ? 848 : 470) : (kind == "capture" ? max(compact ? 864 : 440,(compact ? 664 : 352)+settings.fittingSize.height) : (compact ? 550 : 410))) }
    init(kind: String, settings: NSView, shortcuts: [NSView]) {
        self.kind=kind; self.settings=settings; self.shortcuts=shortcuts.map(ShortcutSettingsRow.init)
        backdrop = kind == "capture" ? IllustratedSettingChoice.artwork("SettingsCaptureBoard") : (kind == "windowSwitcher" ? IllustratedSettingChoice.artwork("SettingsSwitcherBoard") : nil)
        if let existing=settings.constraints.first(where: { $0.identifier == "settings-board-width" }) { settingsWidth=existing }
        else { settingsWidth=settings.widthAnchor.constraint(equalToConstant:840); settingsWidth.identifier="settings-board-width" }
        super.init(frame: CGRect(x:0,y:0,width:840,height:410))
        settingsWidth.isActive=true
        addSubview(settings); for shortcut in self.shortcuts { addSubview(shortcut) }
        for hint in captureHints { hint.font = .systemFont(ofSize:13); hint.textColor=SketchPalette.ink; hint.alignment = .center; hint.isHidden=true; addSubview(hint) }
        if kind == "capture", let stack=settings as? NSStackView, stack.arrangedSubviews.count >= 4 {
            let toggle=stack.arrangedSubviews.first { $0.identifier?.rawValue == "capture-pin-outline" } as? NSButton
            sourceToggle=toggle
            // Keep cached source controls in their stack: reopening the page must
            // still find the same target/action and current persisted state.
            for view in stack.arrangedSubviews where ["capture-pin-outline","capture-pin-help"].contains(view.identifier?.rawValue ?? "") { view.isHidden=true }
            for (index,title) in ["截图 · 指向窗口吸附", "贴图 · 白光边缘", "录屏 · 框选后 Enter"].enumerated() {
                let image=IllustratedSettingChoice(title:title,asset:"GuideCapture",slice:CGRect(x:CGFloat(index)/3,y:0,width:1/3,height:1),target:nil,action:nil)
                image.isEnabled=false; image.setAccessibilityRole(.image); addSubview(image); art.append(image)
            }
            for (index,title) in ["无边缘", "白光边缘"].enumerated() {
                let button=IllustratedSettingChoice(title:title,asset:"GuideCapture",slice:CGRect(x:1/3,y:0,width:1/3,height:1),target:self,action:#selector(selectOutline(_:)))
                button.pinGlow=index == 1; button.tag=index; button.toolTip=index == 1 ? "贴图显示白光边缘" : "贴图不显示边缘"; button.setAccessibilityLabel("贴图：\(title)"); selectors.append(button); addSubview(button)
            }
            refreshChoices()
        } else if kind == "windowSwitcher", let stack=settings as? NSStackView,
                  let row=stack.arrangedSubviews.first(where: { $0.identifier?.rawValue == "switcher-presentation-row" }) as? NSStackView,
                  let mode=row.arrangedSubviews.compactMap({ $0 as? NSPopUpButton }).first {
            sourceMode=mode; row.isHidden=true
            for (index,title) in ["两行 · 分页", "全部 · 滚动"].enumerated() {
                let button=IllustratedSettingChoice(title:title,asset:"GuideSwitcher",slice:CGRect(x:CGFloat(index)/2,y:0,width:0.5,height:1),target:self,action:#selector(selectMode(_:)))
                button.tag=index; selectors.append(button); addSubview(button)
            }
            refreshChoices()
        }
    }
    required init?(coder: NSCoder) { nil }
    @objc private func selectOutline(_ sender: NSButton) {
        guard let toggle=sourceToggle else { return }
        toggle.state=sender.tag == 1 ? .on : .off
        if let action=toggle.action { NSApp.sendAction(action,to:toggle.target,from:toggle) }
        refreshChoices()
    }
    @objc private func selectMode(_ sender: NSButton) {
        guard let mode=sourceMode else { return }
        mode.selectItem(at:sender.tag)
        if let action=mode.action { NSApp.sendAction(action,to:mode.target,from:mode) }
        refreshChoices()
    }
    private func refreshChoices() {
        for button in selectors {
            let selected=kind == "capture" ? sourceToggle?.state == (button.tag == 1 ? .on : .off) : sourceMode?.indexOfSelectedItem == button.tag
            button.state=selected ? .on : .off; button.needsDisplay=true
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        SketchPalette.paper.setFill(); dirtyRect.fill()
        guard usesBackdrop, let backdrop else { return }
        let source = kind == "capture" ? CGRect(origin:.zero,size:backdrop.size) : CGRect(x:0,y:67,width:1774,height:635)
        backdrop.draw(in:CGRect(x:0,y:0,width:bounds.width,height:backdropHeight),from:source,operation:.sourceOver,fraction:1,respectFlipped:true,hints:[.interpolation:NSImageInterpolation.high])
    }
    private func configureFooter(_ view:NSView) {
        if let footer=view as? RecordingSettingsFooter { footer.usesArtwork=usesBackdrop }
        if let footer=view as? SwitcherSettingsFooter { footer.usesArtwork=usesBackdrop }
        for child in view.subviews { configureFooter(child) }
    }
    // Entire illustration and caption are one target, in the source image coordinate space.
    static let captureOutlineSlots=[CGRect(x:670.0/1774.0,y:455.0/887.0,width:175.0/1774.0,height:170.0/887.0),
                                    CGRect(x:925.0/1774.0,y:455.0/887.0,width:175.0/1774.0,height:170.0/887.0)]
    private func layoutBackdrop() {
        for view in art { view.isHidden=true }
        for choice in selectors { choice.backdropOnly=true; choice.checkOnly=kind == "capture" }
        if kind == "capture" {
            for (i,view) in shortcuts.enumerated() { view.frame=slot(Self.captureKeySlots[i]) }
            for (i,view) in selectors.enumerated() { view.frame=slot(Self.captureOutlineSlots[i]) }
            for (i,hint) in captureHints.enumerated() { hint.isHidden=false; hint.frame=slot(CGRect(x:i == 0 ? 0.03 : 0.68,y:0.68,width:0.29,height:0.07)) }
            settings.frame=slot(CGRect(x:0,y:0.838,width:1,height:0.162))
            settings.frame.size.height=max(settings.frame.height,settings.fittingSize.height)
        } else {
            selectors[0].frame=slot(CGRect(x:70.0/1774.0,y:42.0/635.0,width:450.0/1774.0,height:482.0/635.0))
            selectors[1].frame=slot(CGRect(x:550.0/1774.0,y:42.0/635.0,width:465.0/1774.0,height:482.0/635.0))
            shortcuts.first?.frame=slot(CGRect(x:0.659,y:24.0/635.0,width:0.107,height:94.0/635.0))
            settings.frame=slot(CGRect(x:0.70,y:0.69,width:0.27,height:0.31))
        }
        settingsWidth.constant=settings.frame.width
        settings.layoutSubtreeIfNeeded()
        updateSettingsHeight()
        for row in shortcuts { row.layoutSubtreeIfNeeded() }
    }
    private func updateSettingsHeight() {
        let measured=settings.fittingSize.height
        if abs(lastSettingsHeight-measured)>0.5 { lastSettingsHeight=measured; invalidateIntrinsicContentSize() }
    }
    override func layout() {
        super.layout()
        let w=bounds.width
        if abs(lastLayoutWidth-w) > 0.5 { lastLayoutWidth=w; invalidateIntrinsicContentSize() }
        configureFooter(settings)
        if wasCompact != compact { wasCompact=compact; invalidateIntrinsicContentSize() }
        if usesBackdrop { layoutBackdrop(); needsDisplay=true; return }
        for view in art { view.isHidden=false }
        for choice in selectors { choice.backdropOnly=false }
        for hint in captureHints { hint.isHidden=true }
        if compact && kind == "capture" {
            let artY: [CGFloat] = [0, 168, 484]
            for (i, view) in art.enumerated() {
                view.frame = CGRect(x: 0, y: artY[i], width: w, height: 118)
            }
            let shortcutY: [CGFloat] = [120, 288, 334, 604]
            for (i, view) in shortcuts.enumerated() {
                view.frame = CGRect(x: 0, y: shortcutY[i], width: w, height: 46)
            }
            for (i, view) in selectors.enumerated() {
                view.frame = CGRect(x: CGFloat(i)*w/2, y: 382, width: w/2-4, height: 88)
            }
            settings.frame = CGRect(x: 0, y: 664, width: w, height: settings.fittingSize.height)
        } else if compact && kind == "windowSwitcher" {
            for (i,view) in selectors.enumerated() { view.frame=CGRect(x:0,y:CGFloat(i)*164,width:w,height:156) }
            shortcuts.first?.frame=CGRect(x:0,y:332,width:w,height:50)
            settings.frame=CGRect(x:0,y:398,width:w,height:settings.fittingSize.height)
        } else if kind == "capture" {
            let col=(w-24)/3
            for (i,view) in art.enumerated() { view.frame=CGRect(x:CGFloat(i)*(col+12),y:0,width:col,height:150) }
            let xs=[CGFloat(0),col+12,col+12,2*(col+12)]
            let ys=[CGFloat(154),154,202,154]
            for (i,view) in shortcuts.enumerated() { view.frame=CGRect(x:xs[i],y:ys[i],width:col,height:48) }
            for (i,view) in selectors.enumerated() { view.frame=CGRect(x:col+12+CGFloat(i)*col/2,y:252,width:col/2-4,height:88) }
            settings.frame=CGRect(x:0,y:352,width:w,height:max(80,settings.fittingSize.height))
        } else if kind == "windowSwitcher" {
            for (i,view) in selectors.enumerated() { view.frame=CGRect(x:CGFloat(i)*(w*0.34+12),y:0,width:w*0.34,height:204) }
            shortcuts.first?.frame=CGRect(x:w*0.72,y:42,width:w*0.28,height:60)
            settings.frame=CGRect(x:0,y:230,width:w,height:settings.fittingSize.height)
        } else {
            shortcuts.first?.frame=CGRect(x:0,y:0,width:w,height:46)
            settings.frame=CGRect(x:0,y:50,width:w,height:compact ? 798 : 420)
        }
        settingsWidth.constant=settings.frame.width
        settings.layoutSubtreeIfNeeded()
        updateSettingsHeight()
    }
}

@MainActor final class SwitcherSettingsFooter: NSView {
    private let caption:NSView, toggle:NSView
    private let preview:MinimalButton, status:NSTextField
    var usesArtwork=false { didSet { if oldValue != usesArtwork { needsLayout=true; invalidateIntrinsicContentSize() } } }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width:280,height:usesArtwork ? 100 : 132) }
    init(thumbnail:NSStackView,preview:MinimalButton,status:NSTextField) {
        caption=thumbnail.arrangedSubviews[0]; toggle=thumbnail.arrangedSubviews[1]
        self.preview=preview; self.status=status
        super.init(frame:CGRect(x:0,y:0,width:280,height:132))
        for view in [caption,toggle,preview,status] {
            if let parent=view.superview as? NSStackView { parent.removeArrangedSubview(view) }
            view.removeFromSuperview(); view.translatesAutoresizingMaskIntoConstraints=true; addSubview(view)
        }
    }
    required init?(coder:NSCoder) { nil }
    override func layout() {
        super.layout()
        caption.isHidden=usesArtwork
        preview.style=usesArtwork ? .quiet : .standard
        preview.font=usesArtwork ? .systemFont(ofSize:14) : SketchPalette.heading(15)
        status.maximumNumberOfLines=2
        if usesArtwork {
            status.font = .systemFont(ofSize:12)
            status.frame=CGRect(x:0,y:0,width:bounds.width,height:32)
            toggle.frame=CGRect(x:0,y:42,width:34,height:24)
            preview.frame=CGRect(x:max(72,bounds.width-118),y:34,width:118,height:42)
        } else {
            status.font=SketchPalette.heading(16)
            caption.frame=CGRect(x:0,y:0,width:150,height:28)
            toggle.frame=CGRect(x:160,y:2,width:34,height:24)
            preview.frame=CGRect(x:0,y:36,width:180,height:30)
            status.frame=CGRect(x:0,y:74,width:bounds.width,height:48)
        }
    }
}
