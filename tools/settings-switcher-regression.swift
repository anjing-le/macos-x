import AppKit
import ApplicationServices
import MacOSXCore

@MainActor final class BoardReceiver: NSObject {
    var calls=0
    @objc func changed(_ sender: AnyObject) { calls += 1 }
}
@main struct SettingsSwitcherRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let layout = SwitcherLayout(windowCount: 256, available: CGSize(width: 1440, height: 900), presentation: .all)
        let canvas = SwitcherCanvas()
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: layout.size.height - 38)))
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: layout.pageSize(visibleCount: 256).height - 38))
        scroll.documentView = canvas
        let windows = (1...256).map {
            SwitcherWindow(id: UInt32($0), pid: getpid(), title: "窗口 \($0)", applicationName: "测试应用",
                icon: nil, element: AXUIElementCreateApplication(getpid()), isMinimized: false, isHidden: false, isOnScreen: true)
        }
        canvas.configure(windows, 1, layout, [:])
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        for index in [0, 8, 127, 255, 0] {
            canvas.scrollToVisible(layout.card(at: index))
            scroll.reflectScrolledClipView(scroll.contentView)
            canvas.updateChoices()
            try require(canvas.visibleWindows.contains { $0.id == UInt32(index + 1) }, "selected window must be visible after scrolling")
            try require(canvas.visibleWindows.count <= 16, "viewport thumbnail requests must stay bounded")
            try require(canvas.subviews.compactMap { $0 as? NSButton }.count <= 16, "reuse only visible choice buttons")
            let visibleButtons = canvas.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            try require(Set(visibleButtons.map(\.tag)) == Set(canvas.visibleWindows.map { Int($0.id) }), "mouse choices must follow scrolled windows")
        }
        let pageLayout = SwitcherLayout(windowCount: 11, available: CGSize(width: 1440, height: 900))
        let lastPage = pageLayout.pageSize(visibleCount: 3)
        canvas.removeFromSuperview()
        canvas.frame = CGRect(origin: .zero, size: lastPage)
        canvas.configure(Array(windows.prefix(11)), 11, pageLayout, [:])
        try require(canvas.page.map(\.id) == [9, 10, 11], "last two-row page preserves remaining windows")
        for rect in [CGRect.zero, CGRect(x:0,y:0,width:CGFloat.infinity,height:20), CGRect(x:CGFloat.nan,y:0,width:20,height:20)] {
            try require(SketchPencil.outline(in:rect,radius:8).isEmpty,"transient invalid drawing bounds are safe")
        }
        let output = ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"]
        for kind in ["capture", "windowSwitcher", "kaomoji"] {
            let guide = SettingsGuideView(kind: kind)
            guide.layoutSubtreeIfNeeded()
            try require(guide.subviews.compactMap { $0 as? NSImageView }.first?.image != nil, "all settings guide resources must load")
            if let output, let bitmap = guide.bitmapImageRepForCachingDisplay(in: guide.bounds) {
                guide.cacheDisplay(in: guide.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent(kind + ".png"))
            }
        }
        // Real mouseDown events (not performClick) cover padding, picture and caption.
        var opened=0, toggled=0, enabled=true
        let toolCard=ToolCard(title:"提示词库",symbol:"text.bubble") { opened += 1 }
        toolCard.configureEnabled(enabled) { [weak toolCard] value in enabled=value; toggled += 1; toolCard?.updateEnabled(value) }
        let cardWindow=NSWindow(contentRect:CGRect(x:0,y:0,width:200,height:156),styleMask:.borderless,backing:.buffered,defer:false)
        cardWindow.contentView=toolCard; toolCard.frame=CGRect(x:0,y:0,width:200,height:156); toolCard.layoutSubtreeIfNeeded()
        let enableButton=toolCard.subviews.compactMap { $0 as? ModuleEnableButton }.first!
        try require(toolCard.bounds.contains(enableButton.frame),"permanent toggle stays inside card")
        for unit in [CGPoint(x:0.05,y:0.05),CGPoint(x:0.5,y:0.5),CGPoint(x:0.95,y:0.95)] {
            let point=enableButton.convert(CGPoint(x:enableButton.bounds.width*unit.x,y:enableButton.bounds.height*unit.y),to:nil)
            let hitPoint=toolCard.convert(CGPoint(x:enableButton.bounds.width*unit.x,y:enableButton.bounds.height*unit.y),from:enableButton)
            try require(toolCard.hitTest(toolCard.convert(hitPoint,to:toolCard.superview)) === enableButton,"toggle consumes its entire independent target")
            let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:cardWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            enableButton.mouseDown(with:event)
        }
        try require(toggled == 3 && opened == 0 && !enabled,"toggle flips state without navigating")
        toolCard.updateEnabled(true)
        try require(enableButton.state == .on && toggled == 3,"external state sync does not dispatch again")
        try require(toolCard.accessibilityChildren()?.count == 2,"navigation and toggle both remain accessible")
        let bodyPoint=toolCard.convert(CGPoint(x:100,y:70),to:nil)
        let bodyEvent=NSEvent.mouseEvent(with:.leftMouseDown,location:bodyPoint,modifierFlags:[],timestamp:0,windowNumber:cardWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        toolCard.mouseDown(with:bodyEvent); toolCard.mouseUp(with:bodyEvent)
        try require(opened == 1 && toggled == 3,"body click opens settings without toggling")
        try require(toolCard.accessibilityPerformPress() && opened == 2,"accessible card navigation remains available")
        if let output,let bitmap=toolCard.bitmapImageRepForCachingDisplay(in:toolCard.bounds) {
            toolCard.cacheDisplay(in:toolCard.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("module-card.png"))
        }
        toolCard.isEnabled=false
        try require(!enableButton.isEnabled,"disabled control cannot toggle")
        cardWindow.contentView=nil
        let mouseReceiver=BoardReceiver()
        let mouseChoice=IllustratedSettingChoice(title:"白光边缘",asset:"",slice:.zero,target:mouseReceiver,action:#selector(BoardReceiver.changed(_:)))
        let mouseWindow=NSWindow(contentRect:CGRect(x:0,y:0,width:120,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        mouseWindow.contentView=mouseChoice; mouseChoice.frame=CGRect(x:0,y:0,width:120,height:100)
        for point in [CGPoint(x:1,y:1),CGPoint(x:119,y:99),CGPoint(x:60,y:50),CGPoint(x:60,y:88)] {
            mouseChoice.state = .off
            let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:mouseWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            mouseChoice.mouseDown(with:event)
            try require(mouseChoice.state == .on,"mouse press selects the entire card immediately")
            mouseChoice.mouseDown(with:event)
        }
        try require(mouseReceiver.calls == 4,"reclicking the selected card does not repeat work")
        try require(mouseChoice.acceptsFirstMouse(for:nil),"inactive window accepts first card click")
        mouseChoice.isEnabled=false
        let disabledEvent=NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:60,y:50),modifierFlags:[],timestamp:0,windowNumber:mouseWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
        mouseChoice.mouseDown(with:disabledEvent)
        try require(mouseReceiver.calls == 4,"disabled card does not dispatch")
        mouseWindow.contentView=nil
        let options=(0..<500).map { SketchDropdown.Item(title:"选项 \($0)",index:$0,enabled:$0 != 1) }
        let dropdown=SketchDropdown(items:options,selected:0,width:240)
        if let output, let bitmap=dropdown.surface.bitmapImageRepForCachingDisplay(in:dropdown.surface.bounds) {
            dropdown.surface.layoutSubtreeIfNeeded()
            dropdown.surface.cacheDisplay(in:dropdown.surface.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("custom-dropdown.png"))
        }
        var chosen:Int?, dismissals=0
        dropdown.onChoose={ chosen=$0 }; dropdown.onDismiss={ dismissals += 1 }
        dropdown.moveSelection(1)
        try require(dropdown.table.selectedRow == 2,"keyboard skips disabled choices")
        dropdown.search.stringValue="选项 499"
        dropdown.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:dropdown.search))
        try require(dropdown.table.numberOfRows == 1,"long dropdown is searched without changing source indices")
        dropdown.commitSelection()
        try require(chosen == 499 && dismissals == 1,"filtered Enter commits original index once")
        dropdown.dismiss(); try require(dismissals == 1,"dismissal releases once")
        let cancelled=SketchDropdown(items:options,selected:3,width:240)
        cancelled.onChoose={ _ in preconditionFailure("cancel must not commit") }
        cancelled.search.stringValue="不存在"
        cancelled.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:cancelled.search))
        cancelled.commitSelection()
        try require(cancelled.table.numberOfRows == 0,"empty dropdown result does not commit")
        cancelled.dismiss()
        let receiver=BoardReceiver()
        let toggle=MinimalToggle(title:"贴图白光边缘",target:receiver,action:#selector(BoardReceiver.changed(_:)))
        toggle.identifier = .init("capture-pin-outline")
        let recordingPath=MinimalButton(title:"Movies/截图录屏",target:nil,action:nil,style:.standard)
        let recordingChooser=MinimalButton(title:"选择文件夹",target:nil,action:nil,style:.standard)
        let recordingFolder=NSStackView(views:[NSTextField(labelWithString:"保存位置"),recordingPath,recordingChooser])
        let recordingClock=NSTextField(labelWithString:""); recordingClock.isHidden=true
        let recordingCaption=NSTextField(labelWithString:"示例录屏.mp4"); recordingCaption.font = .systemFont(ofSize:12)
        let recordingActions=NSStackView(views:["播放","Finder","复制路径"].map { text in let button=MinimalButton(title:text,target:nil,action:nil,style:.quiet); button.font = .systemFont(ofSize:12); return button })
        let recordingResults=NSStackView(views:[recordingCaption,recordingActions]); recordingResults.orientation = .vertical
        let recordingFooter=RecordingSettingsFooter(folder:recordingFolder,path:recordingPath,choose:recordingChooser,clock:recordingClock,results:recordingResults)
        let captureStatus=NSTextField(labelWithString:""); captureStatus.isHidden=true
        let captureSettings=NSStackView(views:[toggle,NSTextField(labelWithString:"说明"),recordingFooter,captureStatus])
        recordingFooter.widthAnchor.constraint(equalTo:captureSettings.widthAnchor).isActive=true
        captureSettings.arrangedSubviews[1].identifier = .init("capture-pin-help")
        captureSettings.orientation = .vertical; captureSettings.alignment = .leading
        let mode=MinimalPopUpButton(); mode.addItems(withTitles:["两行", "全部"])
        mode.target=receiver; mode.action = #selector(BoardReceiver.changed(_:))
        let modeRow=NSStackView(views:[NSTextField(labelWithString:"展示方式"),mode])
        modeRow.identifier = .init("switcher-presentation-row")
        let thumbnailRow=NSStackView(views:[NSTextField(labelWithString:"窗口缩略图"),MinimalToggle(title:"",target:nil,action:nil)])
        let switchFooter=SwitcherSettingsFooter(thumbnail:thumbnailRow,preview:MinimalButton(title:"实际预览",target:nil,action:nil,style:.standard),status:NSTextField(labelWithString:"松开 ⌘ 切换"))
        let switchSettings=NSStackView(views:[modeRow,switchFooter])
        switchFooter.widthAnchor.constraint(equalTo:switchSettings.widthAnchor).isActive=true
        switchSettings.orientation = .vertical; switchSettings.alignment = .leading
        for (kind,settings) in [("capture",captureSettings),("windowSwitcher",switchSettings)] {
            for pass in 0...1 {
                let keys: [NSView]
                if kind == "capture" {
                    keys = [ShortcutAction.capture,.pin,.togglePins,.recording].map {
                        ShortcutPicker(title:"",binding:$0.defaultBinding,allowsDoubleTap:false,recordingChanged:{ _ in },accepts:{ _ in nil },didChange:{ _ in })
                    }
                } else { let key=NSTextField(labelWithString:"⌘ Tab"); key.alignment = .center; key.font = .systemFont(ofSize:16); keys = [key] }
                let board=SettingsBoardView(kind:kind,settings:settings,shortcuts:keys)
                let root=NSStackView(views:[NSTextField(labelWithString:"启用"),board])
                root.orientation = .vertical; root.alignment = .leading; root.spacing=12
                root.translatesAutoresizingMaskIntoConstraints=false
                board.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
                let rootWidth=root.widthAnchor.constraint(equalToConstant:912); rootWidth.isActive=true
                root.frame=CGRect(x:24,y:24,width:912,height:root.fittingSize.height)
                root.layoutSubtreeIfNeeded()
                try require(abs(board.frame.width-912)<1,"board fills default client width with balanced margins")
                try require(root.fittingSize.height+48 <= 584,"common settings fit default client without outer scrolling")
                board.layoutSubtreeIfNeeded()
                let shortcutRows=board.subviews.compactMap { $0 as? ShortcutSettingsRow }
                if kind == "capture" {
                    try require(board.usesBackdrop,"capture backdrop resource loaded")
                    for (index,row) in shortcutRows.enumerated() {
                        try require(row.frame == board.slot(SettingsBoardView.captureKeySlots[index]),"native keycap follows the image slot")
                        try require(row.control.subviews.count > 0,"real shortcut recorder remains installed")
                    }
                    try require(shortcutRows[1].frame.maxY <= shortcutRows[2].frame.minY, "pin shortcuts do not overlap")
                }
                try require(shortcutRows.filter { $0.control is NSStackView }.allSatisfy { $0.control.frame == $0.bounds }, "shortcut controls use the full row without arrow gutters")
                let choices=board.subviews.compactMap { $0 as? IllustratedSettingChoice }.filter(\.isEnabled)
                try require(choices.count == 2,"exactly two live illustration choices")
                for choice in choices {
                    for unit in [CGPoint(x:0.1,y:0.1),CGPoint(x:0.5,y:0.5),CGPoint(x:0.9,y:0.9)] {
                        let point=board.convert(CGPoint(x:choice.bounds.width*unit.x,y:choice.bounds.height*unit.y),from:choice)
                        try require(board.hitTest(board.convert(point,to:board.superview)) === choice,"image and caption must hit their real choice button")
                    }
                    if kind == "capture" { try require(choice.frame == board.slot(SettingsBoardView.captureOutlineSlots[choice.tag]),"glow choice matches source-image coordinates") }
                }
                choices[1].performClick(nil)
                try require(choices[1].state == .on && choices[0].state == .off,"one selected illustration")
                try require(kind == "capture" ? toggle.state == .on : mode.indexOfSelectedItem == 1,"illustration updates source control")
                choices[0].performClick(nil)
                try require(choices[0].state == .on && choices[1].state == .off,"selection can be reversed")
                let overflowing=board.subviews.filter { !$0.isHidden && !board.bounds.contains($0.frame) }
                if !overflowing.isEmpty { print(kind,board.bounds,overflowing.map { String(describing:type(of:$0))+" "+String(describing:$0.frame) }) }
                try require(overflowing.isEmpty,"board contents stay in viewport")
                if pass == 0, let output, let bitmap=board.bitmapImageRepForCachingDisplay(in:board.bounds) {
                    board.cacheDisplay(in:board.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent(kind+"-board.png"))
                }
                if kind == "capture" {
                    rootWidth.constant=312; root.frame.size.width=312; root.needsLayout=true; root.layoutSubtreeIfNeeded()
                    root.frame.size.height=root.fittingSize.height; root.layoutSubtreeIfNeeded()
                    board.layoutSubtreeIfNeeded()
                    try require(!board.usesBackdrop,"narrow layout uses native sections")
                    try require(board.subviews.filter { !$0.isHidden }.allSatisfy { board.bounds.contains($0.frame) },"narrow capture controls stay within board")
                }
                settings.removeFromSuperview()
            }
        }
        let pathButton=MinimalButton(title:"Movies/截图录屏",target:nil,action:nil,style:.standard)
        let chooser=MinimalButton(title:"选择文件夹",target:nil,action:nil,style:.standard)
        let folder=NSStackView(views:[NSTextField(labelWithString:"保存位置"),pathButton,chooser])
        let clock=NSTextField(labelWithString:"00:12 · 录屏中"); clock.isHidden=true
        let results=NSStackView(views:[NSTextField(labelWithString:"录屏 2026-10-08.mp4"),MinimalButton(title:"播放 · Finder · 复制路径",target:nil,action:nil,style:.quiet)])
        results.orientation = .vertical
        let footer=RecordingSettingsFooter(folder:folder,path:pathButton,choose:chooser,clock:clock,results:results)
        for width:CGFloat in [912,312] {
            footer.usesArtwork = width == 912
            footer.frame.size=NSSize(width:width,height:width < 700 ? 142 : 72); footer.layoutSubtreeIfNeeded()
            try require(footer.subviews.filter { !$0.isHidden }.allSatisfy { footer.bounds.contains($0.frame) },"footer controls stay in both layouts")
        }
        try require(receiver.calls == 8,"each illustration selection sends exactly one action across reopening")
        print("PASS settings/switcher: offscreen AppKit scrolling, 256 windows, <=16 reusable buttons, final page, three bundled guides, direct illustration actions and reopening; no live windows, capture, TCC or preferences")
    }
}
