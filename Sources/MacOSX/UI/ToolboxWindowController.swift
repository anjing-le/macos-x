import AppKit

enum Tool: String, CaseIterable, Hashable {
    case capture
    case windowSwitcher
    case kaomoji

    var title: String {
        switch self {
        case .capture: return "截图录屏"
        case .windowSwitcher: return "窗口切换"
        case .kaomoji: return "提示词库"
        }
    }

    var symbol: String {
        switch self {
        case .capture: return "camera.viewfinder"
        case .windowSwitcher: return "macwindow.on.rectangle"
        case .kaomoji: return "text.bubble"
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
    let header = SketchWindowHeader(frame: .zero)
    private let scroll = NSScrollView()
    private let detail = NSStackView()
    private let detailDocument = DetailDocument()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(header); header.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // This root stack is sized by layout(), not by an autoresizing-mask
        // constraint that pins its initial empty frame to zero.
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        detailDocument.addSubview(detail)
        updateBackground()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = SketchPalette.paper.cgColor
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
            let inset: CGFloat = 24
            let preferredWidth = max(480, detail.arrangedSubviews.map { $0.intrinsicContentSize.width }.max() ?? 480)
            let contentWidth = max(220, min(preferredWidth, width - inset * 2))
            detail.frame = NSRect(x: inset, y: inset, width: contentWidth, height: max(0, detail.fittingSize.height))
            detail.layoutSubtreeIfNeeded()
            let contentHeight = max(0, detail.fittingSize.height)
            detail.frame.size.height = contentHeight
            detailDocument.frame = NSRect(x: 0, y: 0, width: width, height: max(height, contentHeight + inset * 2))
        }
    }
}

@MainActor
private final class DetailDocument: SketchSurface {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); edge = nil; radius = 0 }
    required init?(coder: NSCoder) { nil }
}

@MainActor
final class ToolboxWindowController: NSWindowController {
    private enum Page {
        case home, catalog, settings(Tool)
    }

    func setUpdateAvailable(_ available: Bool) { content.header.setUpdateAvailable(available) }

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "macos-x"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = SketchPalette.paper
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 320)
        window.contentView = content
        window.toolbarStyle = .unifiedCompact
        window.center()
        super.init(window: window)
        content.header.onBack = { [weak self] in self?.goBack() }
        content.header.onUpdate = { [weak self] in self?.checkUpdates() }
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
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func navigate(_ page: Page, title: String) {
        self.page = page
        window?.title = title
        content.header.title = title
        if case .home = page { content.header.back.isHidden = true }
        else { content.header.back.isHidden = false }

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
        let shortcuts: [NSView]
        switch tool {
        case .kaomoji: shortcuts = [modules.shortcutPicker(.wheel)]
        case .capture: shortcuts = [ShortcutAction.capture, .pin, .togglePins, .recording].map { modules.shortcutPicker($0) }
        case .windowSwitcher:
            let label = NSTextField(labelWithString: "⌘ Tab\n松开确认 · ⇧ 反向")
            label.font = SketchPalette.heading(16); label.textColor = SketchPalette.ink
            shortcuts = [label]
        }
        let board = SettingsBoardView(kind: tool.rawValue, settings: modules.settingsView(for: tool), shortcuts: shortcuts)
        content.showDetail([header, board])
    }

    @objc private func goBack() { showHome() }

    @objc private func checkUpdates() {
        guard canCheckUpdates() else { return }
        onCheckUpdates()
    }

}
