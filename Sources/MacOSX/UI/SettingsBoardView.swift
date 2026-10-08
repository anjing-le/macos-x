import AppKit

/// Native settings controls with bounded, shared artwork. Images explain the action;
/// the button state and saved values remain native and accessible.
@MainActor final class IllustratedSettingChoice: MinimalButton {
    private static var images: [String: NSImage] = [:]
    private let asset: String
    private let slice: CGRect
    var pinGlow: Bool?
    var promptList: Bool?
    init(title: String, asset: String, slice: CGRect, target: AnyObject?, action: Selector?) {
        self.asset = asset; self.slice = slice
        super.init(frame: .zero)
        self.title=title; self.target=target; self.action=action; self.style = .quiet
        setButtonType(.radio); setAccessibilityLabel(title)
        if Self.images[asset] == nil, let url = Bundle.main.url(forResource: asset, withExtension: "png") {
            Self.images[asset] = NSImage(contentsOf: url)
        }
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 190, height: 156) }
    override func draw(_ dirtyRect: NSRect) {
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
        control.frame = bounds
    }
}

@MainActor final class SettingsBoardView: NSView {
    private let kind: String
    private let settings: NSView
    private let shortcuts: [NSView]
    private var art: [NSView] = []
    private var selectors: [IllustratedSettingChoice] = []
    private var sourceToggle: NSButton?
    private var sourceMode: NSPopUpButton?
    private var wasCompact=false
    private var compact: Bool { bounds.width < 740 }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width:840,height:kind == "kaomoji" ? (compact ? 848 : 470) : (kind == "capture" ? max(compact ? 760 : 440,(compact ? 664 : 352)+settings.fittingSize.height) : (compact ? 520 : 410))) }
    init(kind: String, settings: NSView, shortcuts: [NSView]) {
        self.kind=kind; self.settings=settings; self.shortcuts=shortcuts.map(ShortcutSettingsRow.init)
        super.init(frame: CGRect(x:0,y:0,width:840,height:410))
        addSubview(settings); for shortcut in self.shortcuts { addSubview(shortcut) }
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
                button.pinGlow=index == 1; button.tag=index; button.setAccessibilityLabel("贴图：\(title)"); selectors.append(button); addSubview(button)
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
    override func draw(_ dirtyRect: NSRect) { SketchPalette.paper.setFill(); dirtyRect.fill() }
    override func layout() {
        super.layout()
        let w=bounds.width
        if wasCompact != compact { wasCompact=compact; invalidateIntrinsicContentSize() }
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
        settings.layoutSubtreeIfNeeded()
    }
}
