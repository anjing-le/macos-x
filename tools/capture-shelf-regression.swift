import AppKit
import ImageIO
import UniformTypeIdentifiers

// The native shelf is production code; only PNG encoding's dependency on the
// full capture editor is substituted. All data lives in a temporary directory.
enum CaptureEditor {
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(target,image,nil)
        return CGImageDestinationFinalize(target) ? data as Data : nil
    }
}
@main struct ShelfRegression {
    static func image(_ width: Int = 360, _ height: Int = 240, color: NSColor = .systemBlue, title: String = "截图") -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: width,pixelsHigh: height,bitsPerSample: 8,samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.withAlphaComponent(0.25).setFill(); CGRect(x: 0,y: 0,width: width,height: height).fill()
        if width > 100 {
            (title as NSString).draw(at: CGPoint(x: 22,y: height-55),withAttributes: [.font:NSFont.systemFont(ofSize: 24,weight: .medium),.foregroundColor:NSColor.darkGray])
            for line in 0..<4 { color.withAlphaComponent(0.45).setFill(); CGRect(x: 22,y: 30+line*27,width: width-44-line*22,height: 7).fill() }
        }
        NSGraphicsContext.restoreGraphicsState(); return bitmap.cgImage!
    }
    @MainActor static func event(_ type: NSEvent.EventType, _ point: CGPoint, view: NSView, key: UInt16? = nil, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        if let key { return NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: flags,timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,characters: key == 8 ? "c" : "",charactersIgnoringModifiers: key == 8 ? "c" : "",isARepeat: false,keyCode: key)! }
        if type == .mouseExited { return NSEvent.enterExitEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,eventNumber: 0,trackingNumber: 0,userData: nil)! }
        return NSEvent.mouseEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,eventNumber: 0,clickCount: clicks,pressure: 1)!
    }
    @MainActor static func waitForRopeTick(_ view:ShelfView, after time:Double) {
        let deadline=Date().addingTimeInterval(0.5)
        while view.motionTime <= time && Date() < deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
    }
    @MainActor static func motionPreview(_ panel:ShelfPanel, name:String) throws {
        guard let path=ProcessInfo.processInfo.environment["MACOSX_SHELF_PREVIEW"], let rail=panel.railView else { return }
        let width=panel.screenFrame.width, height:CGFloat=220
        let stage=NSImage(size:CGSize(width:width,height:height))
        stage.lockFocus()
        NSColor(calibratedWhite:0.93,alpha:1).setFill(); CGRect(x:0,y:0,width:width,height:height).fill()
        for (view,x) in [(rail,CGFloat(0)),(panel.shelfView as NSView,panel.frame.minX-panel.screenFrame.minX)] {
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            NSImage(cgImage:bitmap.cgImage!,size:view.bounds.size).draw(in:CGRect(x:x,y:height-view.bounds.height,width:view.bounds.width,height:view.bounds.height))
        }
        stage.unlockFocus()
        let data=NSBitmapImageRep(data:stage.tiffRepresentation!)!.representation(using:.png,properties:[:])!
        try data.write(to:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent(name+".png"))
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macos-x-shelf-test-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureShelfStore(directory: directory)
        let initiallyLoaded = try store.load(); precondition(initiallyLoaded.isEmpty)
        let first = try store.add(image(title: "设计草稿")), second = try store.add(image(color: .systemOrange,title: "待办事项")), third = try store.add(image(220,400,color: .systemGreen,title: "参考图片"))
        precondition(store.items.map(\.id) == [third.id,second.id,first.id])
        let restart = CaptureShelfStore(directory: directory); _ = try restart.load()
        precondition(restart.items == store.items && restart.image(first.id)?.width == 360)
        precondition(restart.image(first.id,maximum: 120)!.width == 120)
        let original = store.image(first.id)!
        precondition(original.dataProvider!.data! as Data == restart.image(first.id)!.dataProvider!.data! as Data, "Stored PNG retains original decoded pixels")
        try store.move(first.id,to: 0); precondition(store.items[0].id == first.id)
        try store.remove(second.id); precondition(!store.items.contains(second))
        try store.undo(); precondition(store.items[2].id == second.id)
        try store.remove(second.id); try store.remove(third.id)
        precondition(store.image(second.id) == nil, "Only one deleted image is retained for undo")
        try store.undo(); precondition(store.items.count == 2)
        let oversized = image(32_769,1)
        do { _ = try store.add(oversized); preconditionFailure("Dimension limit must reject") } catch {}
        let broken = CaptureShelfStore(directory: directory.appendingPathComponent("blocked"))
        try Data([1]).write(to: broken.directory)
        do { _ = try broken.add(image(8,8)); preconditionFailure("Failed persistence must not be reported as saved") } catch {}
        precondition(broken.items.isEmpty)
        let fixture = [first,second,third]
        let thumbs = Dictionary(uniqueKeysWithValues: fixture.map { item in (item.id,NSImage(cgImage: image(item.width,item.height,color: item.id == second.id ? .systemOrange : .systemBlue,title: item.id == first.id ? "设计草稿" : "参考图片"),size: .zero)) })
        guard let screen = NSScreen.screens.first else { preconditionFailure("Native display required") }
        let panel = ShelfPanel(screen: screen,records: fixture,thumbnails: thumbs,presenting: false)
        defer { panel.dispose() }
        panel.collapse(); precondition(panel.frame.height == 6 && !panel.isVisible)
        precondition(panel.railFrame.minX == screen.frame.minX && panel.railFrame.width == screen.frame.width && panel.railFrame.height == 6, "The idle rail spans the real screen, including negative origins")
        let initialRail = panel.railView as! ShelfRailView
        precondition(!initialRail.showsRope)
        let idleBitmap = initialRail.bitmapImageRepForCachingDisplay(in: initialRail.bounds)!
        initialRail.cacheDisplay(in: initialRail.bounds,to: idleBitmap)
        for y in 0..<idleBitmap.pixelsHigh { for x in stride(from: 0,to: idleBitmap.pixelsWide,by: 8) {
            precondition(idleBitmap.colorAt(x: x,y: y)!.alphaComponent < 0.01, "Idle rope is entirely invisible while its native tracking area remains installed")
        } }
        panel.expand(); precondition(panel.expanded && panel.frame.height == ShelfRope.detailHeight && !panel.isVisible)
        precondition(initialRail.showsRope, "Rope appears with hovered details")
        let view = panel.shelfView
        let resting=view.cardRect(0), anchorX=view.ropeOriginX+resting.midX
        panel.pullRope(anchorX:anchorX,offset:CGSize(width:120,height:80))
        precondition(!panel.hasRopeAnimation,"Holding the rope redraws only on pointer events")
        let pulled=view.cardRect(0)
        precondition(pulled.midX > resting.midX && pulled.midY > resting.midY,"A pull displaces the attached image as well as the rope")
        let anchor=ShelfRope.point(anchorX,width:view.ropeWidth,pull:initialRail.pull,time:initialRail.motionTime)
        precondition(abs(pulled.midX-(anchor.x-view.ropeOriginX))<0.01 && abs(pulled.minY-anchor.y-12)<0.01,"Clip, image and braided rope share the same deformed point")
        for edge in [CGFloat(0),view.ropeWidth] {
            let p=ShelfRope.point(edge,width:view.ropeWidth,pull:initialRail.pull,time:initialRail.motionTime)
            precondition(p == CGPoint(x:edge,y:3),"Rope ends remain fixed during a tug")
        }
        for fraction in [CGFloat(0.10),0.25,0.75,0.90] {
            let x=view.ropeWidth*fraction
            precondition(abs(initialRail.pose.point(x,width:view.ropeWidth).y-ShelfRope.y(x,width:view.ropeWidth))>1,
                         "The main rope changes across the screen, outside the photo container")
        }
        let wideBitmap=initialRail.bitmapImageRepForCachingDisplay(in:initialRail.bounds)!
        initialRail.cacheDisplay(in:initialRail.bounds,to:wideBitmap)
        let outside=initialRail.pose.point(view.ropeWidth*0.1,width:view.ropeWidth)
        let px=Int(outside.x*CGFloat(wideBitmap.pixelsWide)/initialRail.bounds.width)
        let py=Int(outside.y*CGFloat(wideBitmap.pixelsHigh)/initialRail.bounds.height)
        let visibleRope=(-3...3).contains { dy in (-3...3).contains { dx in
            wideBitmap.colorAt(x:px+dx,y:py+dy)!.alphaComponent > 0.1
        } }
        precondition(visibleRope,"The native rail redraws the displaced rope outside the photo area")
        try motionPreview(panel,name:"rope-pulled")
        panel.releaseRope(animated:true)
        precondition(panel.hasRopeAnimation)
        let rebound=panel.ropePull!, started=rebound.releasedAt!
        precondition(rebound.displacement(at:started+0.7).height < 0,"Release crosses rest position once before settling")
        precondition(abs(rebound.displacement(at:started+2.8).height)<1,"Oscillation decays rather than running forever")
        panel.advanceRope(at:started+0.35)
        for age in stride(from:0.0,through:ShelfRope.Pull.duration,by:0.1) {
            let pose=ShelfRope.Pose(pull:rebound,time:started+age)
            for x in stride(from:CGFloat(0),through:view.ropeWidth,by:32) {
                let point=pose.point(x,width:view.ropeWidth)
                precondition(point.y >= 0 && point.y < ShelfRope.height,"Full-width waves stay inside their narrow native surface")
            }
        }
        let early=initialRail.pose
        let late=ShelfRope.Pose(pull:rebound,time:started+0.75)
        let a=CGFloat(0.2), b=CGFloat(0.7)
        precondition(abs(early.heightOffset(a)*late.heightOffset(b)-early.heightOffset(b)*late.heightOffset(a))>0.005,
                     "Different screen positions have different wave phases, rather than scaling one static curve")
        precondition(abs(early.angle(anchorX,width:view.ropeWidth))>0.01,"Photos rotate gently about their attachment")
        let pivot=CGPoint(x:pulled.midX,y:pulled.minY+1)
        precondition(ShelfRope.rotate(pivot,around:pivot,angle:0.1) == pivot,"Swinging a photo never detaches its pivot")
        try motionPreview(panel,name:"rope-rebound")
        if ProcessInfo.processInfo.environment["MACOSX_SHELF_PROFILE"] == "1" {
            let surfaces:[NSView]=[initialRail,view]
            let bitmaps=surfaces.map { $0.bitmapImageRepForCachingDisplay(in:$0.bounds)! }
            var milliseconds=[Double]()
            for frame in 0..<60 {
                let began=ProcessInfo.processInfo.systemUptime
                panel.advanceRope(at:started+Double(frame)/20)
                for (surface,bitmap) in zip(surfaces,bitmaps) { surface.cacheDisplay(in:surface.bounds,to:bitmap) }
                milliseconds.append((ProcessInfo.processInfo.systemUptime-began)*1000)
            }
            milliseconds.sort()
            print(String(format:"Native rope + photos offscreen raster: %.0f pt screen, median %.2f ms, p95 %.2f ms (60 frames; excludes compositor)",view.ropeWidth,milliseconds[30],milliseconds[57]))
        }
        panel.advanceRope(at:started+ShelfRope.Pull.duration+0.01)
        try motionPreview(panel,name:"rope-rest")
        precondition(!panel.hasRopeAnimation && panel.ropePull == nil && view.cardRect(0) == resting,"Settling restores exact resting geometry and removes its timer")
        panel.pullRope(anchorX:anchorX,offset:CGSize(width:100,height:60))
        panel.releaseRope(animated:false)
        precondition(!panel.hasRopeAnimation && view.cardRect(0) == resting,"Reduced motion skips rebound")
        panel.pullRope(anchorX:anchorX,offset:CGSize(width:100,height:60)); panel.releaseRope(animated:true)
        panel.collapse()
        precondition(!panel.hasRopeAnimation && view.pull == nil && initialRail.pull == nil,"Collapse cancels both surfaces and releases animation")
        panel.expand()
        let ropeGrab=CGPoint(x:initialRail.bounds.width*0.1,y:ShelfRope.y(initialRail.bounds.width*0.1,width:initialRail.bounds.width))
        initialRail.mouseDown(with:event(.leftMouseDown,ropeGrab,view:initialRail))
        initialRail.mouseDragged(with:event(.leftMouseDragged,CGPoint(x:ropeGrab.x,y:ropeGrab.y+50),view:initialRail))
        precondition(panel.ropePull != nil && !panel.hasRopeAnimation,"The main rope itself can be tugged outside the photo area")
        initialRail.mouseUp(with:event(.leftMouseUp,ropeGrab,view:initialRail))
        panel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        let timerStart=ProcessInfo.processInfo.systemUptime
        panel.pullRope(anchorX:anchorX,offset:CGSize(width:90,height:80)); panel.releaseRope(animated:true)
        // Exercise a real scheduled callback, not just the deterministic model.
        let beforeTick=view.motionTime
        waitForRopeTick(view,after:beforeTick)
        precondition(view.motionTime > beforeTick,"The bounded animation actually advances on the native run loop")
        panel.advanceRope(at:timerStart+ShelfRope.Pull.duration+1)
        let disposeCheck=ShelfPanel(screen:screen,records:fixture,thumbnails:thumbs,presenting:false)
        disposeCheck.expand(); disposeCheck.pullRope(anchorX:anchorX,offset:CGSize(width:100,height:60)); disposeCheck.releaseRope(animated:true)
        disposeCheck.dispose()
        precondition(!disposeCheck.hasRopeAnimation && disposeCheck.ropePull == nil,"Disposal cancels an active rebound and releases its timer")
        panel.pullRope(anchorX:anchorX,offset:CGSize(width:50,height:50)); panel.releaseRope(animated:true)
        panel.advanceRope(at:panel.ropePull!.releasedAt!+0.35)
        let continuing=view.pose
        panel.pullRope(anchorX:anchorX,offset:.zero)
        for fraction in [CGFloat(0.1),0.5,0.9] {
            let x=view.ropeWidth*fraction
            let before=continuing.point(x,width:view.ropeWidth), after=view.pose.point(x,width:view.ropeWidth)
            precondition(hypot(before.x-after.x,before.y-after.y)<0.01,"Grabbing an already-swinging rope preserves its current shape")
        }
        panel.collapse(); panel.expand()
        var actions = [ShelfView.Action](); view.onAction = { actions.append($0) }
        let center = CGPoint(x: view.cardRect(0).midX,y: view.cardRect(0).midY)
        view.mouseDown(with: event(.leftMouseDown,center,view: view)); view.mouseUp(with: event(.leftMouseUp,center,view: view))
        guard case .preview(let clicked) = actions.last else { preconditionFailure("Whole card selects and previews without leaving keyboard interaction") }; precondition(clicked == first.id && view.selected == first.id)
        view.mouseDown(with: event(.leftMouseDown,center,view: view,clicks: 2)); view.mouseUp(with: event(.leftMouseUp,center,view: view,clicks: 2))
        guard case .pin(first.id, nil) = actions.last else { preconditionFailure("Double click opens a pin") }
        actions.removeAll()
        view.mouseDown(with: event(.leftMouseDown,center,view: view))
        let target = CGPoint(x: view.cardRect(1).midX,y: center.y)
        view.mouseDragged(with: event(.leftMouseDragged,target,view: view))
        precondition(panel.ropePull != nil && !panel.hasRopeAnimation,"Real dragging tugs the rope without starting a timer")
        try motionPreview(panel,name:"rope-drag")
        view.mouseExited(with: event(.mouseExited,target,view: view)); view.mouseUp(with: event(.leftMouseUp,target,view: view))
        guard case .move(let moved, 1) = actions.last else { preconditionFailure("Horizontal drag reorders, despite tracking exit") }; precondition(moved == first.id)
        panel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        actions.removeAll()
        view.mouseDown(with: event(.leftMouseDown,center,view: view))
        let below = CGPoint(x: center.x,y: 245)
        view.mouseDragged(with: event(.leftMouseDragged,below,view: view)); view.mouseUp(with: event(.leftMouseUp,below,view: view))
        guard case .pin(let pulled, .some) = actions.last else { preconditionFailure("Downward drag creates positioned pin") }; precondition(pulled == first.id)
        panel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        view.keyDown(with: event(.keyDown,.zero,view: view,key: 8,flags: .command))
        guard case .copy = actions.last else { preconditionFailure("Keyboard copy routes original image") }
        view.mouseMoved(with: event(.mouseMoved,CGPoint(x: view.cardRect(1).midX,y: center.y),view: view))
        guard case .preview = actions.last else { preconditionFailure("Hover requests a bounded preview") }
        precondition((view.accessibilityChildren()?.count ?? 0) >= fixture.count)
        view.mouseExited(with: event(.mouseExited,CGPoint(x: 50,y: 500),view: view))
        precondition(view.hovered == nil, "Leaving invalidates an in-flight hover preview")
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds,to: bitmap)
        for point in [CGPoint(x: 2,y: 2),CGPoint(x: view.bounds.width-2,y: 80),CGPoint(x: 4,y: view.bounds.height-4),CGPoint(x: 152,y: 60)] {
            let x = Int(point.x*CGFloat(bitmap.pixelsWide)/view.bounds.width), y = Int(point.y*CGFloat(bitmap.pixelsHigh)/view.bounds.height)
            precondition(bitmap.colorAt(x: x,y: y)!.alphaComponent < 0.01, "No surrounding paper, border, card padding or screen-wide backing")
        }
        let firstRect = view.cardRect(0)
        let borderPoint = CGPoint(x:firstRect.minX+44,y:firstRect.minY+2)
        let borderX = Int(borderPoint.x*CGFloat(bitmap.pixelsWide)/view.bounds.width)
        let borderY = Int(borderPoint.y*CGFloat(bitmap.pixelsHigh)/view.bounds.height)
        let borderColor = bitmap.colorAt(x: borderX,y: borderY)!.usingColorSpace(.deviceRGB)!
        precondition(borderColor.alphaComponent > 0.25 && borderColor.redComponent < 0.6, "Individual images have a visible dark pencil frame")
        if let path = ProcessInfo.processInfo.environment["MACOSX_SHELF_PREVIEW"] {
            try bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: path))
            let stage = NSImage(size: CGSize(width: 1280,height: 230))
            stage.lockFocus()
            NSColor(calibratedWhite: 0.90,alpha: 1).setFill(); CGRect(x: 0,y: 0,width: 1280,height: 230).fill()
            if let rail = panel.railView, let railBitmap = rail.bitmapImageRepForCachingDisplay(in: rail.bounds) {
                rail.cacheDisplay(in: rail.bounds,to: railBitmap)
                NSImage(cgImage: railBitmap.cgImage!,size: rail.bounds.size).draw(in: CGRect(x: 0,y: 230-ShelfRope.height,width: 1280,height: ShelfRope.height))
            }
            NSImage(cgImage: bitmap.cgImage!,size: view.bounds.size).draw(in: CGRect(x: (1280-view.bounds.width)/2,y: 230-view.bounds.height,width: view.bounds.width,height: view.bounds.height))
            stage.unlockFocus()
            let stageBitmap = NSBitmapImageRep(data: stage.tiffRepresentation!)!
            try stageBitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("rail-context.png"))
        }
        panel.pullRope(anchorX:anchorX,offset:CGSize(width:90,height:80)); panel.releaseRope(animated:true)
        panel.collapse(); precondition(!panel.expanded && view.preview == nil && !initialRail.showsRope && !panel.hasRopeAnimation)
        let lineView = panel.railView as! ShelfRailView
        let hiddenAgain = lineView.bitmapImageRepForCachingDisplay(in: lineView.bounds)!
        lineView.cacheDisplay(in: lineView.bounds,to: hiddenAgain)
        for y in 0..<hiddenAgain.pixelsHigh { for x in stride(from: 0,to: hiddenAgain.pixelsWide,by: 8) {
            precondition(hiddenAgain.colorAt(x: x,y: y)!.alphaComponent < 0.01, "Collapsing erases previously visible rope pixels")
        } }
        let enter = NSEvent.enterExitEvent(with: .mouseEntered,location: .zero,modifierFlags: [],timestamp: 0,windowNumber: lineView.window!.windowNumber,context: nil,eventNumber: 0,trackingNumber: 0,userData: nil)!
        lineView.mouseEntered(with: enter)
        for _ in 0..<100 { if panel.expanded { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(panel.expanded && panel.frame.width < panel.railFrame.width && !panel.isVisible, "Full-width line hover opens a detail window sized to its occupied slots")
        panel.collapse()
        lineView.mouseEntered(with: enter)
        lineView.mouseExited(with: enter)
        try await Task.sleep(nanoseconds: 240_000_000)
        precondition(!panel.expanded, "Leaving the line before reveal cancels the reveal")
        precondition(ShelfRope.y(0,width: 1512) == 3 && ShelfRope.y(756,width: 1512) == 17, "Rope sags naturally between screen edges")
        panel.beginKeyboardSelection()
        precondition(panel.keyboardSession && panel.expanded && !panel.isVisible)
        panel.scheduleCollapse(after: 0)
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(panel.expanded, "Keyboard selection persists when the pointer leaves")
        view.keyDown(with: event(.keyDown,.zero,view: view,key: 53))
        precondition(!panel.keyboardSession && !panel.expanded && !initialRail.showsRope, "Escape exits keyboard selection and hides the rope")
        panel.beginKeyboardSelection()
        panel.dismissFromKeyboard(pointer: CGPoint(x: panel.railFrame.midX,y: panel.railFrame.maxY-2))
        panel.hoverEntered()
        try await Task.sleep(nanoseconds: 240_000_000)
        precondition(!panel.expanded, "Escape does not reopen underneath a stationary pointer on the trigger")
        panel.triggerExited()
        let many = (0..<12).map { _ in CaptureShelfStore.Item(id: UUID(),width: 360,height: 240,bytes: 1) }
        let wide = ShelfView(records: many,thumbnails: [:])
        let wideWindow = NSPanel(contentRect: CGRect(x: 0,y: 0,width: 1512,height: ShelfRope.detailHeight),styleMask: [.borderless],backing: .buffered,defer: false)
        wideWindow.isReleasedWhenClosed = false; wideWindow.contentView = wide
        defer { wideWindow.close() }
        wide.expanded = true; wide.ropeWidth = 1512
        precondition(ShelfRope.capacity(wide.bounds.width) == 10)
        precondition(wide.cardRect(9).maxX < wide.bounds.width, "Use the screen width for ten slots instead of capping at six")
        let titles = (wide.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        precondition(!titles.contains("上一页") && !titles.contains("下一页"), "Continuous rope has no page buttons")
        var copied = 0; wide.onAction = { if case .copy = $0 { copied += 1 } }
        for _ in 0..<10 { wide.keyDown(with: event(.keyDown,.zero,view: wide,key: 124)) }
        precondition(wide.selected == many[10].id && wide.cardRect(10).maxX < wide.bounds.width && copied == 0, "Arrow selection scrolls only after the visible screen fills and never copies")
        wide.keyDown(with: event(.keyDown,.zero,view: wide,key: 8,flags: .command))
        precondition(copied == 1, "Command C explicitly copies the selected image")
        precondition(NSApp.sendAction(NSSelectorFromString("copy:"),to: wide,from: nil) && copied == 2, "Native Edit/Copy responder routes to the same selected image")
        for display in NSScreen.screens {
            let other = ShelfPanel(screen: display,records: fixture,thumbnails: thumbs,presenting: false)
            other.collapse(); precondition(other.railFrame.minX == display.frame.minX && other.railFrame.width == display.frame.width)
            other.dispose(); precondition(other.railFrame.isEmpty)
        }
        let host = CaptureShelf(directory: directory,presenting: false)
        host.start()
        for _ in 0..<100 { if host.canAdd { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(host.canAdd)
        host.setSuspended(true)
        let saved = await withCheckedContinuation { continuation in host.add(image(8,8)) { continuation.resume(returning: $0) } }
        precondition(saved)
        host.stop(); precondition(!host.canAdd)
        host.start()
        for _ in 0..<100 { if host.canAdd { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(host.canAdd); host.stop()
        print("PASS shelf: original PNG persistence/restart, ordering, delete/undo, bounds, failed save, native hover/whole-card/drag/keyboard, fixed-end rope tug, full-screen multimode wave, short attachments and pivot swing, bounded rebound/reduced motion, hidden trigger and stop/restart; no shown windows, clipboard writes or installed preferences")
    }
}
