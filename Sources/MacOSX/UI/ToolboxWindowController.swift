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

/// Home entries are the explicit opt-in boundary for native modules.
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
    private let detailDocument = DetailDocument()

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
        detail.spacing = 20
        detailDocument.addSubview(detail)
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
            ? NSColor(srgbRed: 0.105, green: 0.105, blue: 0.11, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.985, alpha: 1)).cgColor
    }

    func showCards(_ cards: [ToolCard]) {
        clearDetail()
        scroll.documentView = grid
        grid.setCards(cards)
        scroll.contentView.scroll(to: .zero)
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.recalculateKeyViewLoop()
    }

    func showDetail(_ views: [NSView]) {
        grid.setCards([])
        clearDetail()
        scroll.documentView = detailDocument
        views.forEach(detail.addArrangedSubview)
        scroll.contentView.scroll(to: .zero)
        needsLayout = true
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
        let width = scroll.contentView.bounds.width
        let height = scroll.contentView.bounds.height
        if scroll.documentView === grid {
            grid.arrange(width: width, minimumHeight: height)
        } else {
            let inset: CGFloat = width < 480 ? 24 : 36
            let contentWidth = max(220, min(480, width - inset * 2))
            detail.frame = NSRect(x: inset, y: inset, width: contentWidth, height: max(0, detail.fittingSize.height))
            detail.layoutSubtreeIfNeeded()
            let contentHeight = detail.fittingSize.height
            detail.frame.size.height = contentHeight
            detailDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(height, contentHeight + inset * 2))
        }
    }
}

@MainActor
private final class DetailDocument: NSView { override var isFlipped: Bool { true } }

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
    private let modules: ModuleCoordinator
    private var settingsHeader: ModuleSettingsHeader?

    init(modules: ModuleCoordinator, onCheckUpdates: @escaping () -> Void, canCheckUpdates: @escaping () -> Bool) {
        self.modules = modules
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
        modules.onStateChanged = { [weak self] tool in
            guard let self, case let .settings(current) = self.page, current == tool else { return }
            self.settingsHeader?.refresh()
            self.content.needsLayout = true
        }
        modules.onScreenCapturePermissionNeeded = { [weak self] in
            guard let self, self.added.tools.contains(.capture) else { return }
            self.showSettings(.capture)
            self.present()
        }
        modules.reconcile(added.tools)
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
        settingsHeader = nil
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
                self.modules.reconcile(self.added.tools)
                self.showHome()
            }
        })
    }

    private func showSettings(_ tool: Tool) {
        navigate(.settings(tool), title: tool.title)
        let header = ModuleSettingsHeader(tool: tool, module: modules)
        settingsHeader = header
        var views: [NSView] = [header]
        switch tool {
        case .kaomoji: views.append(modules.shortcutPicker(.wheel))
        case .capture:
            for action in [ShortcutAction.capture, .pin, .togglePins, .recording] { views.append(modules.shortcutPicker(action)) }
        case .windowSwitcher:
            let shortcut = NSTextField(labelWithString: "⌘Tab  ·  ⇧ 反向  ·  松开切换")
            shortcut.font = .systemFont(ofSize: 12); shortcut.textColor = .secondaryLabelColor
            views.append(shortcut)
        }
        views.append(modules.settingsView(for: tool))
        let remove = MinimalButton(title: "移除", target: self, action: #selector(removeCurrentTool), style: .quiet)
        remove.font = .systemFont(ofSize: 12)
        remove.toolTip = "从首页移除这张卡片"
        views.append(remove)
        content.showDetail(views)
    }

    @objc private func goBack() { showHome() }

    @objc private func removeCurrentTool() {
        guard case let .settings(tool) = page else { return }
        added.remove(tool)
        modules.reconcile(added.tools)
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
            let button = MinimalButton(title: "", target: self, action: #selector(goBack), style: .quiet)
            button.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "返回")
            button.imagePosition = .imageOnly
            button.toolTip = "返回首页"
            button.setAccessibilityLabel("返回首页")
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            item.view = button
        } else if identifier == Self.updatesID {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
            let button = MinimalButton(title: version, target: self, action: #selector(checkUpdates), style: .quiet)
            button.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: "检查更新")
            button.imagePosition = .imageTrailing
            button.font = .systemFont(ofSize: 12)
            button.toolTip = "检查更新…"
            button.setAccessibilityLabel("检查更新，当前版本 \(version)")
            item.label = "检查更新"
            item.view = button
        } else { return nil }
        return item
    }
}
