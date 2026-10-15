import AppKit
import MacOSXCore
final class CountingPromptDefaults: UserDefaults {
    var collectionWrites = 0
    override func set(_ value: Any?, forKey key: String) {
        if key == "promptLibrary.collection.v1" { collectionWrites += 1 }
        super.set(value, forKey: key)
    }
}
@main struct Check {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        try checkPromptPreviews()
        try checkPromptManagement()
        try checkPromptPolish()
        let collection = PromptCollection(legacy: (1...10).map { PromptEntry(title: "办公 \($0)", content: "正文 \($0)") })
        // Exercise every display count with real, non-presented AppKit views.
        for style in [PromptPresentation.Style.ring, .list] {
            for count in 0...10 {
                let options = PromptPresentation(style:style,wheelCount:count,listCount:count)
                let candidate = PhraseWheelPanel(anchor:CGPoint(x:450,y:450),screen:CGRect(x:0,y:0,width:900,height:900),collection:collection,presentation:options)
                let content = candidate.contentView!; content.layoutSubtreeIfNeeded()
                let field = content.subviews.compactMap { $0 as? NSSearchField }.first!
                precondition(content.bounds.contains(field.frame))
                let text = (field.cell as! NSSearchFieldCell).searchTextRect(forBounds:field.bounds)
                precondition(field.bounds.contains(text) && abs(text.midY-field.bounds.midY)<1)
                if style == .ring && count > 0 {
                    let ring = content.subviews.compactMap { $0 as? PromptRingView }.first!
                    precondition(!ring.isHidden && ring.subviews.filter { !$0.isHidden }.count == count)
                    for card in ring.subviews where !card.isHidden { precondition(ring.bounds.contains(card.frame)) }
                } else {
                    let rows = content.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title.hasPrefix("办公") }
                    precondition(rows.count == count)
                    for row in rows { precondition(content.bounds.contains(row.frame) && !row.frame.intersects(field.frame)) }
                }
                if style == .ring && count == 10 {
                    let hit=content.hitTest(CGPoint(x:content.bounds.midX,y:content.bounds.maxY-40)) as? NSButton
                    precondition(hit?.tag == 0,"top ring sector is slot one")
                    if let output=ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"],let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                        content.cacheDisplay(in:content.bounds,to:bitmap)
                        try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("ring-runtime.png"))
                    }
                }
                candidate.dismiss()
            }
        }
        let domain = "cc.anjing.macos-x.prompt-ui-check.\(UUID().uuidString)"
        let defaults = CountingPromptDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let data = try JSONEncoder().encode(collection)
        defaults.set(data,forKey:"promptLibrary.collection.v1")
        let module = PhraseWheelModule(defaults:defaults)
        let savedWrites = defaults.collectionWrites
        module.stop(); module.stop()
        precondition(defaults.collectionWrites == savedWrites, "Stopping an unchanged library does not re-encode and rewrite it")
        let controls = module.settingsView.subviews.compactMap { $0 as? NSPopUpButton }
        func control(_ id:String) -> NSPopUpButton { controls.first { $0.identifier?.rawValue == id }! }
        let styleControl = control("prompt-presentation")
        let ringControl = control("prompt-ring-count"), listControl = control("prompt-list-count")
        func visibleButtons(_ view:NSView) -> [(String,CGRect)] {
            view.subviews.filter { !$0.isHidden }.flatMap { child -> [(String,CGRect)] in
                if let button = child as? NSButton { return [(button.title,button.frame)] }
                return visibleButtons(child)
            }
        }
        for styleIndex in 0...1 {
            for count in 0...10 {
                styleControl.selectItem(at:styleIndex); ringControl.selectItem(at:count); listControl.selectItem(at:count)
                precondition(NSApp.sendAction(styleControl.action!,to:styleControl.target,from:styleControl))
                let settings = module.settingsView; settings.layoutSubtreeIfNeeded()
                let host = settings.subviews.first { $0.identifier?.rawValue == "prompt-presentation-preview" }!
                let preview = host.subviews.first as! PromptWheelView; preview.layoutSubtreeIfNeeded()
                let actual = PhraseWheelPanel(anchor:CGPoint(x:450,y:450),screen:CGRect(x:0,y:0,width:900,height:900),collection:collection,
                                              presentation:.init(style:styleIndex == 0 ? .ring : .list,wheelCount:count,listCount:count))
                let actualView = actual.contentView!; actualView.layoutSubtreeIfNeeded()
                precondition(preview.bounds.size == preview.frame.size, "The settings preview keeps native readable text instead of scaling its coordinate system")
                precondition(host.bounds.contains(preview.frame))
                let left = visibleButtons(preview), right = visibleButtons(actualView)
                precondition(left.count == right.count)
                for (lhs,rhs) in zip(left,right) {
                    let title=styleIndex == 1 ? lhs.0.replacingOccurrences(of:"^\\d+ · ",with:"",options:.regularExpression) : lhs.0
                    precondition(title == rhs.0 && preview.bounds.contains(lhs.1) && actualView.bounds.contains(rhs.1))
                }
                let previewSearch = preview.subviews.compactMap { $0 as? NSSearchField }.first!
                let actualSearch = actualView.subviews.compactMap { $0 as? NSSearchField }.first!
                precondition(previewSearch.font!.pointSize >= 12 && actualSearch.font!.pointSize >= 12)
                if count == 0 { precondition(abs(previewSearch.frame.midY-preview.bounds.midY)<1 && abs(actualSearch.frame.midY-actualView.bounds.midY)<1) }
                actual.dismiss()
            }
        }
        styleControl.selectItem(at:1); ringControl.selectItem(at:0); listControl.selectItem(at:6)
        precondition(NSApp.sendAction(styleControl.action!,to:styleControl.target,from:styleControl))
        let restoredModule = PhraseWheelModule(defaults:defaults)
        let restored = restoredModule.settingsView.subviews.compactMap { $0 as? NSPopUpButton }
        precondition(restored.first { $0.identifier?.rawValue == "prompt-presentation" }!.indexOfSelectedItem == 1)
        precondition(restored.first { $0.identifier?.rawValue == "prompt-ring-count" }!.indexOfSelectedItem == 0)
        precondition(restored.first { $0.identifier?.rawValue == "prompt-list-count" }!.indexOfSelectedItem == 6)
        precondition(defaults.data(forKey:"promptLibrary.collection.v1") == data)
        let promptSettings=module.settingsView
        promptSettings.frame.size=NSSize(width:840,height:440); promptSettings.layoutSubtreeIfNeeded()
        let styleButtons=promptSettings.subviews.compactMap { $0 as? IllustratedSettingChoice }
        precondition(styleButtons.count == 2)
        precondition(IllustratedSettingChoice.artwork("SettingsPromptsBoard") != nil)
        for button in styleButtons {
            let point=promptSettings.convert(CGPoint(x:button.bounds.midX,y:button.bounds.midY),from:button)
            precondition(promptSettings.hitTest(promptSettings.convert(point,to:promptSettings.superview)) === button)

            button.performClick(nil)
            precondition(defaults.string(forKey:"promptLibrary.presentation") == (button.tag == 0 ? "ring" : "list"))
            precondition(styleButtons.filter { $0.state == .on }.count == 1)
        }
        precondition(promptSettings.subviews.filter { !$0.isHidden }.allSatisfy { promptSettings.bounds.contains($0.frame) })
        if let output=ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"], let bitmap=promptSettings.bitmapImageRepForCachingDisplay(in:promptSettings.bounds) {
            promptSettings.cacheDisplay(in:promptSettings.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("prompts-board.png"))
        }
        promptSettings.frame.size=NSSize(width:300,height:798); promptSettings.layoutSubtreeIfNeeded()
        precondition(promptSettings.subviews.filter { !$0.isHidden }.allSatisfy { promptSettings.bounds.contains($0.frame) })
        for button in styleButtons {
            precondition(!button.titleGeometry.intersects(button.selectionMarkGeometry), "Compact style labels and selected marks occupy separate regions")
        }
        if let output=ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"],let bitmap=promptSettings.bitmapImageRepForCachingDisplay(in:promptSettings.bounds) {
            promptSettings.cacheDisplay(in:promptSettings.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent("prompts-compact.png"))
        }
        let board=SettingsBoardView(kind:"kaomoji",settings:promptSettings,shortcuts:[NSTextField(labelWithString:"双击 Option")])
        board.frame.size=CGSize(width:912,height:board.intrinsicContentSize.height); board.layoutSubtreeIfNeeded()
        board.frame.size.height = board.intrinsicContentSize.height; board.layoutSubtreeIfNeeded()
        precondition(board.bounds.contains(promptSettings.frame) && promptSettings.frame.height == 440, "The default page gives the prompt editor its complete readable canvas")
        precondition(board.frame.height == 440 && 56+48+board.frame.height <= 640, "Prompt shortcut shares its toolbar instead of adding a full page row")
        let embeddedShortcut = promptSettings.subviews.compactMap { $0 as? ShortcutSettingsRow }.first!
        precondition(promptSettings.bounds.contains(embeddedShortcut.frame), "Real shortcut remains clickable inside editor toolbar")
        let editorArea = promptSettings.subviews.compactMap { $0 as? NSScrollView }.first { $0.documentView is NSTextView }!
        precondition(editorArea.frame.height >= 250, "Compacted editor headings give the body more readable space")
        for width: CGFloat in [740, 312] {
            board.frame.size.width = width; board.needsLayout = true; board.layoutSubtreeIfNeeded()
            board.frame.size.height = board.intrinsicContentSize.height; board.needsLayout = true; board.layoutSubtreeIfNeeded()
            precondition(board.bounds.contains(promptSettings.frame) && promptSettings.bounds.contains(embeddedShortcut.frame), "Hosted shortcut and editor survive wide/narrow transitions")
        }
        board.frame.size.width = 912; board.needsLayout = true; board.layoutSubtreeIfNeeded()
        board.frame.size.height = board.intrinsicContentSize.height; board.needsLayout = true; board.layoutSubtreeIfNeeded()
        for styleIndex in 0...1 {
            styleControl.selectItem(at:styleIndex); ringControl.selectItem(at:10); listControl.selectItem(at:10)
            precondition(NSApp.sendAction(styleControl.action!,to:styleControl.target,from:styleControl))
            board.layoutSubtreeIfNeeded(); promptSettings.layoutSubtreeIfNeeded()
            let host=promptSettings.subviews.first { $0.identifier?.rawValue == "prompt-presentation-preview" }!
            let preview=host.subviews.first as! PromptWheelView; preview.layoutSubtreeIfNeeded()
            precondition(visibleButtons(preview).count == 10 && preview.bounds.size == preview.frame.size)
            for (_,rect) in visibleButtons(preview) { precondition(preview.bounds.contains(rect)) }
            if let output=ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"],let bitmap=promptSettings.bitmapImageRepForCachingDisplay(in:promptSettings.bounds) {
                promptSettings.cacheDisplay(in:promptSettings.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent(styleIndex == 0 ? "prompts-ring-board.png" : "prompts-list-board.png"))
            }
        }
        var drafts=PromptCollection(legacy:[])
        drafts.prompts=[LibraryPrompt(id:"draft",title:"标题草稿",content:""),LibraryPrompt(id:"untitled",title:"",content:"有正文")]
        drafts.assign("draft",to:1); drafts.assign("untitled",to:2)
        let editorList=PromptWheelView(size:CGSize(width:320,height:360),collection:drafts,presentation:.init(style:.list,wheelCount:4,listCount:4),editing:true,selectedSlot:0)
        editorList.frame.size=editorList.preferredSize; editorList.layoutSubtreeIfNeeded()
        let editableRows=editorList.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title.contains(" · ") }
        precondition(editableRows.count == 4 && editableRows[0].title.contains("空位置") && editableRows[1].title.contains("标题草稿") && editableRows[2].title.contains("未命名"))
        var editedSlots=[Int]()
        editorList.onEditSlot={ editedSlots.append($0) }
        editableRows[0].performClick(nil); editableRows[1].performClick(nil)
        precondition(editedSlots == [0,1], "Empty slots and title-only drafts are editable by direct list click")
        let editorText=NSTextView()
        precondition(editorList.control(editorList.search,textView:editorText,doCommandBy:#selector(NSResponder.moveDown(_:))))
        precondition(editorList.control(editorList.search,textView:editorText,doCommandBy:#selector(NSResponder.insertNewline(_:))))
        precondition(editedSlots == [0,1,1], "Keyboard can select an unfinished preset without copying")
        editorList.finish()
        for style in [PromptPresentation.Style.ring,.list] {
            let untitled=PromptWheelView(size:CGSize(width:360,height:360),collection:drafts,presentation:.init(style:style,wheelCount:4,listCount:4))
            untitled.frame.size=untitled.preferredSize; untitled.layoutSubtreeIfNeeded()
            precondition(visibleButtons(untitled).contains { $0.0 == "未命名" })
            var copied=[Int](); untitled.onChoose={ copied.append($0) }
            if style == .list {
                let rows=untitled.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title == "未命名" }
                precondition(rows.count == 1); rows[0].performClick(nil); precondition(copied == [1])
            }
            untitled.finish()
        }
        var searchable = collection
        for index in 11...23 { searchable.prompts.append(LibraryPrompt(id:"search-\(index)",title:"办公 \(index)",content:"正文 \(index)")) }
        let panel = PhraseWheelPanel(anchor: .zero, screen: CGRect(x:0,y:0,width:900,height:900), collection: searchable)
        let view = panel.contentView!
        let search = view.subviews.compactMap { $0 as? NSSearchField }.first!
        let textView = NSTextView()
        func change(_ text: String) {
            search.stringValue = text
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
            view.layoutSubtreeIfNeeded()
        }
        func command(_ selector: Selector) {
            precondition(search.delegate?.control?(search, textView: textView, doCommandBy: selector) == true)
        }
        func save(_ name: String) throws {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
        }
        change("")
        precondition(search.placeholderString == "" && abs(search.frame.midY-view.bounds.midY) < 1)
        try save("idle.png")
        change("办公")
        precondition(search.frame.midY > view.bounds.midY)
        func selectedTitle() -> String? {
            view.subviews.compactMap { $0 as? NSButton }.first { !$0.isHidden && $0.state == .on }?.title
        }
        precondition(selectedTitle() == "办公 1")
        for _ in 0..<3 { command(#selector(NSResponder.moveDown(_:))) }
        precondition(selectedTitle() == "办公 4")
        command(#selector(NSResponder.moveUp(_:)))
        precondition(selectedTitle() == "办公 3")
        for _ in 0..<10 { command(#selector(NSResponder.moveDown(_:))) }
        precondition(selectedTitle() == "办公 13")
        for _ in 0..<10 { command(#selector(NSResponder.moveUp(_:))) }
        precondition(selectedTitle() == "办公 3")
        try save("search.png")
        change("不存在")
        precondition(selectedTitle() == nil)
        var chosen = [Int]()
        panel.onChoose = { chosen.append($0) }
        command(#selector(NSResponder.insertNewline(_:)))
        precondition(chosen.isEmpty)
        change("")
        precondition(abs(search.frame.midY-view.bounds.midY) < 1)
        change("办公")
        command(#selector(NSResponder.moveUp(_:)))
        precondition(selectedTitle() == "办公 23")
        command(#selector(NSResponder.insertNewline(_:)))
        command(#selector(NSResponder.insertNewline(_:)))
        precondition(chosen == [22])
        panel.dismiss()
        let titleEditor = module.settingsView.subviews.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "标题" }!
        titleEditor.stringValue = "修改后保留"
        titleEditor.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: titleEditor))
        module.stop()
        let flushed = try JSONDecoder().decode(PromptCollection.self, from: defaults.data(forKey: "promptLibrary.collection.v1")!)
        precondition(flushed.prompts.contains { $0.title == "修改后保留" } && defaults.collectionWrites == savedWrites + 1, "Stop flushes a real edit before its debounce completes")
        module.stop()
        precondition(defaults.collectionWrites == savedWrites + 1, "Repeated stop after flush does not rewrite")
        print("PASS: settings/runtime shared view and stable positions for 0–10 both styles; native readable text, bounded rows/cards, isolated preference persistence and preservation; centre placement, blank placeholder, search list, cross-page arrows, empty-result Enter, clear search, wrap, one-shot choice; isolated UI, no clipboard/preferences")
    }
}
