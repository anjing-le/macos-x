import AppKit
import MacOSXCore

@MainActor private final class AboutWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { performClose(sender) }
}

/// Static, on-demand content. Closing this window never stops any module.
@MainActor final class AboutWindowController: NSWindowController {
    private let presentWindow: @MainActor (NSWindow) -> Void
    private let openLink: @MainActor (URL) -> Void
    let content = AboutContent(frame: NSRect(x: 0, y: 0, width: 500, height: 580))
    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:],
         presentWindow: @escaping @MainActor (NSWindow) -> Void = {
             if !$0.isVisible { $0.center() }
             NSApp.activate(ignoringOtherApps: true); $0.makeKeyAndOrderFront(nil)
         }, openLink: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.presentWindow = presentWindow; self.openLink = openLink
        let window = AboutWindow(contentRect: content.frame,
                                 styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = AppLanguage.text("关于 macos-x")
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false; window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        window.contentView = content
        super.init(window: window)
        let version = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        content.version.stringValue = version.flatMap { version in build.map { AppLanguage.text("版本 {0} · 构建 {1}", version, $0) } }
            ?? AppLanguage.text("开发版本")
        content.author.target = self; content.author.action = #selector(showAuthor)
        content.project.target = self; content.project.action = #selector(showProject)
        window.layoutIfNeeded(); content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 500, height: content.preferredHeight))
    }
    required init?(coder: NSCoder) { nil }
    func present() { if let window { presentWindow(window) } }
    @objc private func showAuthor() { openLink(URL(string: "https://github.com/anjing-le")!) }
    @objc private func showProject() { openLink(URL(string: "https://github.com/anjing-le/macos-x")!) }
}

@MainActor final class AboutContent: SketchSurface {
    let header = SketchWindowHeader(frame: .zero)
    let version = NSTextField(labelWithString: "")
    let author = MinimalButton(title: AppLanguage.text("作者 GitHub"), target: nil, action: nil, style: .quiet)
    let project = MinimalButton(title: AppLanguage.text("项目与反馈"), target: nil, action: nil, style: .quiet)
    let paragraphs: [NSTextField]
    private let stack = NSStackView()
    var preferredHeight: CGFloat { ceil(38 + 14 + stack.frame.height + 28) }
    override init(frame: NSRect) {
        paragraphs = [
            AppLanguage.text("让 Mac 上的常用操作，顺手一点。"),
            AppLanguage.text("截图贴图、窗口管理、菜单栏收纳、电脑状态、提示词与文件互传和处理。把日常需要的小工具，放在一起。"),
            AppLanguage.text("少一点打断，多一点专注"),
            AppLanguage.text("希望它安静地待在你需要的地方，少一些步骤，少占一些注意力，把时间留给真正想做的事。"),
            AppLanguage.text("来自作者的一点心意"),
            AppLanguage.text("我是 anjing-le，喜欢把日常的小麻烦做成顺手的工具。macos-x 也会从真实使用里的反馈出发，一点点打磨。谢谢你愿意使用它，也欢迎告诉我哪里还不好用。")
        ].map { NSTextField(wrappingLabelWithString: $0) }
        super.init(frame: frame)
        edge = nil; radius = 12
        header.compact = true; header.title = AppLanguage.text("关于 macos-x")
        addSubview(header); header.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        let identity = NSStackView(); identity.orientation = .horizontal; identity.spacing = 16
        let icon = NSImageView(); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage
        icon.setAccessibilityLabel("macos-x")
        icon.widthAnchor.constraint(equalToConstant: 58).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 58).isActive = true
        let name = NSTextField(labelWithString: "macos-x"); name.font = SketchPalette.heading(30); name.textColor = SketchPalette.ink
        version.font = .systemFont(ofSize: 12); version.textColor = SketchPalette.muted
        let titles = NSStackView(views: [name, version]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 4
        identity.addArrangedSubview(icon); identity.addArrangedSubview(titles); stack.addArrangedSubview(identity)
        for (index, label) in paragraphs.enumerated() {
            let heading = index == 0 || index == 2 || index == 4
            label.font = heading ? SketchPalette.heading(index == 0 ? 20 : 17) : .systemFont(ofSize: 14)
            label.textColor = SketchPalette.ink; label.isSelectable = true
            label.maximumNumberOfLines = 0
            label.setContentCompressionResistancePriority(.required, for: .vertical)
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index == 1 || index == 3 { stack.setCustomSpacing(22, after: label) }
        }
        let links = NSStackView(views: [author, project]); links.spacing = 12; stack.addArrangedSubview(links)
        for button in [author, project] {
            let width = ceil((button.title as NSString).size(withAttributes: [.font: button.font!]).width) + 32
            button.widthAnchor.constraint(equalToConstant: width).isActive = true
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 38),
            stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 34),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -34),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -28)
        ])
    }
    required init?(coder: NSCoder) { nil }
}
