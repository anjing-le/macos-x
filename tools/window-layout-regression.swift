import AppKit
import MacOSXCore

@MainActor private extension WindowLayoutModule {
    func verifyEscapeJourney(window:NSWindow) {
        enabled=true; target = .local(window,window.frame)
        verified=true; verifying=true; pendingAction = .left; preview=LayoutPreviewPanel()
        let frame=window.frame, before=generation
        let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,
            context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53)!
        receive(escape)
        precondition(target == nil && preview == nil && !verified && !verifying && pendingAction == nil && generation > before,
                     "Escape cancels drag preview and invalidates late target replies")
        let cancelled=generation; receive(escape)
        precondition(generation == cancelled && window.frame == frame,"Idle Escape is harmless and cancellation never applies a snap")
        stop()
    }
}

@main struct Check {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let window=NSWindow(contentRect:CGRect(x:70,y:60,width:700,height:450),styleMask:[.titled,.resizable],backing:.buffered,defer:false)
        window.minSize=CGSize(width:360,height:240)
        let original=window.frame
        let work=CGRect(x:0,y:25,width:1440,height:875)
        WindowLayoutNative.apply(window,frame:WindowLayoutGeometry.frame(for:.left,in:work)!)
        precondition(window.frame == CGRect(x:0,y:25,width:720,height:875))
        WindowLayoutNative.apply(window,frame:WindowLayoutGeometry.frame(for:.right,in:work)!)
        precondition(window.frame.minX == 720)
        WindowLayoutNative.apply(window,frame:WindowLayoutGeometry.frame(for:.top,in:work)!)
        precondition(window.frame.minY == 462 && window.frame.height == 438 && window.frame.width == 1440)
        WindowLayoutNative.apply(window,frame:WindowLayoutGeometry.frame(for:.bottom,in:work)!)
        precondition(window.frame.minY == 25 && window.frame.height == 437 && window.frame.width == 1440)
        WindowLayoutNative.apply(window,frame:original)
        precondition(window.frame == original)
        WindowLayoutNative.apply(window,frame:CGRect(x:0,y:0,width:200,height:100))
        precondition(window.frame.size == CGSize(width:360,height:240))
        let module=WindowLayoutModule()
        module.verifyEscapeJourney(window:window)
        let settings=module.settingsView
        settings.frame.size=CGSize(width:840,height:300); settings.layoutSubtreeIfNeeded()
        if let path=ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"],let bitmap=settings.bitmapImageRepForCachingDisplay(in:settings.bounds) {
            settings.cacheDisplay(in:settings.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).appendingPathComponent("window-layout.png"))
        }
        module.stop()
        print("PASS native layout: half areas, restoration, minimum sizes and isolated settings; no live AX, event listeners or installed preferences")
    }
}
