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
    @MainActor static func event(_ type: NSEvent.EventType, _ point: CGPoint, view: NSView, key: UInt16? = nil, flags: NSEvent.ModifierFlags = [], clicks: Int = 1, repeated: Bool = false) -> NSEvent {
        if let key { return NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: flags,timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,characters: key == 8 ? "c" : key == 6 ? "z" : "",charactersIgnoringModifiers: key == 8 ? "c" : key == 6 ? "z" : "",isARepeat: repeated,keyCode: key)! }
        if type == .mouseExited { return NSEvent.enterExitEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,eventNumber: 0,trackingNumber: 0,userData: nil)! }
        return NSEvent.mouseEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,eventNumber: 0,clickCount: clicks,pressure: 1)!
    }
    @MainActor static func waitForRopeTick(_ view:ShelfView, after time:Double) {
        let deadline=Date().addingTimeInterval(0.5)
        while view.motionTime <= time && Date() < deadline {
            RunLoop.current.run(until:Date().addingTimeInterval(0.01))
        }
    }
    @MainActor static func waitForReflow(_ view:ShelfView) {
        let deadline=Date().addingTimeInterval(0.6)
        while view.hasReflowAnimation && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        precondition(!view.hasReflowAnimation,"Real neighbour movement finishes and removes its animation timer")
    }
    @MainActor static func motionPreview(_ panel:ShelfPanel, name:String) throws {
        guard let path=ProcessInfo.processInfo.environment["MACOSX_SHELF_PREVIEW"], let rail=panel.railView else { return }
        let width=panel.screenFrame.width, height=max(CGFloat(220),panel.frame.height)
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
        let legacy=try JSONDecoder().decode(CaptureShelfStore.Item.self,from:Data("{\"id\":\"\(first.id.uuidString)\",\"width\":360,\"height\":240,\"bytes\":1}".utf8))
        precondition(legacy.positions == nil,"Existing image indexes require no destructive migration")
        let layoutStore=CaptureShelfStore(directory:directory.appendingPathComponent("positions"))
        let positioned=try (0..<3).map { _ in try layoutStore.add(image(10,10)) }
        let savedOrder=positioned.map(\.id)
        let desired=Dictionary(uniqueKeysWithValues:zip(savedOrder,[0.08,0.5,0.92]))
        try layoutStore.arrange(on:"display-a",order:savedOrder,positions:desired)
        let layoutRestart=CaptureShelfStore(directory:layoutStore.directory)
        let restored=try layoutRestart.load()
        precondition(restored.map(\.id) == savedOrder && restored.allSatisfy { $0.positions?["display-a"] == desired[$0.id] },"Free positions and order survive restart")
        try layoutStore.arrange(on:"display-b",order:savedOrder,positions:[savedOrder[0]:0.25])
        precondition(layoutStore.items[0].positions?["display-a"] == 0.08 && layoutStore.items[0].positions?["display-b"] == 0.25,"Each display keeps its own positions")
        let beforeInvalid=layoutStore.items
        do { try layoutStore.arrange(on:"display-a",order:savedOrder,positions:[savedOrder[0]:.nan]); preconditionFailure("Invalid position must fail") } catch {}
        do { try layoutStore.arrange(on:"display-a",order:[savedOrder[0],savedOrder[0],savedOrder[1]],positions:[:]); preconditionFailure("Duplicate order must fail") } catch {}
        precondition(layoutStore.items == beforeInvalid,"Invalid layout cannot alter saved data")
        let originalIndex=layoutStore.directory.appendingPathComponent("items.json")
        let indexBytes=try Data(contentsOf:originalIndex)
        try FileManager.default.removeItem(at:originalIndex)
        try FileManager.default.createDirectory(at:originalIndex,withIntermediateDirectories:false)
        do { try layoutStore.arrange(on:"display-a",order:savedOrder.reversed(),positions:[savedOrder[0]:0.75]); preconditionFailure("Blocked manifest must fail atomically") } catch {}
        precondition(layoutStore.items == beforeInvalid,"Failed disk write leaves order and all positions unchanged")
        try FileManager.default.removeItem(at:originalIndex); try indexBytes.write(to:originalIndex,options:.atomic)
        var geometry=CaptureShelfLayout(items:restored,display:"display-a",width:1512,cardWidth:132)
        let source=geometry.order[0], neighbour=geometry.order[1], oldSlot=geometry.centers[source]!
        precondition(geometry.drag(source,to:0.55) && geometry.order[1] == source && geometry.centers[neighbour] == oldSlot,"Crossed neighbours occupy the old slot during the drag")
        geometry.drop(source,at:0.97)
        precondition(geometry.centers[source]! > 0.9,"Drop position is independent of the center cluster or grid")
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
        var actions = [ShelfView.Action](); view.onAction = {
            actions.append($0)
            // Mock the async index acknowledgement; persistence is tested separately.
            if case .place = $0 { view.completeLayoutCommit() }
        }
        let center = CGPoint(x: view.cardRect(0).midX,y: view.cardRect(0).midY)
        view.mouseDown(with: event(.leftMouseDown,center,view: view)); view.mouseUp(with: event(.leftMouseUp,center,view: view))
        guard case .preview(let clicked) = actions.last else { preconditionFailure("Whole card selects and previews without leaving keyboard interaction") }; precondition(clicked == first.id && view.selected == first.id)
        view.mouseDown(with: event(.leftMouseDown,center,view: view,clicks: 2)); view.mouseUp(with: event(.leftMouseUp,center,view: view,clicks: 2))
        guard case .pin(first.id) = actions.last else { preconditionFailure("Double click opens a pin") }
        actions.removeAll()
        view.mouseDown(with: event(.leftMouseDown,center,view: view))
        let target = CGPoint(x: view.cardRect(1).midX,y: center.y)
        view.mouseDragged(with: event(.leftMouseDragged,target,view: view))
        precondition(actions.isEmpty && view.records[1].id == first.id,"Order changes before mouse-up, without a placeholder or disk commit")
        precondition(view.hasReflowAnimation,"Crossing a neighbour starts its visible movement")
        waitForReflow(view)
        let shifted=view.cardRect(0)
        precondition(abs(shifted.midX-center.x)<30,"The crossed neighbour visibly takes the vacated position")
        precondition(panel.ropePull != nil && !panel.hasRopeAnimation,"Real dragging tugs the rope without starting a timer")
        try motionPreview(panel,name:"rope-drag")
        view.mouseExited(with: event(.mouseExited,target,view: view)); view.mouseUp(with: event(.leftMouseUp,target,view: view))
        guard case .place(let moved,_,let order,let positions) = actions.last else { preconditionFailure("Horizontal drag commits position and order together") }
        precondition(moved == first.id && order[1] == first.id && positions[first.id] != nil)
        panel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        actions.removeAll()
        view.finishReflow()
        let movedRect=view.cardRect(view.records.firstIndex { $0.id == first.id }!)
        let movedCenter=CGPoint(x:movedRect.midX,y:movedRect.midY)
        view.mouseDown(with: event(.leftMouseDown,movedCenter,view: view))
        let below = CGPoint(x:movedCenter.x,y:245)
        view.mouseDragged(with: event(.leftMouseDragged,below,view: view)); view.mouseUp(with: event(.leftMouseUp,below,view: view))
        guard case .place(let pulled,_,_,_) = actions.last else { preconditionFailure("Downward dragging only commits the hanging position, never opens F3") }
        precondition(pulled == first.id && panel.expanded && panel.firstResponder === view, "Releasing a downward drag keeps the shelf and its selection responder available")
        precondition(!actions.contains { if case .pin = $0 { return true }; return false }, "Dragging never dispatches an implicit pin")
        panel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        precondition(view.performKeyEquivalent(with:event(.keyDown,.zero,view:view,key:8,flags:.command)), "Native Command-C is claimed by the shelf after dropping")
        guard case .copy = actions.last else { preconditionFailure("Keyboard copy routes original image") }
        view.mouseMoved(with:event(.mouseMoved,CGPoint(x:view.cardRect(0).midX,y:view.cardRect(0).midY),view:view))
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
        let selectedBorder=view.selected == view.records[0].id
        let expectedBorder = selectedBorder
            ? borderColor.blueComponent > borderColor.redComponent+0.08 && borderColor.blueComponent > borderColor.greenComponent+0.025
            : borderColor.redComponent < 0.6
        precondition(borderColor.alphaComponent > 0.25 && expectedBorder, "The real photo frame is blue when selected and pencil gray otherwise")
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
        precondition(panel.expanded && panel.frame.width == panel.railFrame.width && !panel.isVisible, "Full-width line hover opens the entire display span for free placement")
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
        panel.resignKey()
        precondition(panel.expanded && !panel.keyboardSession, "Losing keyboard focus ends selection without immediately hiding the shelf")
        panel.beginKeyboardSelection()
        panel.focusForInteraction()
        precondition(panel.expanded && !panel.keyboardSession, "Mouse interaction leaves persistent keyboard selection for delayed hover dismissal")
        panel.beginKeyboardSelection()
        view.keyboardPointer=CGPoint(x:-100000,y:-100000)
        view.mouseMoved(with:event(.mouseMoved,CGPoint(x:view.cardRect(0).midX,y:view.cardRect(0).midY),view:view))
        precondition(panel.expanded && !panel.keyboardSession, "Real pointer movement switches keyboard selection back to ordinary hover without hiding")
        panel.beginKeyboardSelection()
        panel.dismissFromKeyboard(pointer: CGPoint(x: panel.railFrame.midX,y: panel.railFrame.maxY-2))
        panel.hoverEntered()
        try await Task.sleep(nanoseconds: 240_000_000)
        precondition(!panel.expanded, "Escape does not reopen underneath a stationary pointer on the trigger")
        panel.triggerExited()
        // Actual one-shot dispatch callbacks with an injected pointer; never move
        // the user's real mouse or shorten the product's default grace period.
        let idlePanel=ShelfPanel(screen:screen,records:fixture,thumbnails:thumbs,presenting:false)
        defer { idlePanel.dispose() }
        var idlePointer=CGPoint(x:screen.frame.midX,y:screen.frame.minY+10)
        idlePanel.pointerLocation = { idlePointer }
        idlePanel.expand(); idlePanel.scheduleCollapse()
        try await Task.sleep(nanoseconds:550_000_000)
        precondition(idlePanel.expanded, "Leaving no longer dismisses in the former 0.45-second interval")
        idlePanel.scheduleCollapse(after:0.03)
        idlePanel.hoverEntered()
        try await Task.sleep(nanoseconds:60_000_000)
        precondition(idlePanel.expanded, "Re-entry cancels the previous scheduled dismissal")
        idlePointer=CGPoint(x:idlePanel.frame.midX,y:idlePanel.frame.midY)
        idlePanel.scheduleCollapse(after:0.02)
        try await Task.sleep(nanoseconds:50_000_000)
        precondition(idlePanel.expanded, "A stationary pointer inside the interaction area keeps the shelf open")
        idlePointer=CGPoint(x:screen.frame.midX,y:screen.frame.minY+10)
        idlePanel.scheduleCollapse(after:0.03)
        idlePanel.shelfView.copy(nil)
        try await Task.sleep(nanoseconds:70_000_000)
        precondition(idlePanel.expanded, "Copy resets an old outside-pointer deadline without requiring pointer re-entry")
        idlePanel.scheduleCollapse()
        try await Task.sleep(nanoseconds:UInt64((ShelfPanel.idleCollapseDelay+0.2)*1_000_000_000))
        precondition(!idlePanel.expanded, "Three seconds outside without interaction actually hides the shelf")
        idlePanel.expand(); idlePanel.scheduleCollapse(after:0.03)
        idlePanel.beginKeyboardSelection()
        try await Task.sleep(nanoseconds:60_000_000)
        precondition(idlePanel.expanded && idlePanel.keyboardSession, "Starting keyboard selection cancels an already pending pointer deadline")
        idlePanel.dismissFromKeyboard()
        precondition(ShelfRope.panelHeight(available:900,preview:true) > 420, "Large screens give the image more height than the former 420-point panel")
        precondition(ShelfRope.panelHeight(available:500,preview:true) == 500 && ShelfRope.panelHeight(available:900,preview:false) == ShelfRope.detailHeight,
                     "Preview fits a short display without enlarging the idle photo shelf")
        idlePanel.expand(preview:true); idlePanel.focusForInteraction()
        precondition(idlePanel.frame.maxY <= screen.visibleFrame.maxY && idlePanel.frame.minY >= screen.visibleFrame.minY+16,
                     "Expanded preview stays between the menu bar and Dock with bottom breathing room")
        idlePanel.shelfView.hovered=fixture[0].id; idlePanel.shelfView.preview=thumbs[fixture[0].id]
        try motionPreview(idlePanel,name:"shelf-preview-first")
        let boundaries=[CGPoint(x:idlePanel.railFrame.midX,y:idlePanel.railFrame.midY),
                        idlePanel.convertPoint(toScreen:CGPoint(x:idlePanel.frame.width/2,y:idlePanel.frame.height-110)),
                        CGPoint(x:idlePanel.frame.midX,y:idlePanel.frame.minY+60)]
        for pointer in boundaries {
            idlePointer=pointer
            precondition(idlePanel.containsInteraction(pointer), "Rope, photos and lower preview share the same interaction geometry")
            idlePanel.scheduleCollapse(after:0.02)
            idlePanel.shelfView.mouseExited(with:event(.mouseExited,CGPoint(x:10,y:10000),view:idlePanel.shelfView))
            idlePanel.triggerExited()
            try await Task.sleep(nanoseconds:45_000_000)
            precondition(idlePanel.expanded && idlePanel.shelfView.hovered == fixture[0].id && idlePanel.shelfView.preview != nil,
                         "Stale tracking exits between overlapping rope/detail/preview windows cannot clear selection or dismiss")
            precondition(idlePanel.firstResponder === idlePanel.shelfView, "Area transitions retain the native selection responder")
        }
        idlePanel.shelfView.keyDown(with:event(.keyDown,.zero,view:idlePanel.shelfView,key:124))
        idlePanel.shelfView.preview=idlePanel.shelfView.selected.flatMap { thumbs[$0] }
        try motionPreview(idlePanel,name:"shelf-preview-next")
        idlePanel.shelfView.select(fixture[2].id); idlePanel.collapse(); idlePanel.expand()
        precondition(idlePanel.shelfView.selected == idlePanel.shelfView.records.first?.id, "A fresh open defaults to the first visible picture")
        idlePanel.collapse()
        let freePanel=ShelfPanel(screen:screen,records:fixture,thumbnails:thumbs,presenting:false)
        defer { freePanel.dispose() }
        freePanel.expand()
        precondition(freePanel.frame.minX == screen.frame.minX && freePanel.frame.width == screen.frame.width,"The picture interaction window spans the entire current display")
        let free=freePanel.shelfView
        var savedLayoutItems:[CaptureShelfStore.Item]=fixture
        var placementSucceeds=true
        free.onAction = { action in
            if case .place(_,let display,let order,let positions)=action {
                let indexed=Dictionary(uniqueKeysWithValues:savedLayoutItems.map { ($0.id,$0) })
                if placementSucceeds {
                    savedLayoutItems=order.map { id in var item=indexed[id]!; var p=item.positions ?? [:]; p[display]=positions[id]; item.positions=p; return item }
                }
                free.applySavedItems(savedLayoutItems,preserveLayout:placementSucceeds)
            }
        }
        let freeStart=free.cardRect(free.records.firstIndex { $0.id == first.id }!)
        let startPoint=CGPoint(x:freeStart.midX,y:freeStart.midY)
        let farRight=CGPoint(x:free.bounds.width-85,y:startPoint.y)
        free.mouseDown(with:event(.leftMouseDown,startPoint,view:free))
        free.mouseDragged(with:event(.leftMouseDragged,farRight,view:free))
        free.mouseUp(with:event(.leftMouseUp,farRight,view:free))
        free.finishReflow(); freePanel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        let landed=free.cardRect(free.records.firstIndex { $0.id == first.id }!)
        precondition(abs(landed.midX-farRight.x)<1,"Dropping at the screen edge does not snap back into the old center cluster")
        try motionPreview(freePanel,name:"shelf-free-right")
        let restoredPanel=ShelfPanel(screen:screen,records:savedLayoutItems,thumbnails:thumbs,presenting:false)
        restoredPanel.expand()
        let restoredView=restoredPanel.shelfView
        let restoredRect=restoredView.cardRect(restoredView.records.firstIndex { $0.id == first.id }!)
        precondition(abs(restoredRect.midX-farRight.x)<1,"A recreated native shelf restores its display-relative coordinate")
        restoredPanel.dispose()
        let beforeCancel=free.records.map(\.id), previousX=landed.midX
        let left=CGPoint(x:85,y:landed.midY)
        free.mouseDown(with:event(.leftMouseDown,CGPoint(x:landed.midX,y:landed.midY),view:free))
        free.mouseDragged(with:event(.leftMouseDragged,left,view:free))
        try motionPreview(freePanel,name:"shelf-live-swap")
        freePanel.collapse(); freePanel.expand()
        precondition(free.records.map(\.id) == beforeCancel && !free.hasReflowAnimation,"Escape/collapse cancels live swaps and their animation")
        precondition(abs(free.cardRect(free.records.firstIndex { $0.id == first.id }!).midX-previousX)<1,"Cancellation preserves the committed free position")
        let committedStart=CGPoint(x:previousX,y:free.cardRect(free.records.firstIndex { $0.id == first.id }!).midY)
        free.mouseDown(with:event(.leftMouseDown,committedStart,view:free))
        free.mouseDragged(with:event(.leftMouseDragged,left,view:free))
        free.mouseUp(with:event(.leftMouseUp,left,view:free))
        free.finishReflow(); freePanel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        precondition(abs(free.cardRect(free.records.firstIndex { $0.id == first.id }!).midX-85)<1,"The left edge is also a free drop location")
        try motionPreview(freePanel,name:"shelf-free-left")
        placementSucceeds=false
        let failedStart=free.cardRect(free.records.firstIndex { $0.id == first.id }!)
        let failedTarget=CGPoint(x:free.bounds.midX,y:failedStart.midY)
        free.mouseDown(with:event(.leftMouseDown,CGPoint(x:failedStart.midX,y:failedStart.midY),view:free))
        free.mouseDragged(with:event(.leftMouseDragged,failedTarget,view:free))
        free.mouseUp(with:event(.leftMouseUp,failedTarget,view:free))
        freePanel.advanceRope(at:ProcessInfo.processInfo.systemUptime+ShelfRope.Pull.duration+1)
        precondition(abs(free.cardRect(free.records.firstIndex { $0.id == first.id }!).midX-85)<1,"Failed save restores the last acknowledged coordinate")
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
        // Exercise the real async delete/undo manager with real native windows,
        // while substituting only copy's sink to keep the user's clipboard intact.
        let actionDirectory=directory.appendingPathComponent("continuous-actions")
        let actionStore=CaptureShelfStore(directory:actionDirectory); _ = try actionStore.load()
        for _ in 0..<3 { _ = try actionStore.add(image(32,32)) }
        let oldWindows=Set(NSApp.windows.map(ObjectIdentifier.init))
        let actionHost=CaptureShelf(directory:actionDirectory,presenting:false)
        actionHost.start(); defer { actionHost.stop() }
        for _ in 0..<150 { if actionHost.canAdd { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(actionHost.canAdd && actionHost.showForKeyboard())
        let managed=NSApp.windows.compactMap { $0 as? ShelfPanel }.filter { !oldWindows.contains(ObjectIdentifier($0)) }
        guard let actionPanel=managed.first(where: { $0.expanded }) else { preconditionFailure("The host must expose a native keyboard shelf") }
        let actionView=actionPanel.shelfView, originalAction=actionPanel.shelfView.onAction
        let windowIdentity=ObjectIdentifier(actionPanel), initialIDs=actionView.records.map(\.id)
        let savedThumbnail=actionView.thumbnails[initialIDs[0]]!
        var copiedSelection:UUID?
        actionView.onAction = { action in
            if case .copy(let id) = action { copiedSelection=id } else { originalAction?(action) }
        }
        precondition(actionView.selected == initialIDs[0] && actionPanel.firstResponder === actionView, "Opening chooses the first image with native keyboard focus")
        actionView.select(initialIDs[1])
        let delete=event(.keyDown,.zero,view:actionView,key:51,flags:.command)
        precondition(actionView.performKeyEquivalent(with:delete), "Command-Backspace is consumed by the selected shelf")
        _ = actionView.performKeyEquivalent(with:delete)
        for _ in 0..<150 { if actionHost.canAdd { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(actionView.records.count == 2 && actionView.selected == initialIDs[2], "Delete selects the next neighbour; a busy repeat cannot delete a second stale target")
        precondition(ObjectIdentifier(actionView.window!) == windowIdentity && actionPanel.firstResponder === actionView && actionPanel.expanded,
                     "Async deletion updates the same window without dropping focus or visibility")
        precondition(actionView.thumbnails[initialIDs[0]] === savedThumbnail, "Deleting reuses unaffected thumbnails instead of decoding all images again")
        precondition(actionView.performKeyEquivalent(with:event(.keyDown,.zero,view:actionView,key:8,flags:.command)) && copiedSelection == initialIDs[2], "Copy immediately after deletion uses the new selection")
        _ = actionView.performKeyEquivalent(with:event(.keyDown,.zero,view:actionView,key:51,flags:.command,repeated:true))
        for _ in 0..<150 { if actionHost.canAdd { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(actionView.records.count == 1 && actionView.selected == initialIDs[0] && actionPanel.firstResponder === actionView, "Deleting the last position selects the previous item and accepts key repeat")
        _ = actionView.performKeyEquivalent(with:delete)
        for _ in 0..<150 { if actionHost.canAdd { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(actionView.records.isEmpty && actionView.selected == nil && actionPanel.expanded && actionPanel.firstResponder === actionView,
                     "An empty shelf retains its window and focus for undo, without inventing a selection")
        _ = actionView.performKeyEquivalent(with:event(.keyDown,.zero,view:actionView,key:6,flags:.command))
        for _ in 0..<150 { if actionHost.canAdd { break }; try await Task.sleep(nanoseconds:10_000_000) }
        precondition(actionView.records.count == 1 && actionView.selected != nil && actionPanel.firstResponder === actionView,
                     "Native Command-Z restores an image into the focused empty shelf")
        actionHost.stop()
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
        print("PASS shelf: original PNG persistence/restart, ordering, delete/undo, bounds, failed save, native hover/whole-card/drag/keyboard, drag-only placement and resettable three-second idle dismissal, unified rope/preview transitions, first selection and in-place continuous Command-Backspace/undo focus, fixed-end rope tug, full-screen free placement, live neighbour movement, per-display position persistence and rollback, full-screen multimode wave, short attachments and pivot swing, bounded rebound/reduced motion, hidden trigger and stop/restart; no shown windows, clipboard writes or installed preferences")
    }
}
