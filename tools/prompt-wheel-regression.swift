import AppKit
import MacOSXCore
@main struct Check {
    @MainActor static func main() throws {
        _ = NSApplication.shared
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
                candidate.dismiss()
            }
        }
        let domain = "cc.anjing.macos-x.prompt-ui-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let data = try JSONEncoder().encode(collection)
        defaults.set(data,forKey:"promptLibrary.collection.v1")
        let module = PhraseWheelModule(defaults:defaults)
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
                precondition(preview.bounds == actualView.bounds, "style=\(styleIndex) count=\(count) preview=\(preview.bounds) actual=\(actualView.bounds)")
                let left = visibleButtons(preview), right = visibleButtons(actualView)
                precondition(left.count == right.count)
                for (lhs,rhs) in zip(left,right) { precondition(lhs.0 == rhs.0 && lhs.1 == rhs.1) }
                let previewSearch = preview.subviews.compactMap { $0 as? NSSearchField }.first!
                let actualSearch = actualView.subviews.compactMap { $0 as? NSSearchField }.first!
                precondition(previewSearch.frame == actualSearch.frame)
                actual.dismiss()
            }
        }
        styleControl.selectItem(at:1); ringControl.selectItem(at:0); listControl.selectItem(at:6)
        precondition(NSApp.sendAction(styleControl.action!,to:styleControl.target,from:styleControl))
        let restored = PhraseWheelModule(defaults:defaults).settingsView.subviews.compactMap { $0 as? NSPopUpButton }
        precondition(restored.first { $0.identifier?.rawValue == "prompt-presentation" }!.indexOfSelectedItem == 1)
        precondition(restored.first { $0.identifier?.rawValue == "prompt-ring-count" }!.indexOfSelectedItem == 0)
        precondition(restored.first { $0.identifier?.rawValue == "prompt-list-count" }!.indexOfSelectedItem == 6)
        precondition(defaults.data(forKey:"promptLibrary.collection.v1") == data)
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
        print("PASS: settings/runtime shared layout equality for 0–10 both styles; text centring, bounded rows/cards, isolated preference persistence and preservation; centre placement, blank placeholder, search list, cross-page arrows, empty-result Enter, clear search, wrap, one-shot choice; isolated UI, no clipboard/preferences")
    }
}
