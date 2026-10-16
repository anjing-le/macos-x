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
    func verifyMovableTextFixture() {
        canvas.tool = .text
        let input = beginTextFixture(point: CGPoint(x: 40,y: 120),width: 2,ink: .red)
        input.insertText("移动",replacementRange: NSRange(location: 0,length: 0))
        textDidChange(Notification(name: NSText.didChangeNotification,object: input))
        input.setSelectedRange(NSRange(location: 1,length: 0))
        let selected = input.selectedRange(), original = textAnnotation!, container = input.textContainer!.size
        let handle = textMoveHandle!, start = CGPoint(x: 20,y: 80)
        func event(_ type: NSEvent.EventType,_ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type,location: point,modifierFlags: [],timestamp: 0,
                windowNumber: window.windowNumber,context: nil,eventNumber: 1,clickCount: 1,pressure: 1)!
        }
        handle.mouseDown(with: event(.leftMouseDown,start))
        let end = CGPoint(x: start.x + 12 * canvas.scale,y: start.y - 15 * canvas.scale)
        handle.mouseDragged(with: event(.leftMouseDragged,end))
        handle.mouseUp(with: event(.leftMouseUp,end))
        precondition(textInput === input && window.firstResponder === input && annotations.isEmpty && input.selectedRange() == selected && textDrag == nil,
                     "Dragging keeps the same native editor, caret, draft and no history entry")
        precondition(textAnnotation!.points[0] == CGPoint(x: 52,y: 105) && input.textContainer!.size == container,
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
        handle.mouseUp(with: event(.leftMouseUp,end)); input.unmarkText()
        let expected = textAnnotation!.points[0], value = input.string
        let outside = canvas.convert(CGPoint(x: input.bounds.maxX - 1,y: 1),from: input)
        precondition(input.hitTest(outside) == nil,"Blank wrapping-container space must let the canvas finish text editing")
        canvas.mouseDown(with: event(.leftMouseDown,CGPoint(x: 190,y: 10)))
        precondition(textInput == nil && textMoveHandle == nil && handle.superview == nil && annotations.count == 1,
                     "A background click commits once, removes the handle and does not create another text editor")
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
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let domain = "cc.anjing.macos-x.editor-fixture.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let context = CaptureRaster.context(width: 200, height: 160)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let image = context.makeImage()!
        CaptureSelection.verifyHoverFixture(image: image)
        // Real native input and exported pixels, including the normal 2x
        // screenshot-to-point mapping. No shown window or clipboard writes.
        for displayScale: CGFloat in [1, 0.5] {
            let movable = CaptureEditor(image: image,
                selectionFrame: CGRect(x: 0,y: 0,width: 200 * displayScale,height: 160 * displayScale),defaults: defaults)
            movable.verifyMovableTextFixture(); movable.close()
            let textEditor = CaptureEditor(image: image,
                selectionFrame: CGRect(x: 0,y: 0,width: 200 * displayScale,height: 160 * displayScale),defaults: defaults)
            let textCanvas = textEditor.window.contentView as! CaptureCanvas
            let ink = CaptureInk(red: 0.1,green: 0.6,blue: 0.9,alpha: 1)
            let input = textEditor.beginTextFixture(point: CGPoint(x: 16,y: 140),width: 3,ink: ink)
            precondition(!input.drawsBackground && input.backgroundColor == .clear && input.textContainerInset == .zero,
                         "The active text input is transparent and has no padded field or border")
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
        print("PASS editor interaction: default adjustment, tool lock/toggle, Esc, pending crop, region replacement and pin isolation; no displayed windows, capture or clipboard writes")
    }
}

@MainActor private extension CaptureSelection {
    static func verifyHoverFixture(image: CGImage) {
        let oldCursor = NSCursor.current
        defer { oldCursor.set() }
        let screen = CGRect(x: -500, y: -300, width: 400, height: 300)
        let snapshot = CaptureFrame(screen: .init(id: 7, frame: screen, scale: 2), image: image)
        let panel = NSPanel(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
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
            controller.mouseDown(point, twice: false)
            guard case let .resize(actual, _, _) = controller.drag else { preconditionFailure("hover promise must match actual edge dragging") }
            precondition(actual == handle)
            controller.drag = nil
        }
        let inside = CGPoint(x: -350, y: -180), outside = CGPoint(x: -490, y: -290)
        view.mouseEntered(with: hover(inside))
        precondition(NSCursor.current === NSCursor.openHand, "selection interior advertises movement on entry")
        controller.mouseDown(inside, twice: false)
        precondition(controller.cursor(at: inside) === NSCursor.closedHand, "held move uses a closed hand")
        controller.drag = nil
        view.mouseMoved(with: hover(outside))
        precondition(NSCursor.current === NSCursor.crosshair, "outside selection remains ready to create a new region")
        controller.mouseDown(CGPoint(x: -460, y: -180), twice: false)
        controller.mouseDragged(CGPoint(x: -470, y: -180))
        precondition(controller.selection == CGRect(x: -470, y: -260, width: 230, height: 160), "whole-edge hit really resizes that side")
        controller.drag = nil; controller.selection = region
        controller.setEditing(true)
        NSCursor.arrow.set(); view.cursorUpdate(with: hover(inside))
        precondition(controller.cursor(at: inside) == nil && NSCursor.current === NSCursor.arrow, "locked annotation must not receive selection hover cursors")
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
