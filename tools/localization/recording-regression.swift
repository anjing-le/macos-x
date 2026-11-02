import AppKit
import MacOSXCore
@main struct RecordingLocalizationRegression {
    @MainActor static func main() {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance=NSAppearance(named:.aqua)
        let suite="cc.anjing.macos-x.localized-recording."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let bar=RecordingStartBar(target:nil,start:#selector(NSResponder.insertNewline(_:)),cancel:#selector(NSResponder.cancelOperation(_:)),defaults:defaults)
        precondition(bar.qualityChoice.title == "4K", "Default quality is visible before recording")
        bar.qualityChoice.selectItem(at:1)
        precondition(NSApp.sendAction(bar.qualityChoice.action!,to:bar.qualityChoice.target,from:bar.qualityChoice))
        precondition(RecordingQuality.load(from:defaults) == .high)
        let reopened=RecordingStartBar(target:nil,start:#selector(NSResponder.insertNewline(_:)),cancel:#selector(NSResponder.cancelOperation(_:)),defaults:defaults)
        precondition(reopened.qualityChoice.title == "2K", "Opening again restores the chosen quality")
        for width:CGFloat in [220,282,360] {
            bar.frame=CGRect(x:0,y:0,width:width,height:148);bar.layoutSubtreeIfNeeded()
            precondition(bar.bounds.contains(bar.qualityChoice.frame) && !bar.qualityChoice.frame.intersects(bar.startButton.frame) && !bar.qualityChoice.frame.intersects(bar.systemAudioButton.frame))
            for button in [bar.startButton,bar.cancelButton,bar.systemAudioButton,bar.microphoneButton] {
                let gutter:CGFloat=button is MinimalToggle ? 44 : 8
                let text=(button.title as NSString).size(withAttributes:[.font:button.font!]).width
                precondition(text+gutter<=button.frame.width,"Recording button text fits: "+button.title)
                precondition(bar.bounds.contains(button.frame))
            }
            if width == 360, let output=ProcessInfo.processInfo.environment["MACOSX_RECORDING_PREVIEW"],let bitmap=bar.bitmapImageRepForCachingDisplay(in:bar.bounds) {
                bar.cacheDisplay(in:bar.bounds,to:bitmap)
                try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output).appendingPathComponent("recording-quality-"+AppLanguage.current.rawValue+".png"))
            }
            for label in bar.subviews.compactMap({$0 as? NSTextField}).filter({!$0.isHidden}) {
                precondition((label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width<=label.frame.width)
            }
        }
        print("PASS localized recording controls: full button labels at 220/282/360 pt; isolated preferences, no capture or live windows")
    }
}
