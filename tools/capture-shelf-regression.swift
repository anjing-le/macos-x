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
    @MainActor static func event(_ type: NSEvent.EventType, _ point: CGPoint, view: NSView, key: UInt16? = nil, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        if let key { return NSEvent.keyEvent(with: .keyDown,location: .zero,modifierFlags: flags,timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,characters: key == 8 ? "c" : "",charactersIgnoringModifiers: key == 8 ? "c" : "",isARepeat: false,keyCode: key)! }
        if type == .mouseExited { return NSEvent.enterExitEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,eventNumber: 0,trackingNumber: 0,userData: nil)! }
        return NSEvent.mouseEvent(with: type,location: view.convert(point,to: nil),modifierFlags: [],timestamp: 0,windowNumber: view.window!.windowNumber,context: nil,eventNumber: 0,clickCount: 1,pressure: 1)!
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
        panel.expand(); precondition(panel.expanded && panel.frame.height == 184 && !panel.isVisible)
        let view = panel.shelfView
        var actions = [ShelfView.Action](); view.onAction = { actions.append($0) }
        let center = CGPoint(x: view.cardRect(0).midX,y: view.cardRect(0).midY)
        view.mouseDown(with: event(.leftMouseDown,center,view: view)); view.mouseUp(with: event(.leftMouseUp,center,view: view))
        guard case .pin(let clicked, nil) = actions.last else { preconditionFailure("Whole card opens pin") }; precondition(clicked == first.id)
        actions.removeAll()
        view.mouseDown(with: event(.leftMouseDown,center,view: view))
        let target = CGPoint(x: view.cardRect(1).midX,y: center.y)
        view.mouseDragged(with: event(.leftMouseDragged,target,view: view)); view.mouseExited(with: event(.mouseExited,target,view: view)); view.mouseUp(with: event(.leftMouseUp,target,view: view))
        guard case .move(let moved, 1) = actions.last else { preconditionFailure("Horizontal drag reorders, despite tracking exit") }; precondition(moved == first.id)
        actions.removeAll()
        view.mouseDown(with: event(.leftMouseDown,center,view: view))
        let below = CGPoint(x: center.x,y: 245)
        view.mouseDragged(with: event(.leftMouseDragged,below,view: view)); view.mouseUp(with: event(.leftMouseUp,below,view: view))
        guard case .pin(let pulled, .some) = actions.last else { preconditionFailure("Downward drag creates positioned pin") }; precondition(pulled == first.id)
        view.keyDown(with: event(.keyDown,.zero,view: view,key: 8,flags: .command))
        guard case .copy = actions.last else { preconditionFailure("Keyboard copy routes original image") }
        view.mouseMoved(with: event(.mouseMoved,center,view: view))
        guard case .preview = actions.last else { preconditionFailure("Hover requests a bounded preview") }
        precondition((view.accessibilityChildren()?.count ?? 0) >= fixture.count)
        view.mouseExited(with: event(.mouseExited,CGPoint(x: 50,y: 500),view: view))
        precondition(view.hovered == nil, "Leaving invalidates an in-flight hover preview")
        if let path = ProcessInfo.processInfo.environment["MACOSX_SHELF_PREVIEW"] {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds,to: bitmap)
            try bitmap.representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: path))
        }
        panel.collapse(); precondition(!panel.expanded && view.preview == nil)
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
        print("PASS shelf: original PNG persistence/restart, ordering, delete/undo, bounds, failed save, native hover/whole-card/drag/keyboard, hidden trigger and stop/restart; no shown windows, clipboard writes or installed preferences")
    }
}
