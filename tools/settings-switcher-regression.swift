import AppKit
import ApplicationServices
import MacOSXCore

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
        print("PASS settings/switcher: offscreen AppKit scrolling, 256 windows, <=16 reusable buttons, final page and three bundled guides; no live windows, capture, TCC or preferences")
    }
}
