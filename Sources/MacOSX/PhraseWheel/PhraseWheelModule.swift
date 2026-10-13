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
    private var needsSave = true
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
            needsSave = false
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
            guard let self else { return }; self.collection = value; self.revision += 1; self.needsSave = true
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
        guard needsSave else { return }
        let value = collection, expected = revision
        Task { [weak self] in
            let data = await Task.detached(priority: .utility) { try? JSONEncoder().encode(value) }.value
            guard let self, self.revision == expected, let data, data.count <= PromptCollection.byteLimit else { return }
            self.defaults.set(data, forKey: Self.key)
            self.needsSave = false
        }
    }
    func start() { enabled = true }
    func stop() {
        settings?.endInteraction()
        enabled = false; revision += 1; saveWork?.cancel(); saveWork = nil
        if needsSave, let data = try? JSONEncoder().encode(collection), data.count <= PromptCollection.byteLimit {
            defaults.set(data, forKey: Self.key); needsSave = false
        }
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

@MainActor private final class PromptEditingTextView: NSTextView {
    private let history: UndoManager = { let value = UndoManager(); value.levelsOfUndo = 32; return value }()
    override var undoManager: UndoManager? { history }
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
    private var importDropdown:SketchDropdown?
    private let editorHeading=NSTextField(labelWithString:"标题与内容")
    private let editorHint=NSTextField(wrappingLabelWithString:"点左侧常用位置进行编辑；全部提示词可搜索、分配到常用位置。")
    private var loading = false
    private var wasCompact = false
    private let dragContext = PromptDragContext()
    private var draggingLibrary = false
    private var lastDeleted: PromptCollection.DeletedPrompt?
    private var interactionRevision = 0
    private var importRevision = 0
    private var importTask: Task<Void, Never>?
    private var importPanel: NSOpenPanel?
    private var exportTask: Task<Void, Never>?
    private var exportPanel: NSSavePanel?
    private var closeObserver: NSObjectProtocol?
    private let presentationHost = NSView()
    private var presentationPreview: PromptWheelView?
    private let wheelTab = MinimalButton(title: "常用", target: nil, action: nil, style: .quiet)
    private let libraryTab = MinimalButton(title: "全部", target: nil, action: nil, style: .quiet)
    private let add = MinimalButton(title: "+", target: nil, action: nil, style: .quiet)
    private let delete = MinimalButton(title: "删除", target: nil, action: nil, style: .quiet)
    private let undoDelete = MinimalButton(title: "撤销删除", target: nil, action: nil, style: .quiet)
    private let exporter = MinimalButton(title: "导出 JSON", target: nil, action: nil, style: .quiet)
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
    private let body = PromptEditingTextView(), table = NSTableView(), search = SketchSearchField()
    private let scroll = SketchScrollView(), listScroll = SketchScrollView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let artwork = IllustratedSettingChoice.artwork("SettingsPromptsBoard")
    private var compact: Bool { bounds.width < 740 }
    override var intrinsicContentSize: NSSize { NSSize(width: 760, height: compact ? 798 : 440) }
    init(collection: PromptCollection, presentation: PromptPresentation) {
        self.presentation = presentation
        self.collection = collection; encodedSize = (try? JSONEncoder().encode(collection).count) ?? 0
        super.init(frame: NSRect(x:0,y:0,width:760,height:508))
        for (button, action) in [(wheelTab,#selector(showWheel)),(libraryTab,#selector(showLibrary)),(add,#selector(addPrompt)),(delete,#selector(deletePrompt)),(undoDelete,#selector(restorePrompt)),(exporter,#selector(exportPressed)),(importer,#selector(importPressed)),(format,#selector(copyFormat)),(cancelImport,#selector(cancelPendingImport)),(preview,#selector(previewPressed))] { button.target = self; button.action = action; addSubview(button) }
        dragContext.owner = self
        dragContext.onEnd = { [weak self] in self?.finishLibraryDrag() }
        delete.setAccessibilityLabel("从提示词库删除选中内容"); delete.toolTip = "删除内容及常用位置；可撤销最近一次删除"
        undoDelete.setAccessibilityLabel("撤销最近一次删除"); exporter.setAccessibilityLabel("导出完整提示词库 JSON")
        undoDelete.toolTip = "撤销最近一次删除（非输入文字时可按 ⌘Z）"
        exporter.toolTip = "导出完整库、常用位置和草稿；JSON 上限 4 MB"
        delete.identifier = .init("prompt-delete"); undoDelete.identifier = .init("prompt-undo-delete"); exporter.identifier = .init("prompt-export")
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
        body.isRichText = false; body.allowsUndo = true; body.isAutomaticQuoteSubstitutionEnabled = false; body.isAutomaticDashSubstitutionEnabled = false
        body.font = .systemFont(ofSize:15); body.textColor = SketchPalette.ink; body.delegate = self; body.drawsBackground = false; body.textContainerInset = NSSize(width:10,height:10)
        body.isHorizontallyResizable = false; body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true; body.setAccessibilityLabel("提示词内容")
        scroll.documentView = body; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        search.placeholderString = "搜索标题"; search.delegate = self; search.sendsSearchStringImmediately = true; search.setAccessibilityLabel("搜索库中提示词")
        let column = NSTableColumn(identifier: .init("title")); table.addTableColumn(column); table.headerView = nil
        table.dataSource = self; table.delegate = self; table.rowHeight = 32; table.selectionHighlightStyle = .regular; table.backgroundColor = .clear
        table.setAccessibilityLabel("全部提示词")
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        listScroll.documentView = table; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.drawsBackground = false
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 2
        for view in [picker,placement,titleField,scroll,search,listScroll,status] { addSubview(view) }
        editorHeading.font=SketchPalette.heading(20); editorHeading.textColor=SketchPalette.ink
        editorHint.font = .systemFont(ofSize:12); editorHint.textColor=SketchPalette.muted; editorHint.maximumNumberOfLines=2
        for view in [editorHeading,editorHint] { addSubview(view) }
        selectSlot(0)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        SketchPalette.paper.setFill(); bounds.fill()
        guard let artwork else { return }
        // Keep the approved illustration choices, with space reserved for the live editor.
        for (index,button) in styleButtons.enumerated() {
            let source=CGRect(x:(index == 0 ? 0.028 : 0.175)*artwork.size.width,y:0.771*artwork.size.height,width:0.135*artwork.size.width,height:0.19*artwork.size.height)
            let pictureHeight=min(42,button.frame.height-22), pictureWidth=pictureHeight*source.width/source.height
            let picture=CGRect(x:button.frame.midX-pictureWidth/2,y:button.frame.minY+20,width:pictureWidth,height:pictureHeight)
            artwork.draw(in:picture,from:source,operation:.sourceOver,fraction:1,respectFlipped:false,hints:[.interpolation:NSImageInterpolation.high])
            let attributes:[NSAttributedString.Key:Any]=[.font:SketchPalette.heading(13),.foregroundColor:SketchPalette.ink]
            let size=(button.title as NSString).size(withAttributes:attributes)
            (button.title as NSString).draw(at:CGPoint(x:button.frame.midX-size.width/2,y:button.frame.minY+3),withAttributes:attributes)
        }
    }
    private func layoutArtwork() {
        for (index,button) in styleButtons.enumerated() {
            button.backdropOnly=true
            button.frame=CGRect(x:16+CGFloat(index)*116,y:bounds.height-66,width:110,height:64)
        }
        let editorX=bounds.width*0.49, editorWidth=bounds.width-editorX-16
        editorHeading.frame=CGRect(x:editorX,y:bounds.height-32,width:editorWidth,height:26)
        editorHint.frame=CGRect(x:editorX,y:bounds.height-64,width:editorWidth,height:20)
        let countX:CGFloat=250
        ringCountLabel.frame=CGRect(x:countX,y:bounds.height-30,width:52,height:20)
        ringCount.frame=CGRect(x:countX+54,y:bounds.height-34,width:58,height:28)
        listCountLabel.frame=CGRect(x:countX,y:bounds.height-66,width:52,height:20)
        listCount.frame=CGRect(x:countX+54,y:bounds.height-70,width:58,height:28)
        let leftWidth=editorX-32, tabY=bounds.height-96
        wheelTab.frame=CGRect(x:16,y:tabY,width:54,height:28)
        libraryTab.frame=CGRect(x:74,y:tabY,width:54,height:28)
        // Navigation stays with the preview; content actions stay with the editor.
        add.title = "+ 新建"; add.frame=CGRect(x:editorX,y:tabY,width:64,height:28)
        delete.frame=CGRect(x:editorX+74,y:tabY,width:54,height:28)
        undoDelete.frame=CGRect(x:editorX+138,y:tabY,width:80,height:28)
        presentationHost.frame=CGRect(x:16,y:62,width:leftWidth,height:tabY-70); layoutPreview()
        search.frame=CGRect(x:16,y:tabY-40,width:leftWidth,height:30)
        listScroll.frame=CGRect(x:16,y:66,width:leftWidth,height:tabY-114)
        picker.frame=CGRect(x:editorX,y:bounds.height-124,width:editorWidth,height:28); placement.frame=picker.frame
        titleField.frame=CGRect(x:editorX,y:bounds.height-168,width:editorWidth,height:32)
        scroll.frame=CGRect(x:editorX,y:66,width:editorWidth,height:bounds.height-248)
        scroll.layer?.backgroundColor=NSColor.clear.cgColor
        body.frame.size.width=scroll.contentSize.width
        importer.frame=CGRect(x:16,y:28,width:100,height:28)
        format.frame=CGRect(x:122,y:28,width:42,height:28); cancelImport.frame=format.frame
        exporter.frame=CGRect(x:170,y:28,width:86,height:28)
        preview.frame=CGRect(x:bounds.width-76,y:28,width:60,height:28)
        status.frame=CGRect(x:16,y:0,width:bounds.width-32,height:26)
        table.tableColumns.first?.width=max(80,listScroll.contentSize.width)
    }
    override func layout() {
        super.layout()
        editorHeading.isHidden=compact || artwork == nil; editorHint.isHidden=editorHeading.isHidden
        titleField.usesArtwork = false
        scroll.usesArtwork = false
        if !compact && artwork != nil {
            layoutArtwork()
            if wasCompact { wasCompact=false; invalidateIntrinsicContentSize() }
            needsDisplay=true
            return
        }
        for button in styleButtons { button.backdropOnly=artwork != nil }
        add.title = "+"
        displayStyle.frame = CGRect(x:0,y:bounds.height-32,width:100,height:28)
        for (i,button) in styleButtons.enumerated() { button.frame=CGRect(x:CGFloat(i)*116,y:bounds.height-60,width:110,height:58) }
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
        add.frame = NSRect(x:116,y:top,width:28,height:28)
        delete.frame=CGRect(x:150,y:top,width:54,height:28)
        undoDelete.frame=CGRect(x:210,y:top,width:72,height:28)
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
        importer.frame = NSRect(x:0,y:28,width:100,height:28); format.frame = NSRect(x:106,y:28,width:42,height:28)
        exporter.frame=CGRect(x:154,y:28,width:82,height:28)
        cancelImport.frame = format.frame
        preview.frame = NSRect(x:bounds.width-60,y:28,width:60,height:28)
        status.frame = NSRect(x:0,y:0,width:bounds.width,height:26)
        table.tableColumns.first?.width = max(80,listScroll.contentSize.width)
        if wasCompact != compact { wasCompact = compact; invalidateIntrinsicContentSize() }
    }
    private func refresh() {
        rebuildPreview()
        updateModeVisibility()
        delete.isEnabled = selected != nil; undoDelete.isEnabled = lastDeleted != nil
        editorHint.stringValue = "拖到常用位置；已有位置可互换。"
        wheelTab.state = libraryMode ? .off : .on; libraryTab.state = libraryMode ? .on : .off
        picker.isHidden = libraryMode; placement.isHidden = !libraryMode
        picker.removeAllItems(); picker.addItem(withTitle:"空位")
        for p in collection.prompts { picker.addItem(withTitle:p.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "未命名" : p.title) }
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
                                   presentation:presentation,editing:true,selectedPrompt:selected,selectedSlot:selectedSlot)
        view.configureDragging(context: dragContext) { [weak self] payload, slot in self?.dropPrompt(payload, to: slot) ?? false }
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
        let fitted=CGSize(width:min(size.width,presentationHost.bounds.width),height:min(size.height,presentationHost.bounds.height))
        view.frame=CGRect(x:(presentationHost.bounds.width-fitted.width)/2,y:(presentationHost.bounds.height-fitted.height)/2,width:fitted.width,height:fitted.height)
        view.bounds=CGRect(origin:.zero,size:fitted)
        view.needsLayout = true
    }
    private func loadEntry() {
        loading = true; titleField.stringValue = selected.map { collection.prompts[$0].title } ?? ""
        body.string = selected.map { collection.prompts[$0].content } ?? ""; body.undoManager?.removeAllActions(); loading = false
    }
    private func selectSlot(_ slot:Int) {
        window?.makeFirstResponder(nil); selectedSlot = slot
        selected = collection.slots[slot].flatMap { id in collection.prompts.firstIndex(where: { $0.id==id }) }
        loadEntry(); refresh()
    }
    private func updateModeVisibility() {
        presentationHost.isHidden = libraryMode && !draggingLibrary
        listScroll.isHidden = !libraryMode || draggingLibrary; search.isHidden = !libraryMode || draggingLibrary
    }
    func endInteraction() {
        interactionRevision += 1; exportTask?.cancel(); exportTask = nil; exporter.isEnabled = true
        exportPanel?.cancel(nil); exportPanel = nil
        if importTask != nil || importPanel != nil || pending != nil { cancelPendingImport() }
        dragContext.end(); importDropdown?.dismiss(); importDropdown = nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }; closeObserver = nil
        endInteraction()
        if let window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endInteraction() }
            }
        }
    }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 6, !event.isARepeat, flags == .command, lastDeleted != nil, !(window?.firstResponder is NSTextView) {
            restorePrompt(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
    private func finishLibraryDrag() {
        guard draggingLibrary else { return }; draggingLibrary = false; updateModeVisibility()
    }
    private func dropPrompt(_ payload: PromptDragContext.Payload, to slot: Int) -> Bool {
        if let window, !window.makeFirstResponder(nil) { return false }
        guard !body.hasMarkedText(), (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true else {
            status.stringValue = "先完成文字输入，再调整位置"; return false
        }
        changed()
        var candidate = collection
        let id: String
        switch payload {
        case let .preset(source, sourceID):
            guard collection.slots.indices.contains(source), collection.slots[source] == sourceID,
                  candidate.swapSlots(source, slot) else { return false }; id = sourceID
        case let .library(sourceID):
            guard candidate.place(sourceID, to: slot) else { return false }; id = sourceID
        }
        guard applySlots(candidate.slots) else { return false }
        selectedSlot = slot; selected = collection.prompts.firstIndex { $0.id == id }
        loadEntry(); refresh(); onChange?(collection)
        status.stringValue = "已放到位置 \(slot+1)"; return true
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard libraryMode, presentation.count > 0, rows.indices.contains(row) else { return nil }
        return dragContext.begin(source: table, payload: .library(id: collection.prompts[rows[row]].id))
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        beginLibraryDrag()
    }
    private func beginLibraryDrag() {
        window?.makeFirstResponder(nil); draggingLibrary = true; updateModeVisibility()
        status.stringValue = "拖到常用位置；松开完成，Esc 取消"
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragContext.end() }
    @objc private func showWheel() { window?.makeFirstResponder(nil); libraryMode = false; selectSlot(selectedSlot); invalidateIntrinsicContentSize() }
    @objc private func showLibrary() { window?.makeFirstResponder(nil); libraryMode = true; refresh(); invalidateIntrinsicContentSize() }
    @objc private func pickExisting() {
        window?.makeFirstResponder(nil); selected = picker.indexOfSelectedItem == 0 ? nil : picker.indexOfSelectedItem-1
        var nextSlots = collection
        if let selected { _ = nextSlots.place(collection.prompts[selected].id, to: selectedSlot) }
        else { nextSlots.assign(nil, to: selectedSlot) }
        guard applySlots(nextSlots.slots) else { selectSlot(selectedSlot); return }
        loadEntry(); refresh(); onChange?(collection)
    }
    @objc private func changePlacement() {
        guard let selected else { return }; window?.makeFirstResponder(nil)
        let item = placement.indexOfSelectedItem, id = collection.prompts[selected].id
        var candidate = collection
        if item == 0 { for i in candidate.slots.indices where candidate.slots[i]==id { candidate.slots[i] = nil } }
        else { _ = candidate.place(id,to:item-1) }
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
    @objc private func deletePrompt() {
        window?.makeFirstResponder(nil)
        guard let selected, collection.prompts.indices.contains(selected) else { return }
        let oldSlots = collection.slots, count = collection.prompts.count
        guard let deleted = collection.remove(id: collection.prompts[selected].id) else { return }
        encodedSize -= ((try? JSONEncoder().encode(deleted.prompt).count) ?? 0) + (count > 1 ? 1 : 0)
        encodedSize += ((try? JSONEncoder().encode(collection.slots).count) ?? 0) - ((try? JSONEncoder().encode(oldSlots).count) ?? 0)
        lastDeleted = deleted; self.selected = nil; loadEntry(); refresh(); onChange?(collection)
        status.stringValue = "已删除；可撤销最近一次删除"
    }
    @objc private func restorePrompt() {
        window?.makeFirstResponder(nil)
        guard let deleted = lastDeleted else { return }
        do {
            let oldSlots = collection.slots, count = collection.prompts.count
            try collection.restore(deleted)
            encodedSize += ((try? JSONEncoder().encode(deleted.prompt).count) ?? 0) + (count > 0 ? 1 : 0)
            encodedSize += ((try? JSONEncoder().encode(collection.slots).count) ?? 0) - ((try? JSONEncoder().encode(oldSlots).count) ?? 0)
            lastDeleted = nil; selected = collection.prompts.firstIndex { $0.id == deleted.prompt.id }
            let restoredSlot = collection.slots.firstIndex(of: deleted.prompt.id)
            if let restoredSlot { selectedSlot = restoredSlot } else { libraryMode = true }
            loadEntry(); refresh(); onChange?(collection)
            status.stringValue = restoredSlot == nil ? "已恢复到库中；常用位置保持当前内容" : "已恢复内容与原位置"
        } catch { status.stringValue = error.localizedDescription }
    }
    func controlTextDidChange(_ notification:Notification) {
        if notification.object as? NSSearchField === search { filterRows() } else { changed() }
    }
    func controlTextDidEndEditing(_ notification: Notification) { if notification.object as? NSSearchField !== search { changed() } }
    func textDidChange(_ notification:Notification) { changed() }
    func textDidEndEditing(_ notification: Notification) { changed() }
    private func changed() {
        guard !loading, (titleField.currentEditor() as? NSTextView)?.hasMarkedText() != true, !body.hasMarkedText() else { return }
        if let selected, collection.prompts[selected].title == titleField.stringValue, collection.prompts[selected].content == body.string { return }
        if selected == nil && titleField.stringValue.isEmpty && body.string.isEmpty { return }
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
            if creating { refresh() }
            else {
                presentationPreview?.updateEditingPrompt(at: index, prompt: entry)
                if old.title != entry.title {
                    picker.item(at: index + 1)?.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未命名" : entry.title
                    if libraryMode { filterRows() }
                }
            }
            onChange?(collection)
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
        let title=collection.prompts[rows[row]].title
        let label = NSTextField(labelWithString:title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? "未命名" : title)
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
    @objc private func exportPressed() {
        window?.makeFirstResponder(nil)
        guard let window else { return }; let snapshot = collection, expected = interactionRevision
        exporter.isEnabled = false
        exportTask = Task { @MainActor [weak self, weak window] in
            let result = await Task.detached(priority: .userInitiated) { Result { try snapshot.exportJSON() } }.value
            guard !Task.isCancelled, let self, self.interactionRevision == expected,
                  let window, self.window === window else { return }
            self.exportTask = nil; self.exporter.isEnabled = true
            do {
                let data = try result.get()
                let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "提示词.json"; panel.prompt = "导出"
                self.exportPanel = panel
                panel.beginSheetModal(for: window) { [weak self] response in
                    self?.exportPanel = nil
                    guard response == .OK, let url = panel.url else { return }
                    self?.exporter.isEnabled = false
                    Task { @MainActor [weak self] in
                        let written = await Task.detached(priority: .userInitiated) { Result {
                            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                            try data.write(to: url, options: .atomic)
                        } }.value
                        guard let self, self.interactionRevision == expected else { return }; self.exporter.isEnabled = true
                        switch written { case .success: self.status.stringValue = "已导出 \(snapshot.prompts.count) 条，包含常用位置和草稿"
                        case .failure: self.status.stringValue = "无法保存 JSON 文件" }
                    }
                }
            } catch { self.status.stringValue = error.localizedDescription }
        }
    }
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
        if let importDropdown { importDropdown.dismiss(); return }
        let dropdown=SketchDropdown(items:[.init(title:"选择 JSON 文件",index:0),.init(title:"粘贴 JSON",index:1)],selected:-1,width:220)
        dropdown.onChoose = { [weak self] index in if index == 0 { self?.importFile() } else { self?.importClipboard() } }
        dropdown.onDismiss = { [weak self] in self?.importDropdown=nil }
        importDropdown=dropdown; dropdown.present(relativeTo:importer)
    }
    @objc private func cancelPendingImport() {
        importRevision += 1; importTask?.cancel(); importTask = nil
        let panel = importPanel; importPanel = nil; panel?.cancel(nil)
        pending = nil; importer.isEnabled = true; importer.title = "导入 JSON"
        cancelImport.isHidden = true; format.isHidden = false; status.stringValue = ""
    }
    @objc private func importClipboard() {
        guard let string = NSPasteboard.general.string(forType:.string) else { status.stringValue = "剪贴板没有 JSON"; return }
        parseData(Data(string.utf8))
    }
    @objc private func importFile() {
        guard let window else { return }
        cancelPendingImport()
        let expected = importRevision, session = interactionRevision
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.prompt = "选择"
        importPanel = panel
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, self.importRevision == expected, self.interactionRevision == session,
                  self.importPanel === panel else { return }
            self.importPanel = nil
            guard response == .OK, let url = panel.url else { return }
            self.readImportFile(url)
        }
    }
    private func readImportFile(_ url: URL) {
        cancelPendingImport()
        let expected = importRevision, session = interactionRevision
        importer.isEnabled = false; cancelImport.isHidden = false; format.isHidden = true
        status.stringValue = "正在读取 JSON…"
        importTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                return try handle.read(upToCount: PromptCollection.byteLimit + 1) ?? Data()
            } }.value
            guard !Task.isCancelled, let self, self.importRevision == expected,
                  self.interactionRevision == session else { return }
            self.importTask = nil; self.importer.isEnabled = true
            do { self.parseData(try result.get()) }
            catch { self.cancelPendingImport(); self.status.stringValue = "无法读取 JSON 文件" }
        }
    }
    private func parseData(_ data:Data) {
        cancelPendingImport()
        guard data.count<=PromptCollection.byteLimit else { status.stringValue = "JSON 超过 4 MB"; return }
        let expected = importRevision, session = interactionRevision
        importer.isEnabled = false; cancelImport.isHidden = false; format.isHidden = true
        status.stringValue = "正在校验 JSON…"
        importTask = Task { [weak self] in
            let result = await Task.detached(priority:.userInitiated) { Result { try PromptImport.parse(data) } }.value
            guard !Task.isCancelled, let self, self.importRevision == expected,
                  self.interactionRevision == session else { return }
            self.importTask = nil; self.importer.isEnabled = true
            do {
                let document = try result.get(), value = try self.collection.merging(document)
                self.pending = document; self.importer.title = "确认导入"; self.cancelImport.isHidden = false; self.format.isHidden = true
                let updated = document.prompts.filter { item in
                    guard let id = item.id, let old = self.collection.prompts.first(where: { $0.id == id }) else { return false }
                    return old.title != item.title || old.content != item.content
                }.count
                self.status.stringValue = "\(document.prompts.count) 条 · 新增 \(value.prompts.count-self.collection.prompts.count) · 更新 \(updated) · 转盘位置 \(document.prompts.compactMap(\.slot).count) 个"
            } catch { self.cancelPendingImport(); self.status.stringValue = error.localizedDescription }
        }
    }
}
