import AppKit
import UniformTypeIdentifiers
import MacOSXCore

@MainActor final class PhraseWheelModule {
    private let defaults: UserDefaults
    private var collection: PromptCollection
    private var presentation: PromptPresentation
    private var enabled = false
    private var settings: PromptSettingsView?
    private var panel: PhraseWheelPanel?
    private var saveWork: DispatchWorkItem?
    private var revision = 0
    private static let key = "promptLibrary.collection.v1"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        presentation = PromptPresentation(
            style: PromptPresentation.Style(rawValue: defaults.string(forKey: "promptLibrary.presentation") ?? "ring") ?? .ring,
            wheelCount: min(10,max(0,(defaults.object(forKey: "promptLibrary.ringCount") as? Int) ?? 10)),
            listCount: min(10,max(0,(defaults.object(forKey: "promptLibrary.listCount") as? Int) ?? 10)))
        if let data = defaults.data(forKey: Self.key), data.count <= PromptCollection.byteLimit,
           let value = try? JSONDecoder().decode(PromptCollection.self, from: data), (try? value.validate()) != nil {
            collection = value
        } else if let data = defaults.data(forKey: "promptLibrary.entries"), data.count <= 4_000_000,
                  let entries = try? JSONDecoder().decode([PromptEntry].self, from: data) {
            collection = .init(legacy: entries)
        } else if let old = defaults.stringArray(forKey: "phraseWheel.slots") {
            collection = .init(legacy: PromptLibrary.migrate(old))
        } else { collection = .init(legacy: PromptLibrary.presets) }
    }
    var settingsView: NSView {
        if let settings { return settings }
        let view = PromptSettingsView(collection: collection, presentation: presentation)
        view.onChange = { [weak self] value in
            guard let self else { return }; self.collection = value; self.revision += 1
            self.saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveAsync() }
            self.saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.35, execute: work)
        }
        view.onPresentationChange = { [weak self] value in
            guard let self else { return }; self.presentation = value
            self.defaults.set(value.style.rawValue, forKey: "promptLibrary.presentation")
            self.defaults.set(value.wheelCount, forKey: "promptLibrary.ringCount")
            self.defaults.set(value.listCount, forKey: "promptLibrary.listCount")
            self.dismissWheel()
        }
        view.onPreview = { [weak self] in self?.presentWheel() }
        settings = view; return view
    }
    private func saveAsync() {
        saveWork = nil
        let value = collection, expected = revision
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(value) }.value
            guard let self, self.revision == expected, let data, data.count <= PromptCollection.byteLimit else { return }
            self.defaults.set(data, forKey: Self.key)
        }
    }
    func start() { enabled = true }
    func stop() {
        enabled = false; revision += 1; saveWork?.cancel(); saveWork = nil
        if let data = try? JSONEncoder().encode(collection), data.count <= PromptCollection.byteLimit { defaults.set(data, forKey: Self.key) }
        dismissWheel()
    }
    func summon() { guard enabled else { return }; presentWheel() }
    private func presentWheel() {
        dismissWheel()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let snapshot = collection
        let panel = PhraseWheelPanel(anchor: mouse, screen: screen.visibleFrame, collection: snapshot, presentation: presentation)
        panel.onChoose = { [weak self] index in
            guard snapshot.prompts.indices.contains(index), !snapshot.prompts[index].content.isEmpty else { return }
            self?.dismissWheel(); NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot.prompts[index].content, forType: .string)
        }
        panel.onCancel = { [weak self] in self?.dismissWheel() }
        self.panel = panel; panel.present()
    }
    private func dismissWheel() { let old = panel; panel = nil; old?.dismiss() }
}

@MainActor private final class PromptSettingsView: NSView, NSSearchFieldDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onChange: ((PromptCollection) -> Void)?
    var onPreview: (() -> Void)?
    var onPresentationChange: ((PromptPresentation) -> Void)?
    private var presentation: PromptPresentation
    private var collection: PromptCollection
    private var encodedSize: Int
    private var selectedSlot = 0
    private var selected: Int?
    private var libraryMode = false
    private var rows: [Int] = []
    private var pending: PromptImport?
    private var loading = false
    private var wasCompact = false
    private let presentationHost = NSView()
    private var presentationPreview: PromptWheelView?
    private let wheelTab = MinimalButton(title: "常用", target: nil, action: nil, style: .quiet)
    private let libraryTab = MinimalButton(title: "全部", target: nil, action: nil, style: .quiet)
    private let add = MinimalButton(title: "+", target: nil, action: nil, style: .quiet)
    private let importer = MinimalButton(title: "导入 JSON", target: nil, action: nil, style: .quiet)
    private let cancelImport = MinimalButton(title: "取消", target: nil, action: nil, style: .quiet)
    private let format = MinimalButton(title: "格式", target: nil, action: nil, style: .quiet)
    private let preview = MinimalButton(title: "预览", target: nil, action: nil, style: .quiet)
    private let displayStyle = MinimalPopUpButton()
    private var styleButtons: [IllustratedSettingChoice] = []
    private let ringCount = MinimalPopUpButton(), listCount = MinimalPopUpButton()
    private let ringCountLabel = NSTextField(labelWithString: "轮盘")
    private let listCountLabel = NSTextField(labelWithString: "清单")
    private let picker = MinimalPopUpButton()
    private let placement = MinimalPopUpButton()
    private let titleField = SketchTextField()
    private let body = NSTextView(), table = NSTableView(), search = SketchSearchField()
    private let scroll = SketchScrollView(), listScroll = SketchScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var compact: Bool { bounds.width < 740 }
    override var intrinsicContentSize: NSSize { NSSize(width: 760, height: compact ? 798 : 420) }
    init(collection: PromptCollection, presentation: PromptPresentation) {
        self.presentation = presentation
        self.collection = collection; encodedSize = (try? JSONEncoder().encode(collection).count) ?? 0
        super.init(frame: NSRect(x:0,y:0,width:760,height:508))
        for (button, action) in [(wheelTab,#selector(showWheel)),(libraryTab,#selector(showLibrary)),(add,#selector(addPrompt)),(importer,#selector(importPressed)),(format,#selector(copyFormat)),(cancelImport,#selector(cancelPendingImport)),(preview,#selector(previewPressed))] { button.target = self; button.action = action; addSubview(button) }
        displayStyle.identifier = .init("prompt-presentation")
        ringCount.identifier = .init("prompt-ring-count"); listCount.identifier = .init("prompt-list-count")
        displayStyle.addItems(withTitles: ["轮盘", "清单"])
        displayStyle.selectItem(at: presentation.style == .ring ? 0 : 1)
        displayStyle.setAccessibilityLabel("提示词展示样式")
        displayStyle.isHidden = true
        for (index,title) in ["轮盘", "清单"].enumerated() {
            let button = IllustratedSettingChoice(title:title,asset:"",
                slice:CGRect(x:CGFloat(index)/3,y:0,width:1/3,height:1),target:self,action:#selector(chooseStyle(_:)))
            button.promptList=index == 1; button.tag=index; button.state=index == displayStyle.indexOfSelectedItem ? .on : .off
            styleButtons.append(button); addSubview(button)
        }
        for (control,label,count) in [(ringCount,"轮盘常用数量",presentation.wheelCount),(listCount,"清单常用数量",presentation.listCount)] {
            control.addItems(withTitles: (0...10).map(String.init)); control.selectItem(at: count)
            control.setAccessibilityLabel(label); control.toolTip = "0：仅搜索；减少数量不会删除提示词"
        }
        for control in [displayStyle,ringCount,listCount] { control.target = self; control.action = #selector(presentationChanged); addSubview(control) }
        for label in [ringCountLabel,listCountLabel] { label.font = .systemFont(ofSize:12); label.textColor = SketchPalette.muted; addSubview(label) }
        cancelImport.isHidden = true
        format.toolTip = "复制给 AI 使用的 JSON 协议"; format.setAccessibilityLabel("复制 AI 导入格式")
        add.setAccessibilityLabel("新增提示词")
        presentationHost.identifier = .init("prompt-presentation-preview"); addSubview(presentationHost)
        picker.target = self; picker.action = #selector(pickExisting); picker.setAccessibilityLabel("此位置的提示词")
        placement.target = self; placement.action = #selector(changePlacement); placement.setAccessibilityLabel("转盘位置")
        titleField.placeholderString = "标题"; titleField.delegate = self; titleField.isBezeled = false; titleField.drawsBackground = false
        titleField.font = .systemFont(ofSize:16,weight:.medium); titleField.focusRingType = .none; titleField.setAccessibilityLabel("提示词标题")
        body.isRichText = false; body.isAutomaticQuoteSubstitutionEnabled = false; body.isAutomaticDashSubstitutionEnabled = false
        body.font = .systemFont(ofSize:15); body.textColor = SketchPalette.ink; body.delegate = self; body.drawsBackground = false; body.textContainerInset = NSSize(width:10,height:10)
        body.isHorizontallyResizable = false; body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true; body.setAccessibilityLabel("提示词内容")
        scroll.documentView = body; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        search.placeholderString = "搜索标题"; search.delegate = self; search.sendsSearchStringImmediately = true; search.setAccessibilityLabel("搜索库中提示词")
        let column = NSTableColumn(identifier: .init("title")); table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 32; table.selectionHighlightStyle = .regular; table.backgroundColor = .clear
        table.setAccessibilityLabel("全部提示词")
        listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.drawsBackground = false
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        for view in [picker,placement,titleField,scroll,search,listScroll,status] { addSubview(view) }
        selectSlot(0)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        displayStyle.frame = CGRect(x:0,y:bounds.height-32,width:100,height:28)
        for (i,button) in styleButtons.enumerated() { button.frame=CGRect(x:CGFloat(i)*90,y:bounds.height-60,width:84,height:58) }
        ringCountLabel.frame = CGRect(x:192,y:bounds.height-26,width:32,height:18)
        ringCount.frame = CGRect(x:224,y:bounds.height-32,width:58,height:28)
        listCountLabel.frame = CGRect(x:290,y:bounds.height-26,width:32,height:18)
        listCount.frame = CGRect(x:322,y:bounds.height-32,width:58,height:28)
        if compact {
            ringCountLabel.frame=CGRect(x:0,y:bounds.height-96,width:32,height:18)
            ringCount.frame=CGRect(x:32,y:bounds.height-102,width:58,height:28)
            listCountLabel.frame=CGRect(x:110,y:bounds.height-96,width:32,height:18)
            listCount.frame=CGRect(x:142,y:bounds.height-102,width:58,height:28)
        }
        let top = bounds.height-(compact ? 142 : 80), left = compact ? bounds.width : 360
        wheelTab.frame = NSRect(x:0,y:top,width:54,height:28); libraryTab.frame = NSRect(x:58,y:top,width:54,height:28)
        add.frame = NSRect(x:left-32,y:top,width:28,height:28)
        let ringSize = min(compact ? 360 : 268,left)
        presentationHost.frame = NSRect(x:0,y:top-ringSize-12,width:ringSize,height:ringSize)
        layoutPreview()
        search.frame = NSRect(x:0,y:top-44,width:left,height:28)
        listScroll.frame = NSRect(x:0,y:top-ringSize-12,width:left,height:ringSize-42)
        let x:CGFloat = compact ? 0 : 384, width = max(150,bounds.width-x)
        let editTop = compact ? top-ringSize-54 : top
        picker.frame = NSRect(x:x,y:editTop,width:width,height:28); placement.frame = picker.frame
        titleField.frame = NSRect(x:x+10,y:editTop-42,width:width-20,height:28)
        scroll.frame = NSRect(x:x,y:66,width:width,height:max(100,editTop-112))
        body.frame.size.width = scroll.contentSize.width; scroll.layer?.backgroundColor = SketchPalette.paper.cgColor
        importer.frame = NSRect(x:0,y:28,width:110,height:28); format.frame = NSRect(x:116,y:28,width:48,height:28)
        cancelImport.frame = format.frame
        preview.frame = NSRect(x:bounds.width-60,y:28,width:60,height:28)
        status.frame = NSRect(x:0,y:0,width:bounds.width,height:26)
        table.tableColumns.first?.width = max(80,listScroll.contentSize.width)
        if wasCompact != compact { wasCompact = compact; invalidateIntrinsicContentSize() }
    }
    private func refresh() {
        rebuildPreview()
        presentationHost.isHidden = libraryMode; listScroll.isHidden = !libraryMode; search.isHidden = !libraryMode
        wheelTab.state = libraryMode ? .off : .on; libraryTab.state = libraryMode ? .on : .off
        picker.isHidden = libraryMode; placement.isHidden = !libraryMode
        picker.removeAllItems(); picker.addItem(withTitle:"空位")
        for p in collection.prompts { picker.addItem(withTitle:p.title.isEmpty ? "未命名" : p.title) }
        picker.selectItem(at: selected.map { $0+1 } ?? 0)
        placement.removeAllItems(); placement.addItem(withTitle:"仅搜索")
        for i in 0..<10 { placement.addItem(withTitle:"位置 \(i+1)") }
        let slot = selected.flatMap { collection.slots.firstIndex(of:collection.prompts[$0].id) }
        placement.selectItem(at:slot.map { $0+1 } ?? 0)
        filterRows(); needsLayout = true
    }
    private func rebuildPreview() {
        presentationPreview?.finish(); presentationPreview?.removeFromSuperview()
        let view = PromptWheelView(size:CGSize(width:360,height:360),collection:collection,
                                   presentation:presentation,editing:true,selectedPrompt:selected)
        view.onEditSlot = { [weak self] slot in self?.selectSlot(slot) }
        view.onEditPrompt = { [weak self] index in
            guard let self else { return }
            self.window?.makeFirstResponder(nil)
            self.selected = index
            let slot = self.collection.slots.firstIndex(of:self.collection.prompts[index].id)
            if let slot { self.selectedSlot = slot }
            self.libraryMode = slot == nil; self.loadEntry(); self.refresh()
        }
        view.onResize = { [weak self] _ in self?.layoutPreview() }
        presentationPreview = view; presentationHost.addSubview(view); layoutPreview()
    }
    private func layoutPreview() {
        guard let view = presentationPreview else { return }
        let size = view.preferredSize
        view.frame = CGRect(x:max(0,(presentationHost.bounds.width-size.width)/2),
                            y:max(0,(presentationHost.bounds.height-size.height)/2),width:size.width,height:size.height)
        view.needsLayout = true
    }
    private func loadEntry() {
        loading = true; titleField.stringValue = selected.map { collection.prompts[$0].title } ?? ""
        body.string = selected.map { collection.prompts[$0].content } ?? ""; loading = false
    }
    private func selectSlot(_ slot:Int) {
        window?.makeFirstResponder(nil); selectedSlot = slot
        selected = collection.slots[slot].flatMap { id in collection.prompts.firstIndex(where: { $0.id==id }) }
        loadEntry(); refresh()
    }
    @objc private func showWheel() { window?.makeFirstResponder(nil); libraryMode = false; selectSlot(selectedSlot); invalidateIntrinsicContentSize() }
    @objc private func showLibrary() { window?.makeFirstResponder(nil); libraryMode = true; refresh(); invalidateIntrinsicContentSize() }
    @objc private func pickExisting() {
        window?.makeFirstResponder(nil); selected = picker.indexOfSelectedItem == 0 ? nil : picker.indexOfSelectedItem-1
        var nextSlots = collection
        nextSlots.assign(selected.map { collection.prompts[$0].id }, to:selectedSlot)
        guard applySlots(nextSlots.slots) else { selectSlot(selectedSlot); return }
        loadEntry(); refresh(); onChange?(collection)
    }
    @objc private func changePlacement() {
        guard let selected else { return }; window?.makeFirstResponder(nil)
        let item = placement.indexOfSelectedItem, id = collection.prompts[selected].id
        var candidate = collection
        if item == 0 { for i in candidate.slots.indices where candidate.slots[i]==id { candidate.slots[i] = nil } }
        else { candidate.assign(id,to:item-1) }
        guard applySlots(candidate.slots) else { refresh(); return }
        if item > 0 { selectedSlot = item-1 }
        refresh(); onChange?(collection)
    }
    private func applySlots(_ slots:[String?]) -> Bool {
        let old = (try? JSONEncoder().encode(collection.slots).count) ?? 0
        let updated = (try? JSONEncoder().encode(slots).count) ?? 0
        let size = encodedSize + updated-old
        guard size<=PromptCollection.byteLimit else { status.stringValue = "提示词库超过 4 MB"; return false }
        collection.slots = slots; encodedSize = size; return true
    }
    @objc private func addPrompt() {
        guard collection.prompts.count < PromptCollection.limit else { status.stringValue = "提示词库最多 500 条"; return }
        window?.makeFirstResponder(nil)
        let p = LibraryPrompt(title:"",content:"")
        let size = encodedSize + ((try? JSONEncoder().encode(p).count) ?? 0) + (collection.prompts.isEmpty ? 0 : 1)
        guard size<=PromptCollection.byteLimit else { status.stringValue = "提示词库超过 4 MB"; return }
        collection.prompts.append(p); encodedSize = size
        selected = collection.prompts.count-1; libraryMode = true; loadEntry(); refresh(); invalidateIntrinsicContentSize()
        onChange?(collection); window?.makeFirstResponder(titleField)
    }
    func controlTextDidChange(_ notification:Notification) {
        if notification.object as? NSSearchField === search { filterRows() } else { changed() }
    }
    func textDidChange(_ notification:Notification) { changed() }
    private func changed() {
        guard !loading, (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true, !body.hasMarkedText() else { return }
        var candidate = collection
        let index = selected ?? candidate.prompts.count
        let creating = selected == nil
        if creating { guard candidate.prompts.count<PromptCollection.limit else { return }; candidate.prompts.append(.init(title:"",content:"")) }
        let old = candidate.prompts[index]
        var entry = old; entry.title = titleField.stringValue; entry.content = body.string
        do {
            try PromptCollection.check(title:entry.title,content:entry.content)
            let oldSize = creating ? 0 : try JSONEncoder().encode(old).count
            candidate.prompts[index] = entry
            if creating && !libraryMode { candidate.assign(entry.id,to:selectedSlot) }
            let slotsDelta = try JSONEncoder().encode(candidate.slots).count - JSONEncoder().encode(collection.slots).count
            let size = encodedSize + (try JSONEncoder().encode(entry).count) - oldSize + (creating && !collection.prompts.isEmpty ? 1 : 0) + slotsDelta
            guard size<=PromptCollection.byteLimit else { throw PromptCollection.Failure("提示词库超过 4 MB") }
            collection = candidate; selected = index; encodedSize = size; status.stringValue = ""
            refresh(); onChange?(collection)
        } catch { status.stringValue = error.localizedDescription }
    }
    private func filterRows() {
        let previousLoading = loading; loading = true; defer { loading = previousLoading }
        let q = String(search.stringValue.prefix(64)).trimmingCharacters(in:.whitespacesAndNewlines)
        rows = collection.prompts.indices.filter { q.isEmpty || collection.prompts[$0].title.range(of:q,options:[.caseInsensitive,.diacriticInsensitive]) != nil }
        table.reloadData()
        if let selected, let row = rows.firstIndex(of:selected) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
    }
    func numberOfRows(in tableView:NSTableView)->Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SketchTableRow() }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let label = NSTextField(labelWithString:collection.prompts[rows[row]].title.isEmpty ? "未命名" : collection.prompts[rows[row]].title)
        label.font = .systemFont(ofSize:14); label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        let row = table.selectedRow; guard !loading, rows.indices.contains(row) else { return }
        let index = rows[row]; guard selected != index else { return }
        window?.makeFirstResponder(nil); selected = index; loadEntry(); refresh()
    }
    @objc private func chooseStyle(_ sender: NSButton) {
        displayStyle.selectItem(at:sender.tag); presentationChanged()
    }
    @objc private func presentationChanged() {
        window?.makeFirstResponder(nil)
        presentation = PromptPresentation(style: displayStyle.indexOfSelectedItem == 0 ? .ring : .list,
                                          wheelCount: ringCount.indexOfSelectedItem, listCount: listCount.indexOfSelectedItem)
        for button in styleButtons { button.state = button.tag == displayStyle.indexOfSelectedItem ? .on : .off; button.needsDisplay = true }
        rebuildPreview(); needsLayout = true
        onPresentationChange?(presentation)
    }
    @objc private func previewPressed() { window?.makeFirstResponder(nil); onPreview?() }
    @objc private func copyFormat() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(PromptImport.aiInstructions,forType:.string); status.stringValue = "AI 导入格式已复制" }
    @objc private func importPressed() {
        window?.makeFirstResponder(nil)
        if let pending {
            do { let value = try collection.merging(pending); collection = value; encodedSize = try JSONEncoder().encode(value).count
                self.pending = nil; importer.title = "导入 JSON"; cancelImport.isHidden = true; format.isHidden = false; selected = nil; libraryMode = true; loadEntry(); refresh(); invalidateIntrinsicContentSize()
                onChange?(value); status.stringValue = "已导入 \(pending.prompts.count) 条"
            } catch { status.stringValue = error.localizedDescription }
            return
        }
        let menu = NSMenu()
        menu.addItem(withTitle:"选择 JSON 文件",action:#selector(importFile),keyEquivalent:"").target = self
        menu.addItem(withTitle:"粘贴 JSON",action:#selector(importClipboard),keyEquivalent:"").target = self
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:importer.bounds.height),in:importer)
    }
    @objc private func cancelPendingImport() { pending = nil; importer.title = "导入 JSON"; cancelImport.isHidden = true; format.isHidden = false; status.stringValue = "" }
    @objc private func importClipboard() {
        guard let string = NSPasteboard.general.string(forType:.string) else { status.stringValue = "剪贴板没有 JSON"; return }
        parseData(Data(string.utf8))
    }
    @objc private func importFile() {
        guard let window else { return }; let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.prompt = "选择"
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                do {
                    let data = try await Task.detached(priority:.userInitiated) {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
                        return try handle.read(upToCount:PromptCollection.byteLimit+1) ?? Data()
                    }.value
                    self?.parseData(data)
                } catch { self?.status.stringValue = "无法读取 JSON 文件" }
            }
        }
    }
    private func parseData(_ data:Data) {
        guard data.count<=PromptCollection.byteLimit else { status.stringValue = "JSON 超过 4 MB"; return }
        importer.isEnabled = false
        Task { [weak self] in
            let result = await Task.detached(priority:.userInitiated) { Result { try PromptImport.parse(data) } }.value
            guard let self else { return }; self.importer.isEnabled = true
            do {
                let document = try result.get(), value = try self.collection.merging(document)
                self.pending = document; self.importer.title = "确认导入"; self.cancelImport.isHidden = false; self.format.isHidden = true
                let updated = document.prompts.filter { item in
                    guard let id = item.id, let old = self.collection.prompts.first(where: { $0.id == id }) else { return false }
                    return old.title != item.title || old.content != item.content
                }.count
                self.status.stringValue = "\(document.prompts.count) 条 · 新增 \(value.prompts.count-self.collection.prompts.count) · 更新 \(updated) · 转盘位置 \(document.prompts.compactMap(\.slot).count) 个"
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
}
