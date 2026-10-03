import AppKit

enum Tool: String, CaseIterable, Hashable {
    case capture
    case windowSwitcher
    case kaomoji

    var title: String {
        switch self {
        case .capture: return "截图录屏"
        case .windowSwitcher: return "窗口切换"
        case .kaomoji: return "颜文字"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "camera.viewfinder"
        case .windowSwitcher: return "macwindow.on.rectangle"
        case .kaomoji: return "face.smiling"
        }
    }
}

/// Adding an entry stores a choice, without constructing or running a module.
@MainActor
private final class AddedTools {
    private let defaults: UserDefaults
    private let key = "addedTools"
    private(set) var tools: [Tool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var seen = Set<Tool>()
        tools = (defaults.stringArray(forKey: key) ?? [])
            .compactMap(Tool.init(rawValue:))
            .filter { seen.insert($0).inserted }
    }

    func add(_ tool: Tool) {
        guard !tools.contains(tool) else { return }
        tools.append(tool)
        save()
    }

    func remove(_ tool: Tool) {
        tools.removeAll { $0 == tool }
        save()
    }

    private func save() {
        defaults.set(tools.map(\.rawValue), forKey: key)
    }
}

@MainActor
private final class CardGrid: NSView {
    override var isFlipped: Bool { true }
    private var cards: [ToolCard] = []

    func setCards(_ cards: [ToolCard]) {
        self.cards.forEach { $0.removeFromSuperview() }
        self.cards = cards
        cards.forEach { addSubview($0) }
    }

    func arrange(width: CGFloat, minimumHeight: CGFloat) {
        let inset: CGFloat = width < 420 ? 24 : 36
        let gap: CGFloat = 16
        let cardWidth = min(200, max(100, width - inset * 2))
        let cardHeight: CGFloat = 156
        let columns = max(1, Int((width - inset * 2 + gap) / (cardWidth + gap)))
        let rows = (cards.count + columns - 1) / columns
        let contentHeight = inset * 2 + CGFloat(rows) * (cardHeight + gap) - (rows > 0 ? gap : 0)
        frame = NSRect(x: 0, y: 0, width: width, height: max(minimumHeight, contentHeight))
        for (index, card) in cards.enumerated() {
            card.frame = NSRect(
                x: inset + CGFloat(index % columns) * (cardWidth + gap),
                y: inset + CGFloat(index / columns) * (cardHeight + gap),
                width: cardWidth, height: cardHeight
            )
        }
    }
}

@MainActor
private final class ToolboxContent: NSView {
    let grid = CardGrid()
    private let scroll = NSScrollView()
    private let detail = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 24
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            detail.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -36)
        ])
        detail.isHidden = true
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = (dark
            ? NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.13, alpha: 1)
            : NSColor(calibratedRed: 1, green: 0.992, blue: 0.996, alpha: 1)).cgColor
    }

    func showCards(_ cards: [ToolCard]) {
        clearDetail()
        detail.isHidden = true
        scroll.isHidden = false
        grid.setCards(cards)
        scroll.contentView.scroll(to: .zero)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
    }

    func showDetail(_ views: [NSView]) {
        grid.setCards([])
        clearDetail()
        scroll.isHidden = true
        detail.isHidden = false
        views.forEach(detail.addArrangedSubview)
        layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
    }

    private func clearDetail() {
        detail.arrangedSubviews.forEach {
            detail.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    override func layout() {
        super.layout()
        guard !scroll.isHidden else { return }
        grid.arrange(width: scroll.contentView.bounds.width, minimumHeight: scroll.contentView.bounds.height)
    }
}

@MainActor
final class ToolboxWindowController: NSWindowController, NSToolbarDelegate {
    private enum Page {
        case home, catalog, settings(Tool)
    }

    private static let backID = NSToolbarItem.Identifier("back")
    private static let updatesID = NSToolbarItem.Identifier("updates")
    private let added = AddedTools()
    private let content = ToolboxContent(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    private var page: Page = .home
    private let onCheckUpdates: () -> Void
    private let canCheckUpdates: () -> Bool

    init(onCheckUpdates: @escaping () -> Void, canCheckUpdates: @escaping () -> Bool) {
        self.onCheckUpdates = onCheckUpdates
        self.canCheckUpdates = canCheckUpdates
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "macos-x"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.contentView = content
        window.toolbarStyle = .unifiedCompact
        window.center()
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "macos-x")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        showHome()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func navigate(_ page: Page, title: String) {
        self.page = page
        window?.title = title
        guard let toolbar = window?.toolbar else { return }
        let backIndex = toolbar.items.firstIndex { $0.itemIdentifier == Self.backID }
        if case .home = page {
            if let backIndex { toolbar.removeItem(at: backIndex) }
        } else if backIndex == nil {
            toolbar.insertItem(withItemIdentifier: Self.backID, at: 0)
        }
    }

    private func showHome() {
        navigate(.home, title: "macos-x")
        var cards = added.tools.map { tool in
            ToolCard(title: tool.title, symbol: tool.symbol) { [weak self] in
                self?.showSettings(tool)
            }
        }
        if added.tools.count < Tool.allCases.count {
            cards.append(ToolCard(title: "添加", symbol: "plus") { [weak self] in self?.showCatalog() })
        }
        content.showCards(cards)
    }

    private func showCatalog() {
        navigate(.catalog, title: "添加功能")
        content.showCards(Tool.allCases.filter { !added.tools.contains($0) }.map { tool in
            ToolCard(title: tool.title, symbol: tool.symbol) { [weak self] in
                guard let self else { return }
                self.added.add(tool)
                self.showHome()
            }
        })
    }

    private func showSettings(_ tool: Tool) {
        navigate(.settings(tool), title: tool.title)
        let pending = NSTextField(labelWithString: "功能待接入")
        pending.font = .systemFont(ofSize: 13)
        pending.textColor = .secondaryLabelColor
        let remove = NSButton(title: "移除", target: self, action: #selector(removeCurrentTool))
        remove.isBordered = false
        remove.font = .systemFont(ofSize: 13)
        remove.toolTip = "从首页移除这张卡片"
        content.showDetail([pending, remove])
    }

    @objc private func goBack() { showHome() }

    @objc private func removeCurrentTool() {
        guard case let .settings(tool) = page else { return }
        added.remove(tool)
        showHome()
    }

    @objc private func checkUpdates() {
        guard canCheckUpdates() else { return }
        onCheckUpdates()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.updatesID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.backID, .flexibleSpace, Self.updatesID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier == Self.backID {
            item.label = "返回"
            item.toolTip = "返回首页"
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回")
            item.target = self
            item.action = #selector(goBack)
        } else if identifier == Self.updatesID {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
            let button = NSButton(title: version, target: self, action: #selector(checkUpdates))
            button.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "检查更新")
            button.imagePosition = .imageTrailing
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.toolTip = "检查更新…"
            button.setAccessibilityLabel("检查更新，当前版本 \(version)")
            item.label = "检查更新"
            item.view = button
        } else { return nil }
        return item
    }
}
