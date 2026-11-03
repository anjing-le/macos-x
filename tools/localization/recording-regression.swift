import AppKit
import MacOSXCore
@MainActor private final class RecordingFixturePanel: NSPanel {
    override var canBecomeKey:Bool { true }
}
@MainActor private final class RecordingReceiver: NSObject {
    var starts=0,cancels=0
    @objc func start(_ sender:Any?) { starts += 1 }
    @objc func cancel(_ sender:Any?) { cancels += 1 }
}
@main struct RecordingLocalizationRegression {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance=NSAppearance(named:.aqua)
        let suite="cc.anjing.macos-x.localized-recording."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let receiver=RecordingReceiver()
        let bar=RecordingStartBar(target:receiver,start:#selector(RecordingReceiver.start(_:)),cancel:#selector(RecordingReceiver.cancel(_:)),defaults:defaults)
        precondition(!bar.optionsExpanded && bar.subviews.filter{!$0.isHidden}.count == 1,"Only one start button is present at rest")
        precondition(bar.qualityButtons[2].state == .on,"Default quality remains 4K")
        bar.focusOptions()
        bar.qualityButtons[1].performClick(nil)
        precondition(RecordingQuality.load(from:defaults) == .high && bar.qualityButtons.filter{$0.state == .on}.count == 1)
        bar.systemAudioButton.performClick(nil)
        precondition(RecordingAudioOptions(defaults:defaults).system && receiver.starts == 0,"Adjusting options does not start recording")
        bar.qualityButtons[2].performClick(nil)
        precondition(RecordingAudioOptions(defaults:defaults).system && RecordingQuality.load(from:defaults) == .ultra,"Quality does not change audio")
        bar.qualityButtons[1].performClick(nil)
        let reopened=RecordingStartBar(target:nil,start:#selector(NSResponder.insertNewline(_:)),cancel:#selector(NSResponder.cancelOperation(_:)),defaults:defaults)
        precondition(reopened.qualityButtons[1].state == .on && reopened.systemAudioButton.state == .on,"Reopening restores quality and audio")
        for width:CGFloat in [220,282,360] {
            bar.frame=CGRect(x:0,y:0,width:width,height:RecordingStartBar.expandedSize.height);bar.layoutSubtreeIfNeeded()
            let buttons=[bar.startButton,bar.cancelButton,bar.systemAudioButton,bar.microphoneButton]+bar.qualityButtons
            for button in buttons {
                let gutter:CGFloat=button is MinimalToggle ? 44 : 8
                let text=(button.title as NSString).size(withAttributes:[.font:button.font!]).width
                precondition(text+gutter<=button.frame.width,"Recording button text fits: "+button.title)
                precondition(bar.bounds.contains(button.frame))
                for other in buttons where other !== button { precondition(!button.frame.intersects(other.frame),"Actions do not overlap") }
            }
            if width == 282 { render(bar,name:"expanded") }
        }
        // A real offscreen native window owns the resizing and focus; never order it on the user's desktop.
        let fullFrame=CGRect(x:500,y:500,width:282,height:140)
        let panel=RecordingFixturePanel(contentRect:fullFrame,styleMask:.borderless,backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.contentView=bar
        bar.autoresizingMask=[.width,.height]
        bar.onExpansionChanged = { expanded in
            panel.setFrame(RecordingStartBar.presentationFrame(expanded:expanded,in:fullFrame),display:false)
        }
        bar.resetPresentation()
        panel.setFrame(RecordingStartBar.presentationFrame(expanded:false,in:fullFrame),display:false)
        bar.layoutSubtreeIfNeeded();render(bar,name:"collapsed")
        let initialButton=panel.convertToScreen(bar.convert(bar.startButton.frame,to:nil))
        let move=NSEvent.mouseEvent(with:.mouseMoved,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,eventNumber:0,clickCount:0,pressure:0)!
        var pointer=CGPoint(x:fullFrame.midX,y:fullFrame.maxY-20)
        bar.pointerLocation={pointer}
        bar.mouseEntered(with:move);bar.layoutSubtreeIfNeeded()
        precondition(bar.optionsExpanded && panel.frame == fullFrame)
        precondition(initialButton == panel.convertToScreen(bar.convert(bar.startButton.frame,to:nil)),"Start target does not jump when expanding")
        bar.mouseExited(with:move)
        try await Task.sleep(nanoseconds:400_000_000)
        precondition(bar.optionsExpanded,"Stale exit events while crossing the button/options keep the tray open")
        pointer=CGPoint(x:0,y:0);bar.mouseExited(with:move)
        try await Task.sleep(nanoseconds:80_000_000)
        bar.mouseEntered(with:move)
        try await Task.sleep(nanoseconds:350_000_000)
        precondition(bar.optionsExpanded,"Re-entry cancels dismissal")
        bar.mouseExited(with:move)
        try await Task.sleep(nanoseconds:400_000_000)
        precondition(!bar.optionsExpanded && panel.frame.size == RecordingStartBar.collapsedSize,"Leaving returns to the single button")
        let tab=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48)!
        bar.startButton.keyDown(with:tab)
        precondition(bar.optionsExpanded && panel.firstResponder === bar.qualityButtons[0],"Tab expands and focuses native quality choices")
        bar.mouseExited(with:move)
        try await Task.sleep(nanoseconds:350_000_000)
        precondition(bar.optionsExpanded,"Keyboard options remain available without pointer hover")
        precondition(bar.qualityButtons.last?.nextKeyView === bar.systemAudioButton && bar.cancelButton.nextKeyView === bar.startButton)
        panel.selectNextKeyView(bar.qualityButtons[0])
        precondition(panel.firstResponder === bar.qualityButtons[1],"Native Tab order advances through quality choices")
        panel.makeFirstResponder(bar.startButton)
        panel.selectPreviousKeyView(bar.startButton)
        precondition(panel.firstResponder === bar.cancelButton,"Reverse Tab can reach cancel")
        bar.resetPresentation();precondition(!bar.optionsExpanded && panel.firstResponder === bar.startButton)
        precondition(bar.startButton.accessibilityPerformShowMenu())
        precondition(bar.optionsExpanded,"Accessibility can reveal the same options")
        bar.resetPresentation();bar.startButton.performClick(nil)
        precondition(receiver.starts == 1 && receiver.cancels == 0,"One click starts exactly once")
        bar.focusOptions();bar.cancelButton.performClick(nil)
        precondition(receiver.cancels == 1 && receiver.starts == 1)
        bar.resetPresentation();bar.mouseEntered(with:move);bar.mouseExited(with:move)
        NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:panel)
        try await Task.sleep(nanoseconds:350_000_000)
        precondition(!bar.optionsExpanded,"Closing cancels deferred work")
        bar.onExpansionChanged=nil;panel.close()
        for frame in [fullFrame,CGRect(x:-1500,y:-900,width:220,height:140),CGRect(x:0,y:0,width:282,height:140)] {
            let collapsed=RecordingStartBar.presentationFrame(expanded:false,in:frame)
            precondition(frame.contains(collapsed) && collapsed.midX == frame.midX && collapsed.maxY == frame.maxY,"Expanded options stay within pre-clamped screen bounds")
        }
        print("PASS localized recording tray: one-button idle, contiguous hover/leave/re-entry, fixed start target, keyboard/accessibility, native quality/audio persistence, single start/cancel, closure cancellation and 220/282/360 pt layouts; no live windows or capture")
    }
    @MainActor static func render(_ bar:RecordingStartBar,name:String) {
        guard let output=ProcessInfo.processInfo.environment["MACOSX_RECORDING_PREVIEW"],let bitmap=bar.bitmapImageRepForCachingDisplay(in:bar.bounds) else { return }
        bar.cacheDisplay(in:bar.bounds,to:bitmap)
        try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent("recording-hover-"+name+"-"+AppLanguage.current.rawValue+".png"))
    }
}
