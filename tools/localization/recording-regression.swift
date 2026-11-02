import AppKit
import MacOSXCore
@main struct RecordingLocalizationRegression {
    @MainActor static func main() {
        _ = NSApplication.shared
        let suite="cc.anjing.macos-x.localized-recording."+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let bar=RecordingStartBar(target:nil,start:#selector(NSResponder.insertNewline(_:)),cancel:#selector(NSResponder.cancelOperation(_:)),defaults:defaults)
        for width:CGFloat in [220,282,360] {
            bar.frame=CGRect(x:0,y:0,width:width,height:108);bar.layoutSubtreeIfNeeded()
            for button in [bar.startButton,bar.cancelButton,bar.systemAudioButton,bar.microphoneButton] {
                let gutter:CGFloat=button is MinimalToggle ? 44 : 8
                let text=(button.title as NSString).size(withAttributes:[.font:button.font!]).width
                precondition(text+gutter<=button.frame.width,"Recording button text fits: "+button.title)
                precondition(bar.bounds.contains(button.frame))
            }
            for label in bar.subviews.compactMap({$0 as? NSTextField}).filter({!$0.isHidden}) {
                precondition((label.stringValue as NSString).size(withAttributes:[.font:label.font!]).width<=label.frame.width)
            }
        }
        print("PASS localized recording controls: full button labels at 220/282/360 pt; isolated preferences, no capture or live windows")
    }
}
