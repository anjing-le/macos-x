import AppKit

// Compiled alongside the real editor/pin source; these helpers only exist in
// this isolated executable, with no Vision execution or clipboard writes.
@MainActor private extension CaptureEditor {
    func beginPendingRecognitionFixture() {
        toolbarVisible = false
        recognition = VNRecognizeTextRequest(); recognitionButton.isEnabled = false
        showStatus("正在提取文字…")
    }
    var recognitionWasCancelled: Bool { recognition == nil && recognitionButton.isEnabled && status.isHidden && status.stringValue.isEmpty }
    func showFixtureStatus(_ value: String) { toolbarVisible = false; showStatus(value) }
    var fixtureStatus: String { status.stringValue }
    func beginTextFixture(point: CGPoint, width: CGFloat, ink: CaptureInk) -> NSTextView {
        addText(point, width, ink); return textInput!
    }
    func finishTextFixture(commit: Bool) { finishText(commit: commit) }
    var fixtureTextMark: CaptureAnnotation? { annotations.last }
    func verifyTinyTextFrameFixture() {
        let input = beginTextFixture(point: CGPoint(x: 0.5,y: 0.5),width: 3,ink: .red)
        input.insertText("字",replacementRange: NSRange(location: 0,length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification,object: input))
        let frame = textEditingFrame!
        precondition(canvas.bounds.contains(frame.frame) && !frame.frame.isEmpty && frame.outlineRect.width.isFinite,
                     "A one-pixel screenshot keeps finite clipped text-border geometry")
        finishText(commit: false)
    }
    func verifyTextPlacementFixture() {
        canvas.tool = .text
        let click = canvas.viewPoint(for: CGPoint(x: 40,y: 80))
        let event = NSEvent.mouseEvent(with: .leftMouseDown,location: canvas.convert(click,to: nil),modifierFlags: [],timestamp: 0,
            windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        canvas.mouseDown(with: event)
        let input = textInput!
        func caret() -> CGRect {
            let rect = input.firstRect(forCharacterRange: NSRange(location: 0,length: 0),actualRange: nil)
            return canvas.convert(window.convertFromScreen(rect),from: nil)
        }
        let before = caret()
        print("Text click/caret scale=\(canvas.scale) click_y=\(click.y) caret_mid_y=\(before.midY) delta=\(before.midY-click.y)")
        precondition(abs(before.midY-click.y) < 0.75,"The initial native insertion caret must be centred on the clicked location")
        for value in ["ASCII","文字 A","🙂 A","文字\n第二行",""] {
            input.insertText(value,replacementRange: NSRange(location: 0,length: input.string.utf16.count))
            textDidChange(Notification(name: NSText.didChangeNotification,object: input))
            precondition(abs(caret().midY-before.midY) < 0.75,"Font fallback, multiline input and deletion must preserve the first line's clicked centre")
        }
        finishText(commit: false)
    }
    func verifySpaceModeFixture() {
        func key(_ code: UInt16,_ value: String,repeat repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: [],timestamp: 0,
                windowNumber: window.windowNumber,context: nil,characters: value,charactersIgnoringModifiers: value,
                isARepeat: repeated,keyCode: code)!
        }
        func click() {
            let event = NSEvent.mouseEvent(with: .leftMouseDown,location: CGPoint(x: 80,y: 50),modifierFlags: [],timestamp: 0,
                windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
            canvas.mouseDown(with: event); canvas.mouseUp(with: event)
        }
        var editing = true
        onEditingChanged = { editing = $0 }
        for tool in [CaptureTool.text,.rectangle,.arrow,.pen,.mosaic] {
            canvas.tool = nil; selectTool(tool)
            let count = annotations.count
            precondition(handleSelectionKey(key(49," ")))
            precondition(annotationEditingSuspended && !toolbarVisible && canvas.tool == nil && !canvas.inputEnabled &&
                         window.ignoresMouseEvents && !editing,
                         "Space must disable annotation input and unlock real selection dragging, not only hide the toolbar")
            click()
            _ = handleSelectionKey(key(21,"4"))
            precondition(textInput == nil && annotations.count == count && canvas.tool == nil,
                         "Clicks and hidden tool keys cannot write or draw in movement mode")
            precondition(handleSelectionKey(key(49," ",repeat: true)) && annotationEditingSuspended,
                         "Holding Space cannot re-enter editing")
            activateEditing()
            precondition(!annotationEditingSuspended && toolbarVisible && canvas.tool == tool &&
                         canvas.inputEnabled && !window.ignoresMouseEvents && editing,
                         "Click activation restores the previous tool and its input routing")
        }
        canvas.tool = .pen
        func stroke(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: point,modifierFlags: [],timestamp: 0,
                windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        }
        canvas.mouseDown(with: stroke(.leftMouseDown,CGPoint(x: 20,y: 40)))
        canvas.mouseDragged(with: stroke(.leftMouseDragged,CGPoint(x: 90,y: 40)))
        _ = handleSelectionKey(key(49," "))
        canvas.mouseUp(with: stroke(.leftMouseUp,CGPoint(x: 90,y: 40)))
        precondition(annotations.count == 1 && annotations[0].tool == .pen,
                     "Exiting commits an in-flight stroke exactly once; mouseUp cannot resume drawing")
        _ = handleSelectionKey(key(49," ")); undoAction()
        precondition(annotations.isEmpty,"The committed stroke retains normal undo after resuming")
        canvas.tool = .text
        let input = beginTextFixture(point: CGPoint(x: 30,y: 100),width: 2,ink: .red)
        input.insertText("hello",replacementRange: NSRange(location: 0,length: 0))
        precondition(!handleSelectionKey(key(49," ")) && textInput === input,
                     "Native text input and IME must keep their ordinary Space key")
        finishText(commit: true)
        precondition(handleSelectionKey(key(49," ")) && textInput == nil && textEditingFrame == nil)
        click(); precondition(textInput == nil && annotations.count == 1,"Exiting after a text commit cannot leave T active")
        precondition(!window.isVisible && !toolbar.isVisible,"Regression stays isolated without displayed windows")
    }
    var fixtureClosed: Bool { closed }
    func verifyCursorOwnershipFixture() {
        let old = NSCursor.current
        defer { old.set() }
        let point = CGPoint(x: 80,y: 50)
        let event = NSEvent.mouseEvent(with: .mouseMoved,location: point,modifierFlags: [],timestamp: 0,
            windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 0,pressure: 0)!
        for _ in 0..<5 {
            canvas.tool = nil; updateSelectionInput()
            precondition(!canvas.pointerActive && !window.areCursorRectsEnabled && canvas.trackingAreas.isEmpty && !window.acceptsMouseMovedEvents,
                         "A pass-through editor must relinquish native cursor rects, hover areas and movement events")
            NSCursor.resizeLeftRight.set(); canvas.mouseMoved(with: event); canvas.cursorUpdate(with: event)
            precondition(NSCursor.current === NSCursor.resizeLeftRight,"Inactive canvas events cannot overwrite the selection edge cursor")
            for tool in [CaptureTool.rectangle,.arrow,.pen,.mosaic,.text] {
                canvas.tool = tool; updateSelectionInput(); canvas.updateTrackingAreas()
                precondition(canvas.pointerActive && window.areCursorRectsEnabled && canvas.trackingAreas.count == 2 && window.acceptsMouseMovedEvents,
                             "Only the active editing layer owns bounded pointer tracking")
                canvas.mouseMoved(with: event)
                precondition(NSCursor.current === (tool == .text ? NSCursor.iBeam : NSCursor.crosshair))
            }
        }
        let button = toolButtons[0]
        let hover = NSEvent.enterExitEvent(with: .mouseEntered,location: .zero,modifierFlags: [],timestamp: 0,
            windowNumber: toolbar.windowNumber,context: nil,eventNumber: 1,trackingNumber: 0,userData: nil)!
        NSCursor.crosshair.set(); button.mouseEntered(with: hover)
        precondition(NSCursor.current === NSCursor.arrow,"Tool buttons clear the canvas cursor on entry")
        close()
        precondition(!canvas.pointerActive && canvas.trackingAreas.isEmpty,"Close releases editor pointer tracking")
        NSCursor.arrow.set(); canvas.mouseMoved(with: event)
        precondition(NSCursor.current === NSCursor.arrow,"Closed editor events cannot revive its cursor")
        print("PASS cursor ownership: repeated selection/edit transitions, native cursor rects, bounded tracking, tool cursors, toolbar and close")
    }
    func verifyCopyExitFixture(board: NSPasteboard, action: Int) {
        let region = window.frame, base = canvas.base
        annotations = [CaptureAnnotation(tool: .rectangle, points: [CGPoint(x: 20,y: 20), CGPoint(x: 80,y: 70)], ink: .red, width: 3)]
        undo = [[]]; canvas.tool = .rectangle
        var copied = 0, closes = 0
        onCopied = { copied += 1 }
        onClose = { closes += 1; precondition(board.data(forType: .png) != nil,"Closing must follow the clipboard write") }
        let gate = DispatchSemaphore(value: 0)
        queue.async { _ = gate.wait(timeout: .now() + 3) }
        switch action {
        case 0:
            let copy = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: .command,timestamp: 0,
                windowNumber: window.windowNumber,context: nil,characters: "c",charactersIgnoringModifiers: "c",isARepeat: false,keyCode: 8)!
            precondition(handleSelectionKey(copy))
        case 1: copyCurrentImage()
        case 2: confirm()
        case 3: canvas.onCopy?()
        default: (window as! Panel).onCopy?()
        }
        precondition(!closed && copied == 0,"Export must retain the editor while encoding is pending")
        gate.signal()
        let deadline = Date().addingTimeInterval(3)
        while copied == 0 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(copied == 1 && !exporting && window.frame == region && canvas.base === base)
        let data = board.data(forType: .png)!
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData,nil)!,0,nil)!
        precondition(image.width == base.width && image.height == base.height,"Copy keeps the same frozen extent")
        if editingPin {
            precondition(!closed && closes == 0 && annotations.count == 1,"Pin copy keeps its original editing lifecycle")
            close()
        } else {
            precondition(closed && closes == 1 && localMonitor == nil && !toolbar.isVisible && !canvas.pointerActive,
                         "Screenshot copy releases the editor, tools and listeners after PNG acknowledgement")
        }
    }
    func verifyCopyWithTextFocusFixture() {
        let input = beginTextFixture(point: CGPoint(x: 20,y: 120),width: 2,ink: .red)
        input.insertText("正文 ABC",replacementRange: NSRange(location: 0,length: 0))
        input.setSelectedRange(NSRange(location: 0,length: 2))
        let event = NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: .command,timestamp: 0,
            windowNumber: window.windowNumber,context: nil,characters: "c",charactersIgnoringModifiers: "c",isARepeat: false,keyCode: 8)!
        if editingPin {
            precondition(!handleSelectionKey(event) && textInput === input,
                         "F3 text editing keeps its native selected-text copy behavior")
        } else {
            // Stop render work until the editor is closed, so this exercises
            // the real key/export entry without touching the real clipboard.
            let gate = DispatchSemaphore(value: 0)
            queue.async { _ = gate.wait(timeout: .now() + 5) }
            precondition(handleSelectionKey(event) && exporting && textInput == nil && textEditingFrame == nil,
                         "F1 Command-C exports the screenshot even with a native text selection")
            precondition(annotations.last?.text == "正文 ABC","Image copy commits the complete input, not only its selected substring")
            close(); gate.signal()
        }
    }
    func verifyMovableTextFixture() {
        canvas.tool = .text
        let input = beginTextFixture(point: CGPoint(x: 40,y: 120),width: 2,ink: .red)
        input.insertText("移动",replacementRange: NSRange(location: 0,length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification,object: input))
        input.setSelectedRange(NSRange(location: 1,length: 0))
        let selected = input.selectedRange(), original = textAnnotation!, container = input.textContainer!.size
        let handle = textEditingFrame!
        let savedCursor = NSCursor.current
        defer { savedCursor.set() }
        let edges = [CGPoint(x: 2,y: handle.bounds.midY),CGPoint(x: handle.bounds.maxX - 2,y: handle.bounds.midY),
                     CGPoint(x: handle.bounds.midX,y: 2),CGPoint(x: handle.bounds.midX,y: handle.bounds.maxY - 2),
                     CGPoint(x: 2,y: 2),CGPoint(x: handle.bounds.maxX - 2,y: 2),
                     CGPoint(x: 2,y: handle.bounds.maxY - 2),CGPoint(x: handle.bounds.maxX - 2,y: handle.bounds.maxY - 2)]
        for edge in edges {
            let point = handle.convert(edge,to: canvas)
            precondition(canvas.hitTest(point) === handle,"Every visible edge and corner must accept border dragging")
        }
        let outline = handle.outlineRect
        let expanded = [CGPoint(x: outline.minX-6,y: outline.midY),CGPoint(x: outline.minX+6,y: outline.midY),
                        CGPoint(x: outline.maxX-6,y: outline.midY),CGPoint(x: outline.maxX+6,y: outline.midY),
                        CGPoint(x: outline.midX,y: outline.minY-6),CGPoint(x: outline.midX,y: outline.minY+6),
                        CGPoint(x: outline.midX,y: outline.maxY-6),CGPoint(x: outline.midX,y: outline.maxY+6)]
        for point in expanded where handle.bounds.contains(point) {
            precondition(canvas.hitTest(handle.convert(point,to: canvas)) === handle,
                         "Both sides of the visible border accept dragging six points away from the pencil line")
        }
        let interior = handle.convert(CGPoint(x: handle.bounds.midX,y: handle.bounds.midY),to: canvas)
        precondition(handle.hitTest(interior) == nil && canvas.hitTest(interior) === input,
                     "The frame interior passes through to native typing and selection")
        let start = handle.convert(edges[0],to: nil)
        handle.updateTrackingAreas()
        precondition(handle.trackingAreas.count == 4,"Hover tracks only the four border strips")
        let hover = NSEvent.enterExitEvent(with: .mouseEntered,location: start,modifierFlags: [],timestamp: 0,
            windowNumber: window.windowNumber,context: nil,eventNumber: 1,trackingNumber: 0,userData: nil)!
        NSCursor.arrow.set(); handle.mouseEntered(with: hover)
        precondition(NSCursor.current == .openHand && textDrag == nil,"Border hover shows the movement cursor before pressing")
        canvas.mouseMoved(with: hover); canvas.cursorUpdate(with: hover)
        precondition(NSCursor.current === NSCursor.openHand,"Canvas tracking cannot overwrite its native text border")
        canvas.pointerActive = false
        NSCursor.arrow.set(); handle.mouseEntered(with: hover)
        precondition(NSCursor.current === NSCursor.arrow,"Inactive text borders cannot override selection mode")
        canvas.pointerActive = true
        if let directory = ProcessInfo.processInfo.environment["MACOSX_TEXT_FRAME_EVIDENCE_DIRECTORY"] {
            let target = URL(fileURLWithPath: directory,isDirectory: true)
            try! FileManager.default.createDirectory(at: target,withIntermediateDirectories: true)
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds,to: bitmap)
            try! bitmap.representation(using: .png,properties: [:])!.write(to: target.appendingPathComponent("text-frame-\(canvas.scale).png"))
        }
        func event(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: point,modifierFlags: [],timestamp: 0,
                windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown,start))
        handle.mouseEntered(with: hover); canvas.mouseMoved(with: hover)
        precondition(NSCursor.current === NSCursor.closedHand,"Tracking updates cannot turn an active text drag back into hover")
        let end = CGPoint(x: start.x + 12 * canvas.scale,y: start.y - 15 * canvas.scale)
        handle.mouseDragged(with: event(.leftMouseDragged,end))
        handle.mouseUp(with: event(.leftMouseUp,end))
        precondition(textInput === input && window.firstResponder === input && annotations.isEmpty && input.selectedRange() == selected && textDrag == nil,
                     "Dragging keeps the same native editor, caret, draft and no history entry")
        precondition(textAnnotation!.points[0] == CGPoint(x: original.points[0].x + 12,y: original.points[0].y - 15) && input.textContainer!.size == container,
                     "Movement maps points to image pixels without resizing or rewrapping")
        let location = canvas.viewPoint(for: textAnnotation!.points[0])
        precondition(abs(input.frame.minX - location.x) < 0.001 && abs(input.frame.maxY - location.y) < 0.001)
        // Native editing, including an active input-method composition, must
        // survive a move. Cancelling composition still belongs to NSTextView.
        input.setMarkedText("中",selectedRange: NSRange(location: 1,length: 0),replacementRange: NSRange(location: NSNotFound,length: 0))
        handle.mouseDown(with: event(.leftMouseDown,start))
        handle.mouseDragged(with: event(.leftMouseDragged,CGPoint(x: -1000,y: 1000)))
        precondition(input.hasMarkedText() && textInput === input && textAnnotation!.points[0].x == 0 && textAnnotation!.points[0].y == 160,
                     "Dragging clamps inside the image and preserves IME composition")
        precondition(canvas.bounds.contains(handle.frame) && !handle.frame.isEmpty,
                     "The editing border remains visible and hittable when text touches image edges")
        let edgeText = input.convert(CGPoint(x: 6/canvas.scale,y: 6/canvas.scale),to: canvas)
        precondition(canvas.hitTest(edgeText) === input,"Expanded border targets must keep native typing reachable next to clipped image edges")
        handle.mouseUp(with: event(.leftMouseUp,end)); input.unmarkText()
        let expected = textAnnotation!.points[0], value = input.string
        let outside = canvas.convert(CGPoint(x: input.bounds.maxX - 1,y: 1),from: input)
        precondition(input.hitTest(outside) == nil,"Blank wrapping-container space must let the canvas finish text editing")
        canvas.mouseDown(with: event(.leftMouseDown,CGPoint(x: 190,y: 10)))
        precondition(textInput == nil && textEditingFrame == nil && handle.superview == nil && annotations.count == 1,
                     "A background click commits once, removes the border and does not create another text editor")
        precondition(annotations[0].points[0] == expected && annotations[0].text == value &&
                     annotations[0].textLayoutWidth == original.textLayoutWidth,
                     "Commit retains the moved position, text and exact wrapping")
        undoAction(); precondition(annotations.isEmpty,"Input and its repositioning undo together")
        redoAction(); precondition(annotations.count == 1 && annotations[0].points[0] == expected)
        let next = beginTextFixture(point: CGPoint(x: 30,y: 70),width: 2,ink: .red)
        textDidEndEditing(Notification(name: NSText.didEndEditingNotification,object: input))
        precondition(textInput === next,"A stale end-editing notification cannot commit a new text draft")
        finishText(commit: false)
    }
}

@MainActor private extension PinEntry {
    func performFixture(_ command: PinCommand) { perform(command) }
    func applyRenderedEditFixture() { applyEdit(transform.render(image)!) }
    var fixtureZoom: CGFloat { zoom }
}

@main struct EditorRegression {
    @MainActor static func main() {
        setbuf(stdout,nil)
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let domain = "cc.anjing.macos-x.editor-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = CaptureRaster.context(width: 200, height: 160)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let image = context.makeImage()!
        CaptureSelection.verifySessionCopyFixture(image: image)
        for pin in [false,true] {
            let focused = CaptureEditor(image: image,selectionFrame: CGRect(x: 0,y: 0,width: 200,height: 160),editingPin: pin,defaults: defaults)
            focused.verifyCopyWithTextFocusFixture(); focused.close()
        }
        let spaceEditor = CaptureEditor(image: image,selectionFrame: CGRect(x: 0,y: 0,width: 200,height: 160),defaults: defaults)
        spaceEditor.verifySpaceModeFixture(); spaceEditor.close()
        let cursorEditor = CaptureEditor(image: image,selectionFrame: CGRect(x: 0,y: 0,width: 200,height: 160),defaults: defaults)
        cursorEditor.verifyCursorOwnershipFixture()
        CaptureSelection.verifyHoverFixture(image: image)
        CaptureSelection.verifyClickCopyFixture(image: image)
        // Real native input and exported pixels, including the normal 2x
        // screenshot-to-point mapping. No shown window or clipboard writes.
        for displayScale: CGFloat in [1, 0.5] {
            let movable = CaptureEditor(image: image,
                selectionFrame: CGRect(x: 0,y: 0,width: 200 * displayScale,height: 160 * displayScale),defaults: defaults)
            movable.verifyMovableTextFixture(); movable.close()
            let textEditor = CaptureEditor(image: image,
                selectionFrame: CGRect(x: 0,y: 0,width: 200 * displayScale,height: 160 * displayScale),defaults: defaults)
            textEditor.verifyTextPlacementFixture()
            let textCanvas = textEditor.window.contentView as! CaptureCanvas
            let ink = CaptureInk(red: 0.1,green: 0.6,blue: 0.9,alpha: 1)
            let input = textEditor.beginTextFixture(point: CGPoint(x: 16,y: 140),width: 3,ink: ink)
            precondition(!input.drawsBackground && input.backgroundColor == .clear && input.textContainerInset == .zero,
                         "The active text input is transparent and has no padded or opaque text field")
            let sampleText = "Ab中文 🙂 自动换行一致\n第二行"
            input.insertText(sampleText,replacementRange: NSRange(location: 0,length: 0))
            textEditor.textDidChange(Notification(name: NSText.didChangeNotification,object: input))
            precondition(abs(input.font!.pointSize * input.frame.width / input.bounds.width - 21 * displayScale) < 0.001)
            precondition(input.string == sampleText, "Plain native input retains Unicode and pasted line breaks")
            let beforeFrame = input.frame, beforeFont = input.font!, text = input.string
            let beforeContainer = input.textContainer!.size
            // Render the actual editable NSTextView, not another call to the
            // export helper. Its empty area must remain alpha-transparent.
            let nativeWidth = Int(ceil(input.bounds.width)), nativeHeight = Int(ceil(input.bounds.height))
            let nativeContext = CaptureRaster.context(width: nativeWidth,height: nativeHeight)!
            nativeContext.saveGState()
            nativeContext.translateBy(x: 0,y: CGFloat(nativeHeight)); nativeContext.scaleBy(x: 1,y: -1)
            let graphics = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: nativeContext,flipped: true)
            input.draw(input.bounds)
            NSGraphicsContext.current = graphics; nativeContext.restoreGState()
            let nativeInput = nativeContext.makeImage()!
            var localMark = CaptureAnnotation(tool: .text,points: [CGPoint(x: 0,y: CGFloat(nativeHeight))],ink: ink,width: 3)
            localMark.text = text; localMark.textLayoutWidth = beforeContainer.width
            let transparent = CaptureRaster.context(width: nativeWidth,height: nativeHeight)!.makeImage()!
            let nativeExport = CaptureAnnotationRenderer.render(base: transparent,annotations: [localMark])!
            let inputBytes = nativeInput.dataProvider!.data! as Data, exportBytes = nativeExport.dataProvider!.data! as Data
            var activePixels = 0, differences = 0
            for y in 0..<nativeHeight { for x in 0..<nativeWidth {
                let offset = y * nativeInput.bytesPerRow + x * 4
                let exported = y * nativeExport.bytesPerRow + x * 4
                if inputBytes[offset + 3] > 0 || exportBytes[exported + 3] > 0 { activePixels += 1 }
                if (0..<4).contains(where: { abs(Int(inputBytes[offset + $0]) - Int(exportBytes[exported + $0])) > 2 }) { differences += 1 }
            } }
            precondition(activePixels > 0 && activePixels < nativeWidth * nativeHeight / 2,
                         "Native editing renders real text and leaves the surrounding area transparent")
            print("Text native/export RGBA difference: \(differences) / \(activePixels), scale \(displayScale)")
            precondition(differences == 0, "Editable text glyph positions and shapes must match final export")
            if let directory = ProcessInfo.processInfo.environment["MACOSX_TEXT_EVIDENCE_DIRECTORY"] {
                let output = URL(fileURLWithPath: directory,isDirectory: true)
                try! FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
                for (name,bitmap) in [("editing",nativeInput),("export",nativeExport)] {
                    try! NSBitmapImageRep(cgImage: bitmap).representation(using: .png,properties: [:])!
                        .write(to: output.appendingPathComponent("\(name)-\(displayScale).png"))
                }
            }
            textEditor.finishTextFixture(commit: true)
            let mark = textEditor.fixtureTextMark!
            let layout = CaptureTextLayout(annotation: mark)
            precondition(mark.text == text && layout.attributes[.font] as? NSFont == beforeFont && layout.container.size == beforeContainer,
                         "Commit retains the exact font, full text and wrapping width")
            let topLeft = textCanvas.viewPoint(for: mark.points[0])
            precondition(abs(topLeft.x - beforeFrame.minX) < 0.001 && abs(topLeft.y - beforeFrame.maxY) < 0.001,
                         "Commit must retain the displayed top-left instead of moving to a different baseline")
            let rendered = DispatchQueue(label: "cc.anjing.macos-x.text-export-fixture").sync {
                CaptureAnnotationRenderer.render(base: image,annotations: [mark])!
            }
            let sample = CapturePixelSampler(image: rendered)!
            precondition(sample.sample(x: 190,y: 150)?.hex == "#FFFFFF", "Text exports have no opaque text-field background")
            precondition((24..<110).contains { y in (16..<180).contains { x in sample.sample(x: x,y: y)?.hex != "#FFFFFF" } },
                         "Committed text actually paints foreground glyphs")
            let abandoned = textEditor.beginTextFixture(point: CGPoint(x: 30,y: 70),width: 3,ink: ink)
            abandoned.insertText("取消本段",replacementRange: NSRange(location: 0,length: 0))
            precondition(textEditor.textView(abandoned,doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            precondition(textEditor.fixtureTextMark?.text == text, "Esc must abandon only the active text")
            textEditor.close()
        }
        let tinyImage = CaptureRaster.context(width: 1,height: 1)!.makeImage()!
        let tinyEditor = CaptureEditor(image: tinyImage,selectionFrame: CGRect(x: 0,y: 0,width: 1,height: 1),defaults: defaults)
        tinyEditor.verifyTinyTextFrameFixture(); tinyEditor.close()
        let pinEntry = PinEntry(image: image, frame: CGRect(x: -200, y: 40, width: 200, height: 160), queue: DispatchQueue(label: "pin-drag-fixture"))
        let pinView = pinEntry.window.contentView as! PinView
        let initialFrame = pinEntry.window.frame
        let anchor = CGPoint(x: initialFrame.minX + 40, y: initialFrame.minY + 40)
        func pinMouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: pinEntry.window.convertPoint(fromScreen: point), modifierFlags: [], timestamp: 0,
                windowNumber: pinEntry.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        pinView.mouseDown(with: pinMouse(.leftMouseDown, anchor))
        let across = CGPoint(x: anchor.x + 500, y: anchor.y + 30)
        pinView.mouseDragged(with: pinMouse(.leftMouseDragged, across))
        precondition(pinEntry.window.frame.origin == initialFrame.offsetBy(dx: 500, dy: 30).origin)
        let exitEvent = NSEvent.enterExitEvent(with: .mouseExited, location: pinEntry.window.convertPoint(fromScreen: across), modifierFlags: [], timestamp: 0,
            windowNumber: pinEntry.window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil)!
        pinView.mouseExited(with: exitEvent)
        pinView.updateTrackingAreas()
        let returned = CGPoint(x: anchor.x - 600, y: anchor.y - 80)
        pinView.mouseDragged(with: pinMouse(.leftMouseDragged, returned))
        precondition(pinEntry.window.frame == initialFrame.offsetBy(dx: -600, dy: -80), "Tracking exit/rebuild must not cancel an active drag across positive and negative desktop coordinates")
        pinView.mouseUp(with: pinMouse(.leftMouseUp, returned))
        let released = pinEntry.window.frame
        pinView.mouseDragged(with: pinMouse(.leftMouseDragged, across))
        precondition(pinEntry.window.frame == released, "Mouse release ends the drag")
        pinView.mouseDown(with: pinMouse(.leftMouseDown, returned))
        pinView.mouseUp(with: pinMouse(.leftMouseUp, returned))
        precondition(pinEntry.window.frame == released, "Focus click still leaves the pin in place")
        pinEntry.performFixture(.zoom(2))
        pinEntry.applyRenderedEditFixture()
        precondition(pinEntry.fixtureZoom == 2, "Applying an edit preserves the original zoom percentage")
        pinEntry.performFixture(.zoom(1.25))
        precondition(pinEntry.window.frame.size == CGSize(width: 500, height: 400), "Zoom after an edit remains relative to the initial 200x160 size")
        pinEntry.performFixture(.rotate(true))
        pinEntry.applyRenderedEditFixture()
        pinEntry.performFixture(.zoom(0.8))
        precondition(pinEntry.fixtureZoom == 2 && pinEntry.window.frame.size == CGSize(width: 320, height: 400), "Baked rotation preserves zoom and rotated dimensions")
        pinEntry.performFixture(.thumbnail)
        let thumbnailFrame = pinEntry.window.frame
        pinEntry.applyRenderedEditFixture()
        precondition(pinEntry.window.frame == thumbnailFrame && pinEntry.fixtureZoom == 2, "Editing a thumbnail preserves its display size and original zoom")
        pinEntry.performFixture(.thumbnail)
        precondition(pinEntry.window.frame.size == CGSize(width: 320, height: 400), "Leaving thumbnail mode after editing restores the original magnified size")
        pinEntry.dispose()
        let region = CGRect(x: 20, y: 40, width: 100, height: 80)
        let copyBoard = NSPasteboard.withUniqueName()
        for action in 0..<5 {
            let screenshot = CaptureEditor(image: image,selectionFrame: region,defaults: defaults,clipboard: copyBoard)
            screenshot.verifyCopyExitFixture(board: copyBoard,action: action)
        }
        let pinCopy = CaptureEditor(image: image,selectionFrame: region,editingPin: true,defaults: defaults,clipboard: copyBoard)
        pinCopy.verifyCopyExitFixture(board: copyBoard,action: 1)
        copyBoard.releaseGlobally()
        print("PASS copy acknowledgement: screenshot Command-C, Enter, canvas/panel copy and selection callback exit after PNG write; pin copy stays open")
        let editor = CaptureEditor(image: image, selectionFrame: region, defaults: defaults)
        var states = [Bool]()
        editor.onEditingChanged = { states.append($0) }
        func key(_ code: UInt16, _ character: String) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code)!
        }
        precondition((editor.window.contentView as! CaptureCanvas).tool == nil, "Initial selection must have no annotation tool")
        precondition(editor.handleSelectionKey(key(18, "1")))
        precondition(states.last == true && !editor.window.ignoresMouseEvents, "Selecting rectangle gives drawing input to editor")
        precondition(editor.handleSelectionKey(key(18, "1")))
        precondition(states.last == false && editor.window.ignoresMouseEvents, "Clicking current tool again restores selection adjustment")
        precondition(editor.handleSelectionKey(key(19, "2")))
        precondition(states.last == true, "Arrow also locks selection while drawing")
        precondition(editor.handleSelectionKey(key(53, "\u{1b}")))
        precondition(states.last == false && editor.window.ignoresMouseEvents, "Leaving annotation restores draggable selection rather than closing")
        let canvas = editor.window.contentView as! CaptureCanvas
        editor.beginPendingRecognitionFixture()
        canvas.onDraftBegan?()
        precondition(editor.recognitionWasCancelled, "A new draft clears pending OCR feedback and re-enables recognition")
        editor.showFixtureStatus("粗细 3 · 滚轮调节")
        canvas.onDraftBegan?()
        precondition(editor.fixtureStatus == "粗细 3 · 滚轮调节", "Cancelling an absent request preserves unrelated feedback")
        editor.beginPendingRecognitionFixture()
        editor.showFixtureStatus("粗细 4 · 滚轮调节")
        canvas.onDraftBegan?()
        precondition(editor.fixtureStatus == "粗细 4 · 滚轮调节", "Cancelling OCR does not erase newer tool feedback")
        func wheel(_ delta: Int32) -> NSEvent {
            NSEvent(cgEvent: CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!)!
        }
        precondition(!editor.handleThicknessScroll(wheel(1)) && canvas.lineWidth == 3, "Idle selection must not consume wheel")
        precondition(editor.handleSelectionKey(key(20, "3")))
        precondition(editor.handleThicknessScroll(wheel(1)) && canvas.lineWidth == 4, "One wheel notch increases stroke width")
        precondition(editor.handleThicknessScroll(wheel(-1)) && canvas.lineWidth == 3, "Opposite wheel notch decreases stroke width")
        func preciseWheel(_ delta: Int32, momentum: Bool = false) -> NSEvent {
            let value = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
            value.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            value.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
            if momentum { value.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) }
            return NSEvent(cgEvent: value)!
        }
        precondition(preciseWheel(3).hasPreciseScrollingDeltas)
        _ = editor.handleThicknessScroll(preciseWheel(3))
        _ = editor.handleThicknessScroll(preciseWheel(3))
        precondition(canvas.lineWidth == 3, "Small touchpad movement does not jump stroke width")
        _ = editor.handleThicknessScroll(preciseWheel(2))
        precondition(canvas.lineWidth == 4, "Touchpad movement accumulates to one controlled step")
        _ = editor.handleThicknessScroll(preciseWheel(80, momentum: true))
        precondition(canvas.lineWidth == 4, "Momentum cannot change stroke width")
        for _ in 0..<30 { _ = editor.handleThicknessScroll(wheel(1)) }
        precondition(canvas.lineWidth == 12, "Stroke width upper bound")
        for _ in 0..<30 { _ = editor.handleThicknessScroll(wheel(-1)) }
        precondition(canvas.lineWidth == 1 && !editor.window.isVisible, "Stroke width lower bound without presenting windows")
        precondition(editor.handleSelectionKey(key(21, "4")))
        precondition(!editor.handleThicknessScroll(wheel(1)), "Text tool must not accidentally change font size")
        precondition(editor.handleSelectionKey(key(23, "5")))
        precondition(editor.handleThicknessScroll(wheel(1)) && canvas.mosaicDiameter == 36 && canvas.lineWidth == 1, "Mosaic wheel changes diameter separately from drawing width")
        for _ in 0..<50 { _ = editor.handleThicknessScroll(wheel(-1)) }
        precondition(canvas.mosaicDiameter == 8, "Mosaic diameter lower bound")
        for _ in 0..<50 { _ = editor.handleThicknessScroll(wheel(1)) }
        precondition(canvas.mosaicDiameter == 160, "Mosaic diameter upper bound")
        let brushCanvas = CaptureCanvas(image: image); brushCanvas.imageInset = 0
        let brushWindow = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        brushWindow.isReleasedWhenClosed = false; brushWindow.contentView = brushCanvas
        brushCanvas.tool = .mosaic
        var strokes = [CaptureAnnotation](); brushCanvas.onAnnotation = { strokes.append($0) }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: brushWindow.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        brushCanvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 80, y: 80)))
        brushCanvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 110, y: 90)))
        brushCanvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 140, y: 100)))
        precondition(strokes.count == 1 && strokes[0].points.contains(CGPoint(x: 110, y: 90)) && strokes[0].points.last == CGPoint(x: 140, y: 100), "One drag commits one freehand stroke, including release position")
        brushCanvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
        brushCanvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 50, y: 50)))
        precondition(strokes.count == 2 && strokes[1].width == 32, "Click commits a circular dab with the selected diameter")
        brushCanvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
        precondition(brushCanvas.cancelDraft(), "Active brush stroke can be cancelled")
        brushCanvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 50, y: 50)))
        precondition(strokes.count == 2, "Cancelled stroke does not commit")
        brushCanvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
        brushCanvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 80, y: 50)))
        precondition(brushCanvas.commitDraft() && strokes.count == 3, "Export can commit an in-progress redaction")
        brushCanvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 80, y: 50)))
        precondition(strokes.count == 3, "Release cannot double-commit an exported stroke")
        brushCanvas.stopBrushPreview(); brushWindow.close()
        precondition(editor.handleSelectionKey(key(53, "\u{1b}")))
        let palette = CaptureColorPalette(colors: [SketchPalette.ink, SketchPalette.coral, SketchPalette.orange, SketchPalette.yellow, SketchPalette.green, SketchPalette.blue, SketchPalette.purple, .white], selected: SketchPalette.coral, target: editor, action: NSSelectorFromString("chooseColor:"))
        precondition(palette.subviews.count == 8, "All eight preset colours remain directly selectable")
        let colourButtons = palette.subviews.compactMap { $0 as? CaptureToolButton }
        precondition(colourButtons.filter { $0.state == .on }.map(\.tag) == [1], "Current colour is visibly selected in the palette")
        for button in colourButtons {
            button.performClick(nil)
            precondition(colourButtons.filter { $0.state == .on }.map(\.tag) == [button.tag], "Palette selection is exclusive after every click")
            let expected = CaptureInk(button.ink)
            precondition(canvas.ink.red == expected.red && canvas.ink.green == expected.green && canvas.ink.blue == expected.blue,
                         "Each graphical paint spot directly selects its corresponding colour")
        }
        let glyphHost = CaptureToolbarSurface(frame: CGRect(x: 0, y: 0, width: 218, height: 46))
        let glyphs: [CaptureToolButton.Glyph] = [.rectangle, .arrow, .pen, .text, .mosaic]
        for (index, glyph) in glyphs.enumerated() {
            let button = CaptureToolButton(glyph, title: "白色工具", target: editor, action: NSSelectorFromString("copy:"))
            button.ink = .white; button.state = .on
            button.frame = CGRect(x: 6 + index * 42, y: 6, width: 34, height: 34)
            glyphHost.addSubview(button)
        }
        let glyphBitmap = glyphHost.bitmapImageRepForCachingDisplay(in: glyphHost.bounds)!
        glyphHost.cacheDisplay(in: glyphHost.bounds, to: glyphBitmap)
        let pixelScale = CGFloat(glyphBitmap.pixelsWide) / glyphHost.bounds.width
        for index in glyphs.indices {
            let rect = CGRect(x: 10 + index * 42, y: 10, width: 26, height: 26)
            var visiblePixels = 0
            for y in Int(rect.minY * pixelScale)..<Int(rect.maxY * pixelScale) {
                for x in Int(rect.minX * pixelScale)..<Int(rect.maxX * pixelScale) {
                    if let color = glyphBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) < 0.8 { visiblePixels += 1 }
                }
            }
            precondition(visiblePixels > 20, "Each selected white glyph must remain visible on a white toolbar")
        }
        if let output = ProcessInfo.processInfo.environment["MACOSX_WHITE_TOOLS_PREVIEW"] {
            try! glyphBitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
        }
        colourButtons.first { $0.tag == 5 }!.performClick(nil)
        let rememberedWidth = canvas.lineWidth, rememberedDiameter = canvas.mosaicDiameter
        let reopened = CaptureEditor(image: image, defaults: UserDefaults(suiteName: domain)!)
        let restored = reopened.window.contentView as! CaptureCanvas
        precondition(restored.lineWidth == rememberedWidth && restored.mosaicDiameter == rememberedDiameter,
                     "A new editor restores thickness and separate brush size from saved preferences")
        let blue = CaptureInk(SketchPalette.blue)
        precondition(restored.ink.blue == blue.blue && restored.ink.red == blue.red && restored.tool == nil,
                     "A new editor restores the selected colour while leaving the region adjustable")
        reopened.close()
        if let output = ProcessInfo.processInfo.environment["MACOSX_PALETTE_PREVIEW"] {
            NSApp.appearance = NSAppearance(named: .aqua)
            let host = CaptureToolbarSurface(frame: CGRect(x: 0, y: 0, width: 290, height: 170))
            palette.frame.origin = CGPoint(x: 62, y: 8); host.addSubview(palette)
            let button = CaptureToolButton(.color, title: "调色盘", target: editor, action: NSSelectorFromString("copy:"))
            button.frame = CGRect(x: 12, y: 72, width: 34, height: 34); host.addSubview(button)
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
            }
        }
        let before = editor.selectionFrame
        editor.beginPendingRecognitionFixture()
        editor.beginRegionAdjustment(); editor.beginRegionAdjustment()
        precondition(editor.recognitionWasCancelled, "Resizing a selection clears pending OCR feedback")
        precondition(!editor.handleSelectionKey(key(18, "1")), "Pending crop cannot start a drawing tool")
        let next = before.offsetBy(dx: 20, dy: 10)
        editor.replaceSelectionImage(image, at: next)
        precondition(editor.selectionFrame == next && states.last == false, "Updated crop stays adjustable")
        precondition(!editor.window.isVisible, "Regression must not display windows")
        editor.close()
        let pin = CaptureEditor(image: image, selectionFrame: region, editingPin: true, defaults: defaults)
        precondition((pin.window.contentView as! CaptureCanvas).ink.blue == blue.blue, "Pin editing shares the saved drawing style")
        pin.beginRegionAdjustment(); pin.replaceSelectionImage(image, at: next)
        precondition(pin.selectionFrame == region, "Pinned-image editing cannot recrop the desktop")
        pin.close()
        let spacePin = CaptureEditor(image: image,selectionFrame: region,editingPin: true,defaults: defaults)
        let spaceCanvas = spacePin.window.contentView as! CaptureCanvas
        precondition(spacePin.handleSelectionKey(key(21,"4")))
        let pending = spacePin.beginTextFixture(point: CGPoint(x: 20,y: 100),width: 2,ink: .red)
        pending.insertText("已提交",replacementRange: NSRange(location: 0,length: 0))
        spacePin.finishTextFixture(commit: true)
        var appliedPin: CGImage?
        spacePin.onApply = { appliedPin = $0 }
        precondition(spacePin.handleSelectionKey(key(49," ")) && !spaceCanvas.inputEnabled)
        let pinDeadline = Date().addingTimeInterval(4)
        while appliedPin == nil && Date() < pinDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(appliedPin != nil && spacePin.fixtureClosed && !spaceCanvas.inputEnabled,
                     "F3 Space applies the edit and closes its editor, leaving no live drawing canvas")
        let activeExport = CaptureEditor(image: image, selectionFrame: CGRect(x: 0, y: 0, width: 200, height: 160), defaults: defaults)
        let activeCanvas = activeExport.window.contentView as! CaptureCanvas
        activeCanvas.lineWidth = 3
        activeCanvas.tool = .pen
        func activeMouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: activeExport.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        activeCanvas.mouseDown(with: activeMouse(.leftMouseDown, CGPoint(x: 20, y: 40)))
        activeCanvas.mouseDragged(with: activeMouse(.leftMouseDragged, CGPoint(x: 100, y: 40)))
        var exported: CGImage?
        activeExport.onPin = { exported = $0 }
        activeExport.beginPendingRecognitionFixture()
        activeExport.pinCurrentImage()
        precondition(activeExport.recognitionWasCancelled, "Export clears pending OCR feedback")
        precondition(!activeCanvas.inputEnabled, "Export locks canvas edits until completion")
        let deadline = Date().addingTimeInterval(4)
        while exported == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(exported != nil, "F3 resolves without displaying windows")
        precondition(CapturePixelSampler(image: exported!)!.sample(x: 40, y: 119)?.hex != "#FFFFFF", "F3 while dragging exports the current visible stroke")
        activeExport.close()
        defaults.set(99, forKey: "capture.editor.color")
        defaults.set(100, forKey: "capture.editor.line-width")
        defaults.set(0, forKey: "capture.editor.mosaic-diameter")
        let bounded = CaptureEditor(image: image, defaults: defaults)
        let boundedCanvas = bounded.window.contentView as! CaptureCanvas
        precondition(boundedCanvas.lineWidth == 12 && boundedCanvas.mosaicDiameter == 8 && boundedCanvas.ink.red == CaptureInk(SketchPalette.coral).red,
                     "Out-of-range preferences cannot create invalid brush styles")
        bounded.close()
        print("PASS editor interaction: default adjustment, tool lock/toggle, Esc, pending crop, region replacement and pin isolation; no screen capture or general clipboard writes")
    }
}

@MainActor private extension CaptureSelection {
    static func verifySessionCopyFixture(image: CGImage) {
        let region = CGRect(x: 20,y: 20,width: 150,height: 120)
        let frame = CaptureFrame(screen: .init(id: 7,frame: CGRect(x: 0,y: 0,width: 200,height: 160),scale: 1),
                                 image: image,windows: [region],windowTargets: [.init(id: 42,frame: region)])
        var results = [Result](), copies = 0
        func make(selected: Bool = true) -> CaptureSelection {
            results.removeAll(); copies = 0
            let controller = CaptureSelection()
            controller.frames = [frame]; controller.candidates = [region]; controller.pointer = CGPoint(x: 80,y: 80)
            controller.selection = selected ? region : .null; controller.acceptsInput = true
            controller.completion = { results.append($0) }
            return controller
        }
        func key(_ code: UInt16 = 8,_ text: String = "c",flags: NSEvent.ModifierFlags = .command,repeat repeated: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: flags,timestamp: 0,windowNumber: 0,
                context: nil,characters: text,charactersIgnoringModifiers: text,isARepeat: repeated,keyCode: code)!
        }
        let native = make()
        native.onEditorCopy = { copies += 1 }; native.acceptsInput = false
        let previousMenu = NSApp.mainMenu
        let menu = NSMenu(), item = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Copy",action: NSSelectorFromString("copy:"),keyEquivalent: "c"))
        item.submenu = edit; menu.addItem(item); NSApp.mainMenu = menu
        NSApp.sendEvent(key())
        precondition(copies == 0,"The native menu can consume Command-C without a key-window copy target")
        native.installCopyMonitor(); native.installCopyMonitor()
        NSApp.sendEvent(key())
        precondition(copies == 1 && native.copyMonitor != nil,
                     "Real NSApplication dispatch reaches F1 once, before menu processing, even without a key-window target")
        NSApp.sendEvent(key(repeat: true)); precondition(copies == 1,"Repeats do not duplicate a pending copy")
        precondition(!native.handleCopyShortcut(key(flags: [.command,.shift])) && !native.handleCopyShortcut(key(flags: .control)),
                     "OCR and unrelated keyboard combinations retain their original routing")
        native.dismiss(); NSApp.sendEvent(key())
        precondition(copies == 1 && native.copyMonitor == nil,"Closing F1 removes the session monitor")
        let raw = make(selected: false); raw.installCopyMonitor(); NSApp.sendEvent(key())
        guard results.count == 1, case .copy(let rawRect) = results[0] else { preconditionFailure("A native Command-C copies the magnet preview without an editor") }
        precondition(rawRect == region && raw.copyMonitor != nil && raw.copyingRange && !raw.acceptsInput,
                     "Direct copy retains the exact visible range and frozen backdrop until the clipboard acknowledges success")
        NSApp.sendEvent(key()); precondition(results.count == 1,"Repeated copy while encoding stays single-flight")
        raw.completeRangeCopy(error: "fixture failure")
        precondition(!raw.copyingRange && raw.selection == region && raw.snappedWindow?.id == 42 && raw.copyMonitor != nil,
                     "A failed magnet copy retains geometry and the isolated-window identity for retry")
        raw.acceptsInput = true; NSApp.sendEvent(key())
        precondition(results.count == 2 && raw.copyingRange,"The same range can be retried")
        precondition(raw.completedWindow?.id == 42,"Retry must not silently fall back to pixels behind the window")
        raw.completeRangeCopy()
        precondition(raw.copyMonitor == nil && raw.frames.isEmpty && !raw.copyingRange && !raw.acceptsInput,
                     "Successful copy releases the frozen session and its input listener")
        raw.mouseDown(CGPoint(x: region.midX,y: region.midY)); raw.mouseUp(CGPoint(x: region.midX,y: region.midY))
        precondition(results.count == 2,"Clicks after successful copy cannot revive the old screenshot")
        NSApp.mainMenu = previousMenu
        let pending = make(selected: false)
        _ = pending.keyDown(key(49," ",flags: []))
        precondition(pending.awaitingEditor && pending.selection == region && pending.completedWindow?.id == 42,
                     "Space freezes the magnetized range before opening its editor")
        pending.pointer = .zero
        for _ in 0..<3 { precondition(pending.keyDown(key())) }
        precondition(pending.pendingCopy && results.count == 1 && copies == 0,"Copy waits for the new image, coalescing repeated requests")
        pending.onEditorCopy = { copies += 1 }
        precondition(pending.editorDidBecomeReady() && copies == 1 && !pending.pendingCopy)
        precondition(!pending.editorDidBecomeReady() && copies == 1,"The ready callback drains the copy exactly once")
        pending.acceptsInput = false; precondition(pending.keyDown(key()) && copies == 2,"Annotation lock does not block Command-C")
        pending.dismiss()
        let cancelled = make(selected: false)
        _ = cancelled.keyDown(key(49," ",flags: [])); _ = cancelled.keyDown(key())
        cancelled.dismiss(); precondition(!cancelled.editorDidBecomeReady() && copies == 0,"Cancelled deferred copies cannot fire in a later session")
        let moving = make(); moving.onEditorCopy = { copies += 1 }
        let start = CGPoint(x: 80,y: 80), end = CGPoint(x: 90,y: 85)
        moving.mouseDown(start); moving.mouseDragged(end)
        precondition(moving.keyDown(key()) && moving.drag == nil && moving.awaitingEditor && moving.pendingCopy && copies == 0)
        guard results.count == 1, case .edit(let moved) = results[0] else { preconditionFailure("Copy finalizes the live selection first") }
        precondition(moved == region.offsetBy(dx: 10,dy: 5),"Copy uses the currently dragged range, not the old editor crop")
        precondition(moving.editorDidBecomeReady() && copies == 1)
        moving.mouseUp(end); precondition(copies == 1,"A later physical mouse-up cannot copy twice")
        moving.dismiss()
        let locked = make(); locked.acceptsInput = false
        precondition(locked.keyDown(key()))
        guard results.count == 1, case .copy(let copied) = results[0] else { preconditionFailure("A retained F1 range without an editor remains copyable") }
        precondition(copied == region)
        locked.dismiss()
        let cancelledCopy = make(selected: false)
        _ = cancelledCopy.keyDown(key())
        precondition(cancelledCopy.copyingRange && cancelledCopy.keyDown(key(53,"",flags: [])))
        guard results.count == 2, case .cancel = results.last else { preconditionFailure("Esc can cancel while a direct copy is pending") }
        precondition(!cancelledCopy.copyingRange && cancelledCopy.frames.isEmpty)
        let recording = make(); recording.mode = .recording; recording.installCopyMonitor()
        precondition(recording.copyMonitor == nil && !recording.handleCopyShortcut(key()),"Recording does not acquire F1's copy interception")
        recording.dismiss()
        print("PASS F1 session copy: native application/menu dispatch, no key-window target, text focus, drag/crop readiness, coalescing, cancellation and listener release")
    }
    static func verifyClickCopyFixture(image: CGImage) {
        let screen = CaptureScreen(id: 7,frame: CGRect(x: -400,y: -200,width: 200,height: 160),scale: 1)
        let region = CGRect(x: -380,y: -180,width: 120,height: 100)
        let target = CaptureWindow(id: 42,frame: region)
        let snapshot = CaptureFrame(screen: screen,image: image,windows: [region],windowTargets: [target])
        let inside = CGPoint(x: region.midX,y: region.midY)
        var results = [Result](), copies = 0, adjustments = 0, activations = 0
        func make(selected: Bool = false, editor: Bool = false) -> CaptureSelection {
            results.removeAll(); copies = 0; adjustments = 0; activations = 0
            let controller = CaptureSelection()
            controller.frames = [snapshot]; controller.candidates = [region]; controller.pointer = inside
            controller.acceptsInput = true; controller.selection = selected ? region : .null
            controller.snappedWindow = selected ? target : nil
            controller.completion = { results.append($0) }
            controller.onAdjustmentStarted = { adjustments += 1 }
            if editor { controller.onEditorCopy = { copies += 1 }; controller.onEditorActivate = { activations += 1 } }
            return controller
        }
        func key(_ code: UInt16,_ text: String,command: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: command ? .command : [],timestamp: 0,
                windowNumber: 0,context: nil,characters: text,charactersIgnoringModifiers: text,isARepeat: false,keyCode: code)!
        }
        let click = make()
        click.mouseDown(inside)
        precondition(results.isEmpty && adjustments == 0,"Mouse-down must not copy or lock a crop before drag intent is known")
        let jitter = CGPoint(x: inside.x + 1,y: inside.y + 1)
        click.mouseDragged(jitter); click.mouseUp(jitter)
        guard results.count == 1, case .edit(let clicked) = results[0] else { preconditionFailure("Single magnet click opens inline editing") }
        precondition(clicked == region && click.completedWindow?.id == target.id && adjustments == 1 && copies == 0,
                     "A magnet click retains the isolated-window identity and tolerates slight pointer jitter")
        click.mouseUp(jitter); precondition(results.count == 1,"Release is consumed exactly once")
        for event in [key(8,"c",command: true),key(36,"\r")] {
            let keyboard = make()
            precondition(keyboard.keyDown(event))
            guard results.count == 1, case .copy(let rect) = results[0] else { preconditionFailure("Keyboard copies magnet preview") }
            precondition(rect == clicked && keyboard.completedWindow?.id == target.id,
                         "Click-to-edit, Enter and Command-C retain the same region and isolated window capture")
        }
        let edited = make(selected: true,editor: true)
        edited.mouseDown(inside); edited.mouseUp(inside)
        precondition(copies == 0 && results.isEmpty && adjustments == 0 && activations == 1,
                     "Clicking an existing selection restores its editor without copying, recropping or losing annotations")
        _ = edited.keyDown(key(8,"c",command: true)); _ = edited.keyDown(key(36,"\r"))
        precondition(copies == 2 && results.isEmpty,"Keyboard copies independently of click-to-edit")
        edited.dismiss()
        for returnsToStart in [false,true] {
            let moved = make(selected: true,editor: true)
            moved.mouseDown(inside)
            let end = CGPoint(x: inside.x + 10,y: inside.y + 8)
            moved.mouseDragged(end); moved.mouseUp(returnsToStart ? inside : end)
            guard results.count == 1, case .edit(let rect) = results[0] else { preconditionFailure("A drag adjusts instead of copying") }
            precondition(rect == (returnsToStart ? region : region.offsetBy(dx: 10,dy: 8)) && copies == 0 && adjustments == 1,
                         "Dragging, including returning to the start, never confirms a click")
            precondition(moved.completedWindow == nil && moved.frames.first?.image === image,
                         "Changed regions keep frozen pixels and cannot retain stale window identity")
            moved.dismiss()
        }
        for handle in SelectionView.handles(region) {
            let edge = CGPoint(x: handle.midX,y: handle.midY)
            let resized = make(selected: true,editor: true)
            resized.mouseDown(edge); resized.mouseUp(edge)
            precondition(results.isEmpty && copies == 0 && adjustments == 0,"An edge click alone cannot accidentally copy")
            resized.mouseDown(edge); resized.mouseDragged(CGPoint(x: edge.x + 8,y: edge.y + 8))
            resized.mouseUp(CGPoint(x: edge.x + 8,y: edge.y + 8))
            guard results.count == 1, case .edit = results[0] else { preconditionFailure("All eight borders remain adjustable") }
            precondition(copies == 0 && adjustments == 1)
            resized.dismiss()
        }
        let precise = make(selected: true,editor: true)
        let left = CGPoint(x: region.minX,y: region.midY)
        precise.mouseDown(left); precise.mouseUp(CGPoint(x: left.x - 1,y: left.y))
        guard results.count == 1, case .edit(let preciseRect) = results[0] else { preconditionFailure("One-pixel edge changes remain possible") }
        precondition(preciseRect == CGRect(x: region.minX - 1,y: region.minY,width: region.width + 1,height: region.height) && copies == 0)
        precise.dismiss()
        let free = make()
        let blank = CGPoint(x: -395,y: -195), end = CGPoint(x: -350,y: -150)
        free.mouseDown(blank); free.mouseDragged(end); free.mouseUp(end)
        guard results.count == 1, case .edit(let drawn) = results[0] else { preconditionFailure("Drawing still opens inline annotation") }
        precondition(drawn == CGRect(x: -395,y: -195,width: 45,height: 45) && copies == 0)
        free.dismiss()
        let empty = make(); empty.mouseDown(blank); empty.mouseUp(blank)
        precondition(results.isEmpty && empty.acceptsInput,"A blank click without a window cannot copy an invalid region")
        empty.dismiss()
        let changed = make(selected: true,editor: true)
        let other = CaptureWindow(id: 43,frame: CGRect(x: -250,y: -180,width: 40,height: 80))
        changed.frames = [CaptureFrame(screen: screen,image: image,windows: [region,other.frame],windowTargets: [target,other])]
        changed.candidates = [region,other.frame]
        let another = CGPoint(x: other.frame.midX,y: other.frame.midY)
        changed.mouseDown(another); changed.mouseUp(another)
        guard results.count == 1, case .edit(let newRect) = results[0] else { preconditionFailure("Another magnetized window opens its own editor") }
        precondition(newRect == other.frame && changed.completedWindow?.id == other.id && copies == 0,
                     "A new window click cannot use the previous editor's crop")
        let locked = make(selected: true,editor: true); locked.acceptsInput = false
        locked.mouseDown(inside); locked.mouseUp(inside)
        precondition(results.isEmpty && copies == 0 && locked.selection == region,"Active annotation input cannot trigger selection copy")
        locked.dismiss()
        let recording = make(); recording.mode = .recording
        recording.copyPressed(); precondition(results.isEmpty,"Recording never uses screenshot copy")
        _ = recording.keyDown(key(36,"\r"))
        guard results.count == 1, case .edit(let recorded) = results[0] else { preconditionFailure("Recording Enter still confirms recording") }
        precondition(recorded == region)
        print("PASS click-to-edit: magnet identity, existing editor reuse, independent keyboard copy, jitter, eight resize edges, drag return, new-window identity and recording separation")
    }
    static func verifyHoverFixture(image: CGImage) {
        let oldCursor = NSCursor.current
        defer { oldCursor.set() }
        let screen = CGRect(x: -500, y: -300, width: 400, height: 300)
        let snapshot = CaptureFrame(screen: .init(id: 7, frame: screen, scale: 2), image: image)
        let panel = Panel(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.size), snapshot: snapshot)
        panel.contentView = view
        view.updateTrackingAreas(); view.updateTrackingAreas()
        precondition(view.trackingAreas.count == 2, "tracking replacement stays bounded across layout updates")
        precondition(view.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.activeAlways) }, "inactive display panels still receive hover movement")
        precondition(view.trackingAreas.filter { $0.options.contains(.cursorUpdate) }.allSatisfy { $0.options.contains(.activeInKeyWindow) && !$0.options.contains(.activeAlways) }, "cursor refresh uses AppKit-supported activation options")
        let controller = CaptureSelection()
        let region = CGRect(x: -460, y: -260, width: 220, height: 160)
        controller.frames = [snapshot]; controller.panels = [panel]; controller.views = [view]
        controller.selection = region; controller.acceptsInput = true
        view.cursorAt = { controller.cursor(at: $0) }
        view.onPointer = { controller.pointerMoved($0) }
        defer { controller.dismiss() }
        func hover(_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .mouseMoved, location: panel.convertPoint(fromScreen: point), modifierFlags: [],
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
        }
        let positions: [(CGPoint, Int)] = [
            (CGPoint(x: -460, y: -260), 0), (CGPoint(x: -405, y: -260), 1),
            (CGPoint(x: -240, y: -260), 2), (CGPoint(x: -240, y: -220), 3),
            (CGPoint(x: -240, y: -100), 4), (CGPoint(x: -355, y: -100), 5),
            (CGPoint(x: -460, y: -100), 6), (CGPoint(x: -460, y: -180), 7)]
        for (point, handle) in positions {
            precondition(SelectionView.resizeHandle(at: point, in: region) == handle, "edges and corners have distinct resize hits")
            view.mouseMoved(with: hover(point))
            precondition(controller.drag == nil && NSCursor.current === SelectionView.resizeCursor(for: handle), "hover sets resize cursor before any button press")
            precondition(controller.selection == region && controller.frames.first?.image === image, "hover leaves the selection and frozen image unchanged")
            NSCursor.arrow.set(); view.cursorUpdate(with: hover(point))
            precondition(NSCursor.current === SelectionView.resizeCursor(for: handle), "AppKit cursor refresh cannot restore a blanket crosshair over the edge")
            controller.mouseDown(point)
            guard case let .resize(actual, _, _) = controller.drag else { preconditionFailure("hover promise must match actual edge dragging") }
            precondition(actual == handle)
            controller.drag = nil
        }
        let inside = CGPoint(x: -350, y: -180), outside = CGPoint(x: -490, y: -290)
        view.mouseEntered(with: hover(inside))
        precondition(NSCursor.current === NSCursor.arrow, "selection interior keeps a stable normal arrow before dragging")
        controller.mouseDown(inside)
        precondition(controller.cursor(at: inside) === NSCursor.arrow, "Pressing to confirm does not briefly flash a drag cursor")
        controller.mouseDragged(CGPoint(x: inside.x + 2,y: inside.y))
        precondition(controller.cursor(at: inside) === NSCursor.arrow,"Click jitter retains the same arrow")
        controller.mouseDragged(CGPoint(x: inside.x + 8,y: inside.y))
        precondition(controller.cursor(at: inside) === NSCursor.closedHand,"Actual selection movement uses a closed hand")
        controller.selection = region
        controller.drag = nil
        view.mouseMoved(with: hover(outside))
        precondition(NSCursor.current === NSCursor.crosshair, "outside selection remains ready to create a new region")
        controller.mouseDown(CGPoint(x: -460, y: -180))
        controller.mouseDragged(CGPoint(x: -470, y: -180))
        precondition(controller.selection == CGRect(x: -470, y: -260, width: 230, height: 160), "whole-edge hit really resizes that side")
        controller.drag = nil; controller.selection = region
        controller.setEditing(true)
        precondition(view.trackingAreas.isEmpty && !panel.areCursorRectsEnabled,"Backdrop tracking and native cursor rects are removed when the annotation layer owns the pointer")
        NSCursor.arrow.set(); view.cursorUpdate(with: hover(inside))
        precondition(controller.cursor(at: inside) == nil && NSCursor.current === NSCursor.arrow, "locked annotation must not receive selection hover cursors")
        controller.acceptsInput = true
        NSCursor.iBeam.set(); view.mouseEntered(with: hover(inside)); view.mouseMoved(with: hover(inside))
        precondition(NSCursor.current === NSCursor.iBeam,"Stale backdrop events cannot replace the active editor cursor")
        for _ in 0..<5 {
            panel.acceptsSelectionInput = true; panel.acceptsSelectionInput = true; view.tracksPointer = true
            precondition(panel.areCursorRectsEnabled && view.trackingAreas.count == 2,"Resuming cursor ownership remains balanced")
            panel.acceptsSelectionInput = false; panel.acceptsSelectionInput = false; view.tracksPointer = false
            precondition(!panel.areCursorRectsEnabled && view.trackingAreas.isEmpty,"Repeatedly releasing ownership cannot accumulate cursor tracking")
        }
        controller.acceptsInput = true; controller.selection = .null; controller.candidates = [region]
        precondition(controller.cursor(at: inside) === NSCursor.crosshair, "window magnet preview is not already a draggable selection")
        precondition(SelectionView.resizeHandle(at: CGPoint(x: 1.9, y: 1.9), in: CGRect(x: 0, y: 0, width: 2, height: 2)) == 4,
                     "tiny selections choose the nearest corner rather than the first overlapping handle")
        precondition(SelectionView.resizeHandle(at: .zero, in: .null) == nil)
        SelectionView.verifyLegacyCursorFixture()
        print("PASS selection hover: all 8 directions before mouseDown, whole-edge drag agreement, cursorUpdate/entry, negative origins, tiny corners, annotation lock and unchanged frozen image")
    }
}
@MainActor private extension SelectionView {
    static func verifyLegacyCursorFixture() {
        let first = diagonalCursor(rising: true), second = diagonalCursor(rising: false)
        precondition(first.image.size == CGSize(width: 24, height: 24) && first.hotSpot == CGPoint(x: 12, y: 12))
        precondition(first.image.tiffRepresentation != nil && second.image.tiffRepresentation != nil)
        precondition(first.image.tiffRepresentation != second.image.tiffRepresentation, "macOS 14 fallback diagonals render in different directions")
    }
}
