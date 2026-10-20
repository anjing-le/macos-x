// Appended to production UpdatePanel.swift so this fixture can inspect its private
// native surface without ordering a window, starting Sparkle, or accessing preferences.
@main @MainActor struct UpdatePanelLayoutRegression {
    static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance=NSAppearance(named:.aqua)
        func require(_ condition:Bool,_ message:String) throws {
            if !condition { throw NSError(domain:message,code:1) }
        }
        let content=UpdatePanelContent(frame:CGRect(x:0,y:0,width:460,height:220))
        content.titleLabel.stringValue="更新失败"
        let detail=Array(repeating:"安装未完成，请检查目标文件夹是否可写，再关闭其他正在使用文件的应用并重试。",count:24).joined(separator:"\n")+"\n最后一步：重新检查更新。"
        content.setDetail(detail)
        content.primary.title="好"; content.primary.isHidden=false; content.buttons.isHidden=false
        content.frame.size.height=content.preferredHeight; content.layoutSubtreeIfNeeded()
        content.header.refreshActions()
        try require(content.detailLabel.isHidden && !content.detailScroll.isHidden,"long error uses the readable detail surface")
        try require(content.detailText.string == detail,"complete recovery instructions are retained")
        try require(content.detailText.isSelectable && !content.detailText.isEditable,"error details can be selected and copied without editing")
        try require(content.detailScroll.frame.height <= 224 && content.detailText.frame.height > content.detailScroll.frame.height,"long details scroll within a bounded dialog")
        try require(abs(content.detailScroll.frame.height-224)<1,"a long first error uses the full bounded reading area before any previous layout")
        try require(abs(content.detailText.frame.width-content.detailScroll.contentSize.width)<1,"recovery text wraps within the visible detail width")
        if let manager=content.detailText.layoutManager,let container=content.detailText.textContainer {
            manager.ensureLayout(for:container)
            try require(manager.glyphRange(for:container).length == manager.numberOfGlyphs,"the final recovery instruction has laid-out glyphs")
            try require(manager.usedRect(for:container).maxY+content.detailText.textContainerInset.height <= content.detailText.frame.height,"the last line stays within the scrollable document")
        }
        try require(content.bounds.contains(content.detailScroll.frame) && content.bounds.contains(content.buttons.frame),"error body and actions remain inside the dialog")
        if let output=ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"],let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("update-long-error.png"))
        }
        content.setDetail("0.0.61 → 0.0.62")
        content.titleLabel.stringValue="有新版本"
        content.frame.size.height=content.preferredHeight; content.layoutSubtreeIfNeeded()
        try require(!content.detailLabel.isHidden && content.detailScroll.isHidden && content.detailText.string.isEmpty,"short version transition keeps the compact update layout and clears old errors")
        content.setDetail(String(repeating:"版本",count:10))
        content.frame.size.height=content.preferredHeight; content.layoutSubtreeIfNeeded()
        let shortHeight=content.detailLabel.attributedStringValue.boundingRect(with:NSSize(width:content.detailLabel.frame.width,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading]).height
        try require(!content.detailLabel.isHidden && content.detailLabel.frame.height >= ceil(shortHeight),"a short wrapped detail retains its second line")
        content.setDetail(detail); content.frame.size.height=content.preferredHeight; content.layoutSubtreeIfNeeded()
        content.detailScroll.contentView.scroll(to:NSPoint(x:0,y:300))
        try require(content.detailScroll.contentView.bounds.minY > 0,"fixture reaches a later recovery paragraph")
        content.setDetail(detail)
        try require(content.detailScroll.contentView.bounds.minY == 0,"a replacement error starts at the first instruction")
        content.setDetail("")
        try require(content.detailLabel.isHidden && content.detailScroll.isHidden,"empty status does not leave an empty detail frame")
        try UpdatePanel.verifyCentering(detail:detail)
        print("PASS update panel layout: readable bounded details; client-centered check/download/install/error, live move/resize, screen fallback and observer cleanup; windows only offscreen, no network, updater or preferences")
    }
}

@MainActor private extension UpdatePanel {
    static func verifyCentering(detail:String) throws {
        func require(_ condition:Bool,_ message:String) throws {
            if !condition { throw NSError(domain:message,code:1) }
        }
        // Real AppKit frames and notifications, ordered entirely offscreen.
        // No updater, installed preferences or user-visible preview windows.
        NSApp.setActivationPolicy(.prohibited)
        let client = OffscreenUpdateFixtureWindow(contentRect: CGRect(x:-20000,y:-20000,width:960,height:640),
                              styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        client.isReleasedWhenClosed=false
        client.orderBack(nil)
        let panel=UpdatePanel(presentationWindow:{ client })
        // Disable AppKit's titlebar-on-screen clamp only in this fixture, so
        // production positioning and real notifications can run offscreen.
        let fixtureWindow=OffscreenUpdateFixtureWindow(contentRect:panel.window!.frame,
            styleMask:[.titled,.fullSizeContentView],backing:.buffered,defer:false)
        fixtureWindow.isReleasedWhenClosed=false
        fixtureWindow.contentView=panel.window!.contentView
        panel.window=fixtureWindow
        func centered(_ message:String) throws {
            // WindowServer movement notifications arrive on the next run-loop turn.
            let deadline=Date().addingTimeInterval(0.8)
            while Date() < deadline {
                let frame=panel.window!.frame
                if abs(frame.midX-client.frame.midX)<1 && abs(frame.midY-client.frame.midY)<1 { break }
                RunLoop.current.run(until:Date().addingTimeInterval(0.01))
            }
            let frame=panel.window!.frame, target=client.frame
            try require(abs(frame.midX-target.midX)<1 && abs(frame.midY-target.midY)<1,message)
        }
        panel.show(title:"检查更新",progress:.indeterminate,secondaryTitle:"取消",secondaryAction:{})
        try centered("first update state centers in the client, not on the screen")
        panel.show(title:"有新版本",detail:"0.0.91 → 0.0.92",primaryTitle:"更新",primaryAction:{})
        try centered("available update recenters after a state height change")
        panel.show(title:"正在下载",detail:"0.0.92 · 0%",progress:.fraction(0),secondaryTitle:"取消",secondaryAction:{})
        try centered("download state centers in both axes")
        panel.setProgress(.hidden,detail:detail)
        try centered("progress-only update recenters after long details resize the panel")
        client.setFrameOrigin(NSPoint(x:-19000,y:-19500))
        try centered("client movement keeps the update centered")
        client.setContentSize(NSSize(width:720,height:500))
        try centered("client resizing keeps the update centered")
        panel.show(title:"准备安装",primaryTitle:"安装并重启",primaryAction:{})
        try centered("install state remains centered after shrinking")
        panel.show(title:"更新失败",detail:detail,primaryTitle:"好",primaryAction:{})
        try centered("expanded error remains centered")
        panel.dismiss()
        let dismissedFrame=panel.window!.frame
        client.setFrameOrigin(NSPoint(x:-18000,y:-19000))
        try require(panel.window!.frame == dismissedFrame && panel.anchorWindow == nil,"dismiss releases client observations")
        client.orderOut(nil)
        panel.updateAnchor()
        panel.centerOnAnchor()
        if let screen=panel.window!.screen ?? NSScreen.main {
            try require(abs(panel.window!.frame.midY-screen.visibleFrame.midY)<1 && abs(panel.window!.frame.midX-screen.visibleFrame.midX)<1,"hidden client uses geometric screen center")
        }
        panel.dismiss(); client.close()
    }
}

@MainActor private final class OffscreenUpdateFixtureWindow: NSPanel {
    override var canBecomeKey:Bool { true }
    override func constrainFrameRect(_ frameRect:NSRect,to screen:NSScreen?) -> NSRect { frameRect }
}
