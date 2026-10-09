import AppKit

@main struct EditorRegression {
    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let context = CaptureRaster.context(width: 200, height: 160)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let image = context.makeImage()!
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
        pinEntry.dispose()
        let region = CGRect(x: 20, y: 40, width: 100, height: 80)
        let editor = CaptureEditor(image: image, selectionFrame: region)
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
        editor.beginRegionAdjustment(); editor.beginRegionAdjustment()
        precondition(!editor.handleSelectionKey(key(18, "1")), "Pending crop cannot start a drawing tool")
        let next = before.offsetBy(dx: 20, dy: 10)
        editor.replaceSelectionImage(image, at: next)
        precondition(editor.selectionFrame == next && states.last == false, "Updated crop stays adjustable")
        precondition(!editor.window.isVisible, "Regression must not display windows")
        editor.close()
        let pin = CaptureEditor(image: image, selectionFrame: region, editingPin: true)
        pin.beginRegionAdjustment(); pin.replaceSelectionImage(image, at: next)
        precondition(pin.selectionFrame == region, "Pinned-image editing cannot recrop the desktop")
        pin.close()
        let activeExport = CaptureEditor(image: image, selectionFrame: CGRect(x: 0, y: 0, width: 200, height: 160))
        let activeCanvas = activeExport.window.contentView as! CaptureCanvas
        activeCanvas.tool = .pen
        func activeMouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: activeExport.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        activeCanvas.mouseDown(with: activeMouse(.leftMouseDown, CGPoint(x: 20, y: 40)))
        activeCanvas.mouseDragged(with: activeMouse(.leftMouseDragged, CGPoint(x: 100, y: 40)))
        var exported: CGImage?
        activeExport.onPin = { exported = $0 }
        activeExport.pinCurrentImage()
        precondition(!activeCanvas.inputEnabled, "Export locks canvas edits until completion")
        let deadline = Date().addingTimeInterval(4)
        while exported == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(exported != nil, "F3 resolves without displaying windows")
        precondition(CapturePixelSampler(image: exported!)!.sample(x: 40, y: 119)?.hex != "#FFFFFF", "F3 while dragging exports the current visible stroke")
        activeExport.close()
        print("PASS editor interaction: default adjustment, tool lock/toggle, Esc, pending crop, region replacement and pin isolation; no displayed windows, capture or clipboard writes")
    }
}
