import AppKit
import ApplicationServices
import MacOSXCore

@MainActor final class BoardReceiver: NSObject {
    var calls=0
    @objc func changed(_ sender: AnyObject) { calls += 1 }
}
@main struct SettingsSwitcherRegression {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let layout = SwitcherLayout(windowCount: 256, available: CGSize(width: 1440, height: 900), presentation: .all)
        let canvas = SwitcherCanvas()
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: layout.size.height - 38)))
        scroll.hasVerticalScroller = true; scroll.scrollerStyle = .overlay
        canvas.frame = CGRect(origin: .zero, size: CGSize(width: layout.size.width, height: layout.pageSize(visibleCount: 256).height - 38))
        scroll.documentView = canvas
        let windows = (1...256).map {
            SwitcherWindow(id: UInt32($0), pid: getpid(), title: "窗口 \($0)", applicationName: "测试应用",
                icon: nil, element: AXUIElementCreateApplication(getpid()), isMinimized: false, isHidden: false, isOnScreen: true)
        }
        canvas.configure(windows, 1, layout, [:])
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: message, code: 1) }
        }
        for index in [0, 8, 127, 255, 0] {
            canvas.scrollToVisible(layout.card(at: index))
            scroll.reflectScrolledClipView(scroll.contentView)
            canvas.updateChoices()
            try require(canvas.visibleWindows.contains { $0.id == UInt32(index + 1) }, "selected window must be visible after scrolling")
            try require(canvas.visibleWindows.count <= 16, "viewport thumbnail requests must stay bounded")
            try require(canvas.subviews.compactMap { $0 as? NSButton }.count <= 16, "reuse only visible choice buttons")
            let visibleButtons = canvas.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
            try require(Set(visibleButtons.map(\.tag)) == Set(canvas.visibleWindows.map { Int($0.id) }), "mouse choices must follow scrolled windows")
        }
        let pageLayout = SwitcherLayout(windowCount: 11, available: CGSize(width: 1440, height: 900))
        let lastPage = pageLayout.pageSize(visibleCount: 3)
        canvas.removeFromSuperview()
        canvas.frame = CGRect(origin: .zero, size: lastPage)
        canvas.configure(Array(windows.prefix(11)), 11, pageLayout, [:])
        try require(canvas.page.map(\.id) == [9, 10, 11], "last two-row page preserves remaining windows")
        let output = ProcessInfo.processInfo.environment["MACOSX_SETTINGS_PREVIEW"]
        for kind in ["capture", "windowSwitcher", "kaomoji"] {
            let guide = SettingsGuideView(kind: kind)
            guide.layoutSubtreeIfNeeded()
            try require(guide.subviews.compactMap { $0 as? NSImageView }.first?.image != nil, "all settings guide resources must load")
            if let output, let bitmap = guide.bitmapImageRepForCachingDisplay(in: guide.bounds) {
                guide.cacheDisplay(in: guide.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent(kind + ".png"))
            }
        }
        let receiver=BoardReceiver()
        let toggle=MinimalToggle(title:"贴图白光边缘",target:receiver,action:#selector(BoardReceiver.changed(_:)))
        toggle.identifier = .init("capture-pin-outline")
        let captureSettings=NSStackView(views:[toggle,NSTextField(labelWithString:"说明"),NSTextField(labelWithString:"保存到 ~/Movies/macos-x"),NSTextField(labelWithString:"最近录屏 · 播放 / Finder / 复制路径")])
        captureSettings.arrangedSubviews[1].identifier = .init("capture-pin-help")
        captureSettings.orientation = .vertical; captureSettings.alignment = .leading
        let mode=MinimalPopUpButton(); mode.addItems(withTitles:["两行", "全部"])
        mode.target=receiver; mode.action = #selector(BoardReceiver.changed(_:))
        let modeRow=NSStackView(views:[NSTextField(labelWithString:"展示方式"),mode])
        modeRow.identifier = .init("switcher-presentation-row")
        let switchSettings=NSStackView(views:[modeRow,MinimalToggle(title:"窗口缩略图",target:nil,action:nil),MinimalButton(title:"预览窗口切换",target:nil,action:nil,style:.quiet)])
        switchSettings.orientation = .vertical; switchSettings.alignment = .leading
        for (kind,settings) in [("capture",captureSettings),("windowSwitcher",switchSettings)] {
            for pass in 0...1 {
                let keys = kind == "capture" ? ["截图 · F1","贴图 · F3","显隐 · ⇧F3","录屏 · ⌃⌥R"] : ["⌘ Tab · 松开确认"]
                let board=SettingsBoardView(kind:kind,settings:settings,shortcuts:keys.map { NSTextField(labelWithString:$0) })
                let root=NSStackView(views:[NSTextField(labelWithString:"启用"),board])
                root.orientation = .vertical; root.alignment = .leading; root.spacing=12
                root.translatesAutoresizingMaskIntoConstraints=false
                board.widthAnchor.constraint(equalTo:root.widthAnchor).isActive=true
                root.frame=CGRect(x:24,y:24,width:912,height:root.fittingSize.height)
                root.layoutSubtreeIfNeeded()
                try require(abs(board.frame.width-912)<1,"board fills default client width with balanced margins")
                try require(root.fittingSize.height+48 <= 584,"common settings fit default client without outer scrolling")
                board.layoutSubtreeIfNeeded()
                let choices=board.subviews.compactMap { $0 as? IllustratedSettingChoice }.filter(\.isEnabled)
                try require(choices.count == 2,"exactly two live illustration choices")
                choices[1].performClick(nil)
                try require(choices[1].state == .on && choices[0].state == .off,"one selected illustration")
                try require(kind == "capture" ? toggle.state == .on : mode.indexOfSelectedItem == 1,"illustration updates source control")
                choices[0].performClick(nil)
                try require(choices[0].state == .on && choices[1].state == .off,"selection can be reversed")
                try require(board.subviews.filter { !$0.isHidden }.allSatisfy { board.bounds.contains($0.frame) },"board contents stay in viewport")
                if pass == 0, let output, let bitmap=board.bitmapImageRepForCachingDisplay(in:board.bounds) {
                    board.cacheDisplay(in:board.bounds,to:bitmap)
                    try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:output).appendingPathComponent(kind+"-board.png"))
                }
                settings.removeFromSuperview()
            }
        }
        try require(receiver.calls == 8,"each illustration selection sends exactly one action across reopening")
        print("PASS settings/switcher: offscreen AppKit scrolling, 256 windows, <=16 reusable buttons, final page, three bundled guides, direct illustration actions and reopening; no live windows, capture, TCC or preferences")
    }
}
