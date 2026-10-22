import AppKit
import ApplicationServices
import MacOSXCore

@MainActor final class SettingsHeaderFixtureModel {
    var enabled = true, needsAX = true, needsCapture = true
    var message: String? = "组合键已被其他功能使用，请修改快捷键后重试。"
    var requestedAX = 0, requestedCapture = 0
    func isEnabled(_ tool: Tool) -> Bool { enabled }
    func setEnabled(_ value: Bool, tool: Tool) { enabled = value }
    func needsAccessibility(_ tool: Tool) -> Bool { needsAX }
    func needsScreenCapture(_ tool: Tool) -> Bool { needsCapture }
    func issue(for tool: Tool) -> String? { message }
    func requestAccessibility() { requestedAX += 1 }
    func requestScreenCapture() { requestedCapture += 1 }
}

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
        func descendants(_ view:NSView)->[NSView] { view.subviews.flatMap { [$0]+descendants($0) } }
        func key(_ code:UInt16, flags:NSEvent.ModifierFlags=[])->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:0,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
        }
        // Exercise the real page host, not just individually resized boards.
        // An unrecognised dashboard must get the same width as established pages.
        final class NewDashboard: NSView {
            override var intrinsicContentSize: NSSize { NSSize(width: 840, height: 420) }
        }
        let pageHost = ToolboxContent(frame: CGRect(x: 0, y: 0, width: 960, height: 640))
        let newDashboard = NewDashboard(frame: .zero)
        let hostWindow = NSWindow(contentRect: pageHost.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false; hostWindow.contentView = pageHost
        pageHost.showDetail([newDashboard])
        for width: CGFloat in [960, 740, 360, 960] {
            hostWindow.setContentSize(CGSize(width: width, height: 640))
            pageHost.needsLayout = true; pageHost.layoutSubtreeIfNeeded()
            let pageScroll = pageHost.subviews.compactMap { $0 as? NSScrollView }.first!
            try require(abs(newDashboard.frame.width - (pageScroll.contentView.bounds.width - 48)) < 1,
                        "Every dashboard follows the real host width without a class-specific allow-list")
            let rect = newDashboard.convert(newDashboard.bounds, to: pageHost)
            try require(rect.minX >= 0 && rect.maxX <= pageHost.bounds.maxX,
                        "Narrow client windows never clip a newer dashboard horizontally")
        }
        hostWindow.contentView = nil; hostWindow.close()
        let registrySuite="cc.anjing.macos-x.registry-fixture.\(UUID().uuidString)"
        let registryDefaults=UserDefaults(suiteName:registrySuite)!
        defer { registryDefaults.removePersistentDomain(forName:registrySuite) }
        registryDefaults.set("保留的提示词",forKey:"fixture.prompt-content")
        let registry=AddedTools(defaults:registryDefaults)
        registry.add(.kaomoji); registry.add(.kaomoji); registry.add(.capture)
        try require(registry.tools == [.kaomoji,.capture],"Repeated add cannot duplicate a module")
        registry.remove(.kaomoji)
        try require(AddedTools(defaults:registryDefaults).tools == [.capture],"Removal persists across reopening")
        registry.add(.kaomoji)
        try require(AddedTools(defaults:registryDefaults).tools == [.capture,.kaomoji] && registryDefaults.string(forKey:"fixture.prompt-content") == "保留的提示词","Re-adding restores entry without deleting unrelated content")
        registry.reorder([.kaomoji,.capture])
        try require(AddedTools(defaults:registryDefaults).tools == [.kaomoji,.capture],"Home order persists across reopening")
        registry.reorder([.capture,.capture])
        try require(registry.tools == [.kaomoji,.capture],"Reorder cannot duplicate or lose membership")
        let catalog=ModuleCatalogView(added:[.kaomoji,.capture])
        var catalogChanges=0
        catalog.onToggle = { tool in catalogChanges += 1 }
        catalog.onReorder = { order in registry.reorder(order); catalog.configure(added:order) }
        catalog.place(.kaomoji,at:1)
        try require(catalog.added == [.capture,.kaomoji] && registry.tools == catalog.added,"Drag placement changes the saved home order")
        catalog.move(.kaomoji,by:-1)
        try require(catalog.added == [.kaomoji,.capture],"Keyboard/button movement uses the same saved order")
        catalog.place(.windowLayout,at:0); catalog.move(.kaomoji,by:-1)
        try require(catalog.added == [.kaomoji,.capture],"Unadded and out-of-bounds moves are rejected")
        for width:CGFloat in [912,300] {
            catalog.frame.size.width=width; catalog.needsLayout=true; catalog.layoutSubtreeIfNeeded()
            let poolCards=catalog.subviews.compactMap { $0 as? ModuleCatalogCard }
            try require(poolCards.count == Tool.allCases.count,"Editor retains added and available cards")
            try require(poolCards.allSatisfy { $0.frame.minX >= 0 && $0.frame.maxX <= width },"Editor cards fit wide and narrow layouts")
        }
        let member=catalog.subviews.compactMap { $0 as? ModuleCatalogCard }.first!
        try require(member.isAccessibilityElement() && member.accessibilityChildren()?.contains(where: { ($0 as? NSButton) === member.membership }) == true,"Catalog exposes its actual membership button to accessibility")
        member.membership.performClick(nil)
        try require(catalogChanges == 1,"Editor membership button invokes only membership callback")
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
        let pageHeader = SketchWindowHeader(frame: CGRect(x: 0, y: 0, width: 960, height: 56))
        let pageToggle = ModuleEnableButton(title: "测试功能", target: nil, action: nil)
        pageHeader.accessory = pageToggle; pageHeader.back.isHidden = false
        for width: CGFloat in [960, 740, 360] {
            pageHeader.frame.size.width = width; pageHeader.title = "截图录屏"
            pageHeader.needsLayout = true; pageHeader.layoutSubtreeIfNeeded()
            let title = pageHeader.subviews.compactMap { $0 as? NSTextField }.first!
            try require(pageHeader.bounds.contains(pageToggle.frame) && !pageToggle.frame.intersects(pageHeader.update.frame), "header enable control fits without covering updates")
            try require(!title.frame.intersects(pageToggle.frame) && !title.frame.intersects(pageHeader.back.frame), "title stays clear of module switch and navigation at narrow widths")
        }
        let state = SettingsHeaderFixtureModel()
        let permissionHeader = ModuleSettingsHeader(tool: .capture, module: state)
        permissionHeader.placeEnableControl(in: pageHeader)
        for width: CGFloat in [912, 312] {
            permissionHeader.frame.size.width = width
            permissionHeader.frame.size.height = permissionHeader.intrinsicContentSize.height
            permissionHeader.needsLayout = true; permissionHeader.layoutSubtreeIfNeeded()
            let buttons = permissionHeader.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            try require(buttons.count == 2 && !permissionHeader.isHidden, "permissions remain explicit after moving enable to the title bar")
            for button in buttons {
                try require(button.frame.width >= 68 && button.frame.height >= 30 && permissionHeader.bounds.contains(button.frame), "permission controls retain visible nonzero click areas")
            }
            try require(!buttons[0].frame.intersects(buttons[1].frame), "permission actions never overlap")
            let error = permissionHeader.subviews.compactMap { $0 as? NSTextField }.first!
            try require(!error.isHidden && error.frame.minY >= 36 && permissionHeader.bounds.contains(error.frame), "actual shortcut errors stay visible below permission controls")
            buttons[0].performClick(nil); buttons[1].performClick(nil)
        }
        try require(state.requestedAX == 2 && state.requestedCapture == 2, "visible permission buttons retain their original actions")
        state.needsAX = false; state.needsCapture = false; state.message = nil; permissionHeader.refresh()
        try require(permissionHeader.isHidden && permissionHeader.intrinsicContentSize.height == 0, "ready pages reclaim the whole permissions row")
        state.needsAX = true; permissionHeader.refresh()
        try require(!permissionHeader.isHidden && permissionHeader.intrinsicContentSize.height >= 30, "later permission changes restore the visible row")
        pageHeader.accessory = nil
        try require(pageToggle.superview == nil, "leaving settings removes the old enable control")
        let output = ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"]
        let layoutModule = WindowLayoutModule()
        let layoutActions: [ShortcutAction] = [.layoutLeft, .layoutRight, .layoutUp, .layoutDown]
        try require(layoutActions.map(\.title) == ["左半屏", "右半屏", "上半屏", "下半屏"], "shortcut names match four directional halves")
        let layoutKeys: [NSView] = layoutActions.map {
            ShortcutPicker(title: "", binding: $0.defaultBinding, allowsDoubleTap: false,
                recordingChanged: { _ in }, accepts: { $0.keyCode == 122 ? "与“截图”重复，请选择其他快捷键" : nil }, didChange: { _ in })
        }
        let layoutBoard = SettingsBoardView(kind: "windowLayout", settings: layoutModule.settingsView, shortcuts: layoutKeys)
        for width: CGFloat in [840, 600] {
            layoutBoard.frame.size.width = width; layoutBoard.needsLayout = true; layoutBoard.layoutSubtreeIfNeeded()
            layoutBoard.frame.size.height = layoutBoard.intrinsicContentSize.height; layoutBoard.layoutSubtreeIfNeeded()
            let diagrams = layoutBoard.subviews.compactMap { $0 as? NSImageView }
            let keys = layoutBoard.subviews.compactMap { $0 as? ShortcutSettingsRow }
            try require(diagrams.count == 4 && diagrams.allSatisfy { $0.image != nil } && keys.count == 4,
                        "four bundled diagrams each retain a real editable keycap")
            for index in 0..<4 {
                try require(abs(keys[index].frame.midX - diagrams[index].frame.midX) < 1 && keys[index].frame.minY >= diagrams[index].frame.maxY,
                            "each shortcut stays immediately below its own diagram")
                try require(layoutBoard.bounds.contains(keys[index].frame) && layoutBoard.bounds.contains(diagrams[index].frame),
                            "four actions fit both wide and compact settings boards")
            }
            if width == 840, let output, let bitmap = layoutBoard.bitmapImageRepForCachingDisplay(in: layoutBoard.bounds) {
                layoutBoard.cacheDisplay(in: layoutBoard.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("window-layout-board.png"))
            }
        }
        let errorRecorder=descendants(layoutKeys[0]).compactMap { $0 as? NSButton }.first!
        for width:CGFloat in [912,312] {
            layoutBoard.frame.size.width=width
            errorRecorder.performClick(nil); errorRecorder.keyDown(with:key(122))
            layoutBoard.frame.size.height=layoutBoard.intrinsicContentSize.height
            layoutBoard.needsLayout=true; layoutBoard.layoutSubtreeIfNeeded()
            let error=layoutBoard.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "shortcut-board-issue" }!
            try require(!error.isHidden && error.frame.height > 15 && error.stringValue.contains("左半屏：与“截图”重复"),"real rejected keystroke has a visible full-width explanation")
            try require(layoutBoard.bounds.contains(error.frame),"shortcut conflict explanation stays inside wide and narrow boards")
            try require(descendants(layoutKeys[0]).compactMap { $0 as? NSTextField }.allSatisfy(\.isHidden),"illustrated keycap does not retain a zero-height internal error")
            if let output,let bitmap=layoutBoard.bitmapImageRepForCachingDisplay(in:layoutBoard.bounds) {
                layoutBoard.cacheDisplay(in:layoutBoard.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent(width == 912 ? "shortcut-conflict-wide.png" : "shortcut-conflict-narrow.png"))
            }
            errorRecorder.performClick(nil); errorRecorder.keyDown(with:key(120))
            try require(error.isHidden && layoutKeys[0] is ShortcutPicker,"accepted replacement clears the stale conflict explanation")
        }
        layoutModule.stop()
        let promptKey=ShortcutPicker(title:"唤起",binding:ShortcutAction.capture.defaultBinding,allowsDoubleTap:true,recordingChanged:{ _ in },accepts:{ _ in "与“截图”重复" },didChange:{ _ in })
        let promptBoard=SettingsBoardView(kind:"kaomoji",settings:NSView(),shortcuts:[promptKey])
        promptBoard.frame.size=CGSize(width:312,height:848); promptBoard.layoutSubtreeIfNeeded()
        let promptRecorder=descendants(promptKey).compactMap { $0 as? NSButton }.first { !($0 is NSPopUpButton) }!
        promptRecorder.performClick(nil); promptRecorder.keyDown(with:key(120))
        promptBoard.frame.size.height=promptBoard.intrinsicContentSize.height; promptBoard.layoutSubtreeIfNeeded()
        let promptIssue=promptBoard.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "shortcut-board-issue" }!
        try require(!promptIssue.isHidden && promptIssue.stringValue.hasPrefix("提示词：") && promptBoard.bounds.contains(promptIssue.frame),"prompt shortcut conflict uses the correct module name and a visible external explanation")
        try require(descendants(promptKey).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.allSatisfy { promptKey.bounds.contains($0.convert($0.bounds,to:promptKey)) },"prompt trigger mode and chord fit a narrow board without a duplicate title")
        for tool in Tool.allCases {
            try require(SketchCardArt.image(tool.symbol) != nil, "every module entry illustration must load from its bundled resource")
        }
        if let output {
            let board = NSView(frame: CGRect(x: 0, y: 0, width: CGFloat(Tool.allCases.count) * 216, height: 185))
            for (index, tool) in Tool.allCases.enumerated() {
                let card = ToolCard(title: tool.title, symbol: tool.symbol) {}
                card.frame = CGRect(x: CGFloat(index) * 216, y: 0, width: 192, height: 177)
                board.addSubview(card)
            }
            board.layoutSubtreeIfNeeded()
            if let bitmap = board.bitmapImageRepForCachingDisplay(in: board.bounds) {
                board.cacheDisplay(in: board.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent("entry-cards.png"))
            }
        }
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
        let shortcutDomain="cc.anjing.macos-x.layout-conflicts.\(UUID().uuidString)"
        let shortcutDefaults=UserDefaults(suiteName:shortcutDomain)!
        defer { shortcutDefaults.removePersistentDomain(forName:shortcutDomain) }
        let shortcutStore=ShortcutStore(defaults:shortcutDefaults)
        shortcutStore.set(ShortcutAction.layoutLeft.defaultBinding,for:.capture)
        let duplicate="与“左半屏”重复"
        try require(shortcutStore.conflict(ShortcutAction.layoutLeft.defaultBinding,action:.capture,activeActions:[.capture,.layoutLeft]) == duplicate,"enabled layout conflict is reported")
        try require(shortcutStore.conflict(ShortcutAction.layoutLeft.defaultBinding,action:.capture,activeActions:[.capture]) != duplicate,"unadded layout does not disable existing shortcuts")
        var opened=0, toggled=0, enabled=true
        let toolCard=ToolCard(title:"提示词库",symbol:"text.bubble") { opened += 1 }
        toolCard.configureEnabled(enabled) { [weak toolCard] value in enabled=value; toggled += 1; toolCard?.updateEnabled(value) }
        let cardWindow=CardFocusFixtureWindow(contentRect:CGRect(x:0,y:0,width:200,height:156),styleMask:.borderless,backing:.buffered,defer:false)
        cardWindow.contentView=toolCard; toolCard.frame=CGRect(x:0,y:0,width:200,height:156); toolCard.layoutSubtreeIfNeeded()
        let enableButton=toolCard.subviews.compactMap { $0 as? ModuleEnableButton }.first!
        try require(toolCard.bounds.contains(enableButton.frame) && enableButton.isHidden,"toggle stays inside card and is hidden at rest")
        let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: cardWindow.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        toolCard.mouseEntered(with: enter)
        try require(!enableButton.isHidden, "Hover reveals the real toggle")
        for unit in [CGPoint(x:0.05,y:0.05),CGPoint(x:0.5,y:0.5),CGPoint(x:0.95,y:0.95)] {
            let point=enableButton.convert(CGPoint(x:enableButton.bounds.width*unit.x,y:enableButton.bounds.height*unit.y),to:nil)
            let hitPoint=toolCard.convert(CGPoint(x:enableButton.bounds.width*unit.x,y:enableButton.bounds.height*unit.y),from:enableButton)
            try require(toolCard.hitTest(toolCard.convert(hitPoint,to:toolCard.superview)) === enableButton,"toggle consumes its entire independent target")
            let event=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:cardWindow.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            enableButton.mouseDown(with:event)
        }
        try require(toggled == 3 && opened == 0 && !enabled,"toggle flips state without navigating")
        let art=toolCard.subviews.flatMap(\.subviews).compactMap { $0 as? NSImageView }.first!
        let gray=NSBitmapImageRep(cgImage:art.image!.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
        var graySamples=0
        for y in stride(from:0,to:gray.pixelsHigh,by:4) { for x in stride(from:0,to:gray.pixelsWide,by:4) {
            if let c=gray.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),c.alphaComponent > 0.95 {
                try require(abs(c.redComponent-c.greenComponent)<0.02 && abs(c.redComponent-c.blueComponent)<0.02,"Disabled artwork must be monochrome")
                graySamples += 1
            }
        } }
        try require(graySamples>10,"Disabled artwork retains visible pixels")
        toolCard.updateEnabled(true)
        try require(enableButton.state == .on && toggled == 3,"external state sync does not dispatch again")
        try require(toolCard.accessibilityChildren()?.count == 2,"navigation and toggle both remain accessible")
        let accessibleEntry = toolCard.accessibilityChildren()?.first as? NSAccessibilityElement
        try require(accessibleEntry?.isAccessibilityEnabled() == true,"Home navigation proxy is enabled when the card is enabled")
        var removed=0
        toolCard.configureRemoval { removed += 1 }
        toolCard.layoutSubtreeIfNeeded()
        let removal=toolCard.subviews.compactMap { $0 as? CardActionButton }.first { !($0 is ModuleEnableButton) }!
        try require(!removal.isHidden && toolCard.accessibilityChildren()?.count == 3,"Hover exposes removal as a separate accessible action")
        let removalPoint=removal.convert(CGPoint(x:removal.bounds.midX,y:removal.bounds.midY),to:toolCard.superview)
        try require(toolCard.hitTest(removalPoint) === removal,"Removal cannot trigger settings navigation")
        removal.performClick(nil)
        try require(removed == 1 && opened == 0 && toggled == 3,"Removing is independent from switching and navigating")
        _ = cardWindow.makeFirstResponder(nil)
        toolCard.mouseExited(with:enter)
        try require(enableButton.isHidden && removal.isHidden,"Pointer exit hides card actions")
        try require(cardWindow.makeFirstResponder(toolCard) && !enableButton.isHidden,"Keyboard focus reveals card actions")
        try require(cardWindow.makeFirstResponder(enableButton) && !enableButton.isHidden,"Moving keyboard focus to the switch keeps it visible")
        _ = cardWindow.makeFirstResponder(nil)
        try require(enableButton.isHidden && removal.isHidden,"Leaving keyboard focus hides actions again")
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
        try require(accessibleEntry?.isAccessibilityEnabled() == false,"Disabled home card disables its navigation proxy")
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
        for backwards in [false,true] {
            let navigation=SketchDropdown(items:Array(options.prefix(3)),selected:0,width:240)
            var direction:Bool?, closes=0, commits=0
            navigation.onNavigate={ direction=$0 }; navigation.onDismiss={ closes += 1 }; navigation.onChoose={ _ in commits += 1 }
            try require(navigation.handleNavigationKey(key(48,flags:backwards ? .shift : [])),"open custom dropdown consumes Tab as navigation")
            navigation.dismiss()
            try require(direction == backwards && closes == 1 && commits == 0,"Tab closes once without committing and preserves navigation direction")
        }
        let focusWindow=CardFocusFixtureWindow(contentRect:CGRect(x:0,y:0,width:360,height:200),styleMask:.borderless,backing:.buffered,defer:false)
        let before=MinimalButton(title:"之前",target:nil,action:nil,style:.quiet), popup=MinimalPopUpButton(), after=MinimalButton(title:"之后",target:nil,action:nil,style:.quiet)
        popup.addItems(withTitles:["轮盘","清单"])
        let focusRoot=NSView(frame:CGRect(x:0,y:0,width:360,height:200)); [before,popup,after].enumerated().forEach { index,view in view.frame=CGRect(x:CGFloat(index)*110,y:30,width:100,height:32); focusRoot.addSubview(view) }
        focusWindow.contentView=focusRoot
        before.nextKeyView=popup; popup.nextKeyView=after; after.nextKeyView=before
        _ = focusWindow.makeFirstResponder(popup); popup.keyDown(with:key(48))
        try require(focusWindow.firstResponder === after,"closed popup Tab advances to the next setting")
        _ = focusWindow.makeFirstResponder(popup); popup.keyDown(with:key(48,flags:.shift))
        try require(focusWindow.firstResponder === before,"closed popup Shift-Tab returns to the previous setting")
        focusWindow.contentView=nil
        let header=SketchWindowHeader(frame:CGRect(x:0,y:0,width:360,height:56)); header.back.isHidden=false
        for title in Tool.allCases.map(\.title) {
            header.title=title; header.needsLayout=true; header.layoutSubtreeIfNeeded()
            let label=header.subviews.compactMap { $0 as? NSTextField }.first!
            let textWidth=(title as NSString).size(withAttributes:[.font:label.font!]).width
            try require(label.frame.width >= ceil(textWidth),"narrow header retains complete module title")
            try require(!label.frame.intersects(header.back.frame) && !label.frame.intersects(header.update.frame),"narrow title never overlaps navigation")
        }
        for card in catalog.subviews.compactMap({ $0 as? ModuleCatalogCard }) {
            try require(!card.artworkFrame.intersects(card.titleFrame),"catalog artwork remains separate from title")
            try require(abs(card.artworkFrame.width/card.artworkFrame.height-256.0/236.0)<0.001,"catalog artwork keeps the approved aspect ratio")
        }
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
        let audioReceiver = BoardReceiver()
        let audioButtons = ["系统声音", "麦克风"].enumerated().map { index, title in
            let button = MinimalToggle(title: title, target: audioReceiver, action: #selector(BoardReceiver.changed(_:)))
            button.tag = index; button.identifier = .init(index == 0 ? "recording-system-audio" : "recording-microphone")
            return button
        }
        let audioRow = NSStackView(views: audioButtons); audioRow.identifier = .init("capture-recording-audio")
        let captureSettings=NSStackView(views:[toggle,NSTextField(labelWithString:"说明"),recordingFooter,audioRow,captureStatus])
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
                    keys = [ShortcutAction.capture,.pin,.togglePins,.recording,.shelf].map {
                        ShortcutPicker(title:"",binding:$0.defaultBinding,allowsDoubleTap:false,recordingChanged:{ _ in },accepts:{ $0.keyCode == 120 ? "与“贴图”重复，请选择其他快捷键" : nil },didChange:{ _ in })
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
                if kind == "capture" {
                    let audioChoices = board.subviews.compactMap { $0 as? MinimalToggle }
                    try require(audioChoices.count == 2 && audioRow.isHidden, "audio settings have one visible pair of real controls")
                    for choice in audioChoices {
                        try require(board.bounds.contains(choice.frame) && choice.frame.height >= 30, "audio controls fit the recording area")
                        let before = audioReceiver.calls
                        choice.performClick(nil)
                        try require(audioReceiver.calls == before + 1 && audioButtons[choice.tag].state == choice.state,
                                    "audio option routes to the original settings action exactly once")
                        choice.performClick(nil)
                    }
                }
                let shortcutRows=board.subviews.compactMap { $0 as? ShortcutSettingsRow }
                if kind == "capture" {
                    try require(board.usesBackdrop,"capture backdrop resource loaded")
                    for (index,row) in shortcutRows.enumerated() {
                        try require(row.frame == board.slot(SettingsBoardView.captureKeySlots[index]),"native keycap follows the image slot")
                        try require(row.control.subviews.count > 0,"real shortcut recorder remains installed")
                    }
                    let shelfCard = board.subviews.compactMap { $0 as? CaptureShelfSettingsCard }.first!
                    try require(shelfCard.shortcut.control === keys[4], "Shelf illustration hosts the real shared F4 recorder")
                    try require(board.bounds.contains(shelfCard.frame) && !shelfCard.frame.intersects(settings.frame), "Shelf stays inside screenshot settings above the recording footer")
                    try require(shelfCard.bounds.contains(shelfCard.shortcut.frame), "Shelf keycap stays in its illustration")
                    try require(shelfCard.shortcut.frame.size == shortcutRows[0].frame.size, "Shelf keycap uses the exact F1 keycap dimensions instead of a stretched button")
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
                    if pass == 0 {
                        let shelfRecorder = descendants(keys[4]).compactMap { $0 as? NSButton }.first!
                        let shelfIssue = board.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "shortcut-board-issue" }!
                        shelfRecorder.performClick(nil); shelfRecorder.keyDown(with: key(120))
                        try require(!shelfIssue.isHidden && shelfIssue.stringValue.contains("晾衣杆"), "Shelf recorder reports its own named conflict")
                        shelfRecorder.performClick(nil); shelfRecorder.keyDown(with: key(96))
                        try require(shelfIssue.isHidden && shelfRecorder.title == "F5", "Shelf keycap displays a newly accepted custom shortcut")
                        shelfRecorder.performClick(nil); shelfRecorder.keyDown(with: key(118))
                        let recorder=descendants(keys[0]).compactMap { $0 as? NSButton }.first!
                        for width:CGFloat in [912,312] {
                            rootWidth.constant=width; root.frame.size.width=width
                            recorder.performClick(nil); recorder.keyDown(with:key(120))
                            root.needsLayout=true; root.layoutSubtreeIfNeeded()
                            root.frame.size.height=root.fittingSize.height; root.layoutSubtreeIfNeeded(); board.layoutSubtreeIfNeeded()
                            let error=board.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "shortcut-board-issue" }!
                            let audioChoices = board.subviews.compactMap { $0 as? MinimalToggle }
                            try require(audioChoices.allSatisfy { board.bounds.contains($0.frame) && !$0.frame.intersects(settings.frame) },
                                        "audio choices remain visible and separate from recording footer in wide and narrow layouts")
                            try require(!error.isHidden && error.frame.height > 15 && board.bounds.contains(error.frame),"capture conflict is visible outside its illustrated keycap in both layouts")
                            if let output,let bitmap=board.bitmapImageRepForCachingDisplay(in:board.bounds) {
                                board.cacheDisplay(in:board.bounds,to:bitmap)
                                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent(width == 912 ? "capture-conflict-wide.png" : "capture-conflict-narrow.png"))
                            }
                            recorder.performClick(nil); recorder.keyDown(with:key(118))
                            try require(error.isHidden,"capture accepted shortcut clears conflict")
                        }
                    }
                    for width: CGFloat in [740, 739, 312] {
                        rootWidth.constant = width; root.frame.size.width = width; root.needsLayout = true; root.layoutSubtreeIfNeeded()
                        root.frame.size.height = root.fittingSize.height; root.layoutSubtreeIfNeeded(); board.layoutSubtreeIfNeeded()
                        let card = board.subviews.compactMap { $0 as? CaptureShelfSettingsCard }.first!
                        try require(board.bounds.contains(card.frame) && card.frame.maxY <= settings.frame.minY, "Shelf never overlaps footer at responsive layout boundaries")
                        try require(card.subviews.allSatisfy { card.bounds.contains($0.frame) }, "Shelf title, help and recorder fit at every supported width")
                    }
                    rootWidth.constant=312; root.frame.size.width=312; root.needsLayout=true; root.layoutSubtreeIfNeeded()
                    root.frame.size.height=root.fittingSize.height; root.layoutSubtreeIfNeeded()
                    board.layoutSubtreeIfNeeded()
                    try require(!board.usesBackdrop,"narrow layout uses native sections")
                    let shelfCard = board.subviews.compactMap { $0 as? CaptureShelfSettingsCard }.first!
                    try require(shelfCard.frame.maxY <= settings.frame.minY && board.bounds.contains(shelfCard.frame), "Narrow layout retains the complete shelf section")
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

@MainActor private final class CardFocusFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}
