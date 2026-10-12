// Concatenated after the production module so fixtures can observe private state
// without introducing production-only test entry points or real preferences.
@MainActor private final class PromptDragInfoFixture: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingLocation = CGPoint.zero
    var draggedImageLocation = CGPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard = NSPasteboard(name: .init("prompt-drag-fixture-\(UUID().uuidString)"))
    var draggingSource: Any?
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
    func set(_ value: NSPasteboardItem) { draggingPasteboard.clearContents(); precondition(draggingPasteboard.writeObjects([value])) }
}
@MainActor private final class PromptDragButtonFixture: PromptDraggableButton {
    var started = 0
    override func startPromptDrag(with event: NSEvent, context: PromptDragContext, payload: PromptDragContext.Payload, at point: CGPoint) {
        started += 1; _ = context.begin(source: self, payload: payload)
    }
}
@MainActor private final class PromptClickFixture: NSObject {
    var clicks = 0
    @objc func click(_ sender: NSButton) { clicks += 1 }
}

extension PromptSettingsView {
    @MainActor static func checkManagementFixture() throws {
        var collection = PromptCollection(legacy: (1...10).map { PromptEntry(title: "位置\($0)", content: "正文\($0)") })
        collection.prompts.append(.init(id: "library-only", title: "仅库中", content: "完整正文"))
        let settings = PromptSettingsView(collection: collection, presentation: .init())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 840, height: 440), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = settings; settings.layoutSubtreeIfNeeded()
        defer { settings.endInteraction(); window.close() }
        var changes = [PromptCollection](); settings.onChange = { changes.append($0) }
        let info = PromptDragInfoFixture(); defer { info.draggingPasteboard.releaseGlobally() }
        info.draggingDestinationWindow = window
        func preview() -> PromptWheelView { let view = settings.presentationPreview!; view.layoutSubtreeIfNeeded(); return view }
        func card(_ index: Int) -> PromptDraggableButton {
            let ring = preview().subviews.compactMap { $0 as? PromptRingView }.first!
            return ring.subviews.compactMap { $0 as? PromptDraggableButton }.first { $0.tag == index }!
        }
        func target(_ button: PromptDraggableButton) { info.draggingLocation = button.convert(button.dragHitPoint, to: nil) }
        func begin(_ source: NSView, _ payload: PromptDragContext.Payload) {
            info.draggingSource = source; info.set(settings.dragContext.begin(source: source, payload: payload))
        }
        let clickable = card(2)
        let clickPoint = clickable.convert(clickable.dragHitPoint, to:nil)
        func clickEvent(_ type:NSEvent.EventType)->NSEvent { NSEvent.mouseEvent(with:type,location:clickPoint,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        clickable.mouseDown(with:clickEvent(.leftMouseDown)); precondition(settings.selectedSlot == 0)
        clickable.mouseUp(with:clickEvent(.leftMouseUp)); precondition(settings.selectedSlot == 2 && changes.isEmpty)
        let first = card(0)
        begin(first, .preset(slot: 0, id: collection.slots[0]!)); target(card(1))
        precondition(preview().draggingEntered(info) == .move && card(1).dropHighlighted)
        precondition(preview().prepareForDragOperation(info) && preview().performDragOperation(info))
        precondition(settings.collection.slots[0] == collection.slots[1] && settings.collection.slots[1] == collection.slots[0])
        precondition(settings.collection.prompts == collection.prompts && changes.count == 1)
        settings.dragContext.end()
        begin(card(1), .preset(slot: 1, id: collection.slots[0]!))
        info.draggingLocation = preview().convert(CGPoint(x: preview().bounds.midX, y: preview().bounds.midY), to: nil)
        precondition(preview().draggingEntered(info).isEmpty && !preview().performDragOperation(info), "Centre is not a slot")
        target(card(2)); precondition(preview().draggingUpdated(info) == .move)
        preview().draggingExited(info); precondition(!card(2).dropHighlighted)
        settings.dragContext.end(); precondition(!preview().performDragOperation(info) && changes.count == 1, "Cancel leaves positions unchanged")
        begin(card(1), .preset(slot: 1, id: "stale-id")); target(card(2))
        precondition(!preview().prepareForDragOperation(info), "Stale source assignment is rejected")
        settings.dragContext.end()
        begin(card(1), .preset(slot: 1, id: collection.slots[0]!)); target(card(2))
        let wrong = NSPasteboardItem(); wrong.setString("wrong-token", forType: PromptDragContext.pasteboardType); info.set(wrong)
        precondition(!preview().performDragOperation(info)); settings.dragContext.end()
        let foreign = NSView(); settings.addSubview(foreign)
        begin(card(1), .preset(slot: 1, id: collection.slots[0]!)); info.draggingSource = foreign; target(card(2))
        precondition(!preview().prepareForDragOperation(info)); settings.dragContext.end(); foreign.removeFromSuperview()
        let otherWindow = NSWindow(contentRect: CGRect(x:0,y:0,width:100,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        otherWindow.isReleasedWhenClosed = false
        begin(card(1), .preset(slot:1,id:collection.slots[0]!)); info.draggingDestinationWindow = otherWindow; target(card(2))
        precondition(!preview().performDragOperation(info)); info.draggingDestinationWindow=window; settings.dragContext.end(); otherWindow.close()

        settings.showLibrary(); settings.selected = settings.collection.prompts.count-1; settings.loadEntry(); settings.refresh()
        let row = settings.rows.firstIndex(of: settings.selected!)!
        let writer = settings.tableView(settings.table, pasteboardWriterForRow: row) as! NSPasteboardItem
        info.draggingSource = settings.table; info.set(writer); settings.beginLibraryDrag()
        precondition(!settings.presentationHost.isHidden && settings.listScroll.isHidden && settings.table.window === window)
        target(card(4)); precondition(preview().draggingEntered(info) == .move && preview().performDragOperation(info))
        settings.dragContext.end()
        precondition(settings.presentationHost.isHidden && !settings.listScroll.isHidden && settings.collection.slots[4] == "library-only")
        precondition(settings.collection.prompts.contains { $0.id == collection.slots[4]! }, "Displaced prompt stays in library")
        settings.showWheel(); settings.selectSlot(4)
        let beforeDelete = settings.collection
        settings.delete.performClick(nil)
        precondition(settings.collection.prompts.count == beforeDelete.prompts.count-1 && settings.collection.slots[4] == nil && settings.undoDelete.isEnabled)
        settings.selectSlot(0); settings.titleField.stringValue = "删除后编辑保留"
        settings.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:settings.titleField))
        settings.undoDelete.performClick(nil)
        precondition(settings.collection.prompts.contains { $0.id == "library-only" } && settings.collection.prompts.contains { $0.title == "删除后编辑保留" })
        precondition(settings.collection.slots[4] == "library-only" && !settings.undoDelete.isEnabled)
        let actualSize = try JSONEncoder().encode(settings.collection).count
        precondition(settings.encodedSize == actualSize, "Delete, restore and edits maintain exact capacity")
        let roundtrip = try PromptCollection(legacy: []).merging(PromptImport.parse(settings.collection.exportJSON()))
        precondition(roundtrip == settings.collection)
        settings.selectSlot(4); settings.delete.performClick(nil)
        settings.collection.assign(settings.collection.prompts[0].id, to:4); settings.refresh()
        settings.undoDelete.performClick(nil)
        precondition(settings.collection.slots[4] != "library-only" && settings.collection.prompts.contains { $0.id == "library-only" } && settings.libraryMode, "Undo never overwrites newly occupied positions and selects the restored library row")
        settings.delete.performClick(nil)
        window.makeFirstResponder(nil)
        let undoKey=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"z",charactersIgnoringModifiers:"z",isARepeat:false,keyCode:6)!
        precondition(settings.performKeyEquivalent(with:undoKey) && settings.collection.prompts.contains { $0.id == "library-only" })
        settings.body.undoManager?.registerUndo(withTarget:settings.body) { $0.string = "不能带到另一个条目" }
        precondition(settings.body.undoManager?.canUndo == true)
        settings.selectSlot(0); precondition(settings.body.undoManager?.canUndo == false)
        settings.exporter.performClick(nil); precondition(settings.exportTask != nil)
        settings.endInteraction(); RunLoop.main.run(until:Date().addingTimeInterval(0.15))
        precondition(settings.exportTask == nil && settings.exportPanel == nil && settings.exporter.isEnabled, "Cancelled export never opens a late save sheet")

        let clicks=PromptClickFixture(), button=PromptDragButtonFixture(title:"拖动",target:clicks,action:#selector(PromptClickFixture.click(_:)))
        button.frame=CGRect(x:10,y:10,width:120,height:30); settings.addSubview(button)
        button.dragContext=settings.dragContext; button.dragPayload = .library(id:"library-only")
        func event(_ type:NSEvent.EventType, _ offset:CGFloat)->NSEvent { NSEvent.mouseEvent(with:type,location:button.convert(CGPoint(x:30+offset,y:15),to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
        button.mouseDown(with:event(.leftMouseDown,0)); precondition(clicks.clicks == 0)
        button.mouseDragged(with:event(.leftMouseDragged,3)); button.mouseUp(with:event(.leftMouseUp,3))
        precondition(clicks.clicks == 1 && button.started == 0)
        button.mouseDown(with:event(.leftMouseDown,0)); button.mouseDragged(with:event(.leftMouseDragged,6)); button.mouseDragged(with:event(.leftMouseDragged,12)); button.mouseUp(with:event(.leftMouseUp,12))
        precondition(button.started == 1 && clicks.clicks == 1, "Drag threshold starts once and does not select/copy")
        button.dragContext=nil
        button.finishPromptDrag(); precondition(settings.dragContext.acceptedPayload(from:info) == nil, "Drag completion survives the preview clearing its source context")
        button.removeFromSuperview()
        let runtime = PromptWheelView(size:CGSize(width:360,height:360),collection:collection,presentation:.init())
        runtime.configureDragging(context:settings.dragContext) { _,_ in preconditionFailure("Runtime must never reorder") }
        precondition(runtime.registeredDraggedTypes.isEmpty)
        runtime.finish()
        var sparse=collection; sparse.slots[2]=nil
        let listSettings=PromptSettingsView(collection:sparse,presentation:.init(style:.list,listCount:4))
        let listWindow=NSWindow(contentRect:CGRect(x:0,y:0,width:840,height:440),styleMask:[.titled],backing:.buffered,defer:false)
        listWindow.isReleasedWhenClosed=false; listWindow.contentView=listSettings; listSettings.layoutSubtreeIfNeeded()
        let listPreview=listSettings.presentationPreview!; listPreview.layoutSubtreeIfNeeded()
        let listRow=listPreview.subviews.compactMap { $0 as? PromptDraggableButton }.first { $0.tag == 0 }!
        info.draggingSource=listRow; info.draggingDestinationWindow=listWindow
        info.set(listSettings.dragContext.begin(source:listRow,payload:.preset(slot:0,id:sparse.slots[0]!)))
        let emptyRow=listPreview.subviews.compactMap { $0 as? PromptDraggableButton }.first { $0.tag == 2 }!
        info.draggingLocation=emptyRow.convert(emptyRow.dragHitPoint,to:nil)
        precondition(listPreview.draggingEntered(info) == .move && listPreview.performDragOperation(info))
        precondition(listSettings.collection.slots[0] == nil && listSettings.collection.slots[2] == sparse.slots[0] && listSettings.collection.slots[9] == sparse.slots[9])
        listSettings.dragContext.end(); listWindow.close()
        let zero=PromptSettingsView(collection:collection,presentation:.init(wheelCount:0,listCount:0))
        zero.showLibrary(); precondition(zero.tableView(zero.table,pasteboardWriterForRow:0) == nil)
        let smallEditor=PromptWheelView(size:CGSize(width:220,height:200),collection:collection,presentation:.init(style:.list,listCount:10),editing:true,selectedSlot:0)
        let smallWindow=NSWindow(contentRect:smallEditor.bounds,styleMask:[.titled],backing:.buffered,defer:false)
        smallWindow.isReleasedWhenClosed=false; smallWindow.contentView=smallEditor
        let smallContext=PromptDragContext(); smallContext.owner=smallEditor
        var droppedSlot:Int?, editedSlot:Int?
        smallEditor.onEditSlot={ editedSlot=$0 }
        smallEditor.configureDragging(context:smallContext) { payload,slot in
            precondition(payload == .preset(slot:9,id:collection.slots[9]!)); droppedSlot=slot; return true
        }
        precondition(smallEditor.control(smallEditor.search,textView:NSTextView(),doCommandBy:#selector(NSResponder.moveUp(_:))))
        smallEditor.frame.size=smallEditor.preferredSize; smallEditor.layoutSubtreeIfNeeded()
        let smallRows=smallEditor.subviews.compactMap { $0 as? PromptDraggableButton }.filter { !$0.isHidden }
        let smallSource=smallRows.first { $0.title.hasPrefix("10 ·") }!
        precondition(smallSource.dragPayload == .preset(slot:9,id:collection.slots[9]!))
        info.draggingSource=smallSource; info.draggingDestinationWindow=smallWindow
        info.set(smallContext.begin(source:smallSource,payload:smallSource.dragPayload!))
        let smallTarget=smallRows.first { $0.title.hasPrefix("9 ·") }!
        info.draggingLocation=smallTarget.convert(smallTarget.dragHitPoint,to:nil)
        precondition(smallEditor.performDragOperation(info) && droppedSlot == 8)
        let hovering=smallRows.first { $0.title.hasPrefix("8 ·") }!
        hovering.mouseEntered(with:NSEvent.enterExitEvent(with:.mouseEntered,location:.zero,modifierFlags:[],timestamp:0,windowNumber:smallWindow.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!)
        precondition(smallEditor.control(smallEditor.search,textView:NSTextView(),doCommandBy:#selector(NSResponder.insertNewline(_:))) && editedSlot == 7)
        smallContext.end(); smallEditor.finish(); smallWindow.close()
        let imeCollection=PromptCollection(legacy:(1...3).map { PromptEntry(title:"输入\($0)",content:"正文\($0)") })
        let imeSettings=PromptSettingsView(collection:imeCollection,presentation:.init())
        let imeWindow=NSWindow(contentRect:CGRect(x:0,y:0,width:840,height:440),styleMask:[.titled],backing:.buffered,defer:false)
        imeWindow.isReleasedWhenClosed=false; imeWindow.contentView=imeSettings; imeSettings.layoutSubtreeIfNeeded()
        defer { imeSettings.endInteraction(); imeWindow.close() }
        let composingID=imeCollection.slots[2]!
        func imeCard(_ slot:Int)->PromptDraggableButton {
            let view=imeSettings.presentationPreview!; view.layoutSubtreeIfNeeded()
            return view.subviews.compactMap { $0 as? PromptRingView }.first!.subviews.compactMap { $0 as? PromptDraggableButton }.first { $0.tag == slot }!
        }
        func imeEntry()->LibraryPrompt { imeSettings.collection.prompts.first { $0.id == composingID }! }
        func selectComposingEntry(library:Bool=false) {
            if library { imeSettings.showLibrary() }
            else { imeSettings.showWheel() }
            imeSettings.selected=imeSettings.collection.prompts.firstIndex { $0.id == composingID }
            imeSettings.loadEntry(); imeSettings.refresh()
        }
        func markBody(_ text:String)->String {
            precondition(imeWindow.makeFirstResponder(imeSettings.body))
            imeSettings.body.setSelectedRange(NSRange(location:imeSettings.body.string.utf16.count,length:0))
            imeSettings.body.setMarkedText(text,selectedRange:NSRange(location:0,length:text.utf16.count),replacementRange:NSRange(location:NSNotFound,length:0))
            precondition(imeSettings.body.hasMarkedText())
            return imeSettings.body.string
        }
        func markTitle(_ text:String)->String {
            precondition(imeWindow.makeFirstResponder(imeSettings.titleField))
            let editor=imeSettings.titleField.currentEditor() as! NSTextView
            editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
            editor.setMarkedText(text,selectedRange:NSRange(location:0,length:text.utf16.count),replacementRange:NSRange(location:NSNotFound,length:0))
            precondition(editor.hasMarkedText())
            return editor.string
        }
        func beginPresetIME() {
            let source=imeCard(0)
            info.draggingSource=source; info.draggingDestinationWindow=imeWindow
            info.set(imeSettings.dragContext.begin(source:source,payload:.preset(slot:0,id:imeSettings.collection.slots[0]!)))
        }
        func dropIME(to slot:Int) {
            let target=imeCard(slot)
            info.draggingLocation=target.convert(target.dragHitPoint,to:nil)
            let receiver=imeSettings.presentationPreview!
            let payload=imeSettings.dragContext.acceptedPayload(from:info)!
            let oldSlots=imeSettings.collection.slots, beforeBody=imeSettings.body.string
            let titleEditor=imeSettings.titleField.currentEditor() as? NSTextView
            let operation=receiver.draggingEntered(info), dropped=receiver.performDragOperation(info)
            precondition(operation == .move)
            if !dropped {
                precondition(imeSettings.body.hasMarkedText() || titleEditor?.hasMarkedText() == true)
                precondition(imeSettings.body.string == beforeBody && imeSettings.collection.slots == oldSlots,"An unfinished composition rejects dragging without losing text or moving positions")
                imeSettings.body.unmarkText(); titleEditor?.unmarkText()
                imeSettings.dragContext.end()
                let source:NSView
                switch payload {
                case let .preset(position,_): source=imeCard(position)
                case .library: imeSettings.beginLibraryDrag(); source=imeSettings.table
                }
                info.draggingSource=source; info.set(imeSettings.dragContext.begin(source:source,payload:payload))
                let retryTarget=imeCard(slot); info.draggingLocation=retryTarget.convert(retryTarget.dragHitPoint,to:nil)
                let retryReceiver=imeSettings.presentationPreview!
                precondition(retryReceiver.draggingEntered(info) == .move && retryReceiver.performDragOperation(info),"Committed composition can be dragged on the next attempt")
            }
            imeSettings.dragContext.end()
        }
        selectComposingEntry()
        let markedBody=markBody("未提交正文")
        precondition(imeEntry().content != markedBody)
        beginPresetIME(); dropIME(to:1)
        precondition(imeEntry().content == markedBody,"Preset drop commits marked body text before replacing the editor")
        selectComposingEntry()
        let markedTitle=markTitle("未提交标题")
        precondition(imeEntry().title != markedTitle)
        beginPresetIME(); dropIME(to:1)
        precondition(imeEntry().title == markedTitle,"Preset drop commits marked title text before replacing the editor")
        func beginLibraryIME() {
            let row=imeSettings.rows.firstIndex(of:imeSettings.selected!)!
            let writer=imeSettings.tableView(imeSettings.table,pasteboardWriterForRow:row) as! NSPasteboardItem
            info.draggingSource=imeSettings.table; info.draggingDestinationWindow=imeWindow; info.set(writer)
            imeSettings.beginLibraryDrag()
        }
        selectComposingEntry(library:true)
        let libraryBody=markBody("库拖动正文")
        beginLibraryIME()
        precondition(imeSettings.body.string == libraryBody,"Beginning library drag retains marked body text")
        dropIME(to:0)
        precondition(imeEntry().content == libraryBody && imeSettings.collection.slots[0] == composingID)
        selectComposingEntry(library:true)
        let libraryTitle=markTitle("库拖动标题")
        beginLibraryIME()
        dropIME(to:1)
        precondition(imeEntry().title == libraryTitle && imeSettings.collection.slots[1] == composingID)
        print("PASS: native drag receiver rejects centre, cancelled/stale/foreign/cross-window payloads; source threshold/click split, slot swap, library placement, delete/undo, JSON roundtrip and title/body IME preservation through drag; isolated views and named pasteboard")
    }
}

extension Check {
    @MainActor static func checkPromptManagement() throws { try PromptSettingsView.checkManagementFixture() }
}
