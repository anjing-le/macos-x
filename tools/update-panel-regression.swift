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
        print("PASS update panel layout: full selectable recovery text, bounded scrolling, compact version state; no visible window, network, updater or preferences")
    }
}
