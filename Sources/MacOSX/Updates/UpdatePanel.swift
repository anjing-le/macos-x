import AppKit

enum UpdatePanelProgress {
    case hidden
    case indeterminate
    case fraction(Double)
}

@MainActor
private final class UpdateFloatingPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
private final class UpdatePanelButton: MinimalButton {
    override var canBecomeKeyView: Bool {
        isEnabled && acceptsFirstResponder && !isHiddenOrHasHiddenAncestor && window?.canBecomeKey == true
    }
}

@MainActor
private final class UpdateUnderline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let line = NSBezierPath()
        line.move(to: CGPoint(x: 1, y: bounds.midY)); line.line(to: CGPoint(x: bounds.maxX - 1, y: bounds.midY))
        SketchPencil.stroke(line, color: SketchPalette.yellow, width: 2.5)
    }
}

@MainActor
private final class UpdatePanelContent: SketchSurface {
    let header = SketchWindowHeader(frame: .zero)
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let primary = UpdatePanelButton(title: "", target: nil, action: nil, style: .primary)
    let secondary = UpdatePanelButton(title: "", target: nil, action: nil, style: .quiet)
    let buttons = NSView()
    private let iconPlate = NSView()
    private let labels = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        header.compact = true; header.title = ""; addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 32)])
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true

        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: url)
        } else {
            icon.image = NSApp.applicationIconImage
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        iconPlate.wantsLayer = true
        iconPlate.layer?.cornerRadius = 12
        iconPlate.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = SketchPalette.heading(32)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = SketchPalette.heading(20)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.preferredMaxLayoutWidth = 306
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let accent = UpdateUnderline()
        accent.translatesAutoresizingMaskIntoConstraints = false
        accent.widthAnchor.constraint(equalToConstant: 130).isActive = true
        accent.heightAnchor.constraint(equalToConstant: 3).isActive = true
        for view in [titleLabel, accent, detailLabel] { labels.addArrangedSubview(view) }
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let header = NSStackView(views: [iconPlate, labels])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 22

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isDisplayedWhenStopped = true
        progress.usesThreadedAnimation = true

        for button in [primary, secondary] {
            button.setButtonType(.momentaryPushIn)
            button.font = SketchPalette.heading(23)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: button === primary ? 128 : 96).isActive = true
        }
        primary.keyEquivalent = "\r"
        let actions = NSStackView(views: [secondary, primary])
        actions.orientation = .horizontal
        actions.spacing = 16
        actions.alignment = .centerY
        buttons.addSubview(actions)
        actions.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, progress, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [iconPlate, labels, header, progress, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            iconPlate.widthAnchor.constraint(equalToConstant: 76),
            iconPlate.heightAnchor.constraint(equalToConstant: 76),
            icon.leadingAnchor.constraint(equalTo: iconPlate.leadingAnchor, constant: 7),
            icon.trailingAnchor.constraint(equalTo: iconPlate.trailingAnchor, constant: -7),
            icon.topAnchor.constraint(equalTo: iconPlate.topAnchor, constant: 5),
            icon.bottomAnchor.constraint(equalTo: iconPlate.bottomAnchor, constant: -5),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 4),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 48),
            actions.trailingAnchor.constraint(equalTo: buttons.trailingAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.leadingAnchor),
            actions.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
        detailLabel.isHidden = true
        progress.isHidden = true
        primary.isHidden = true
        secondary.isHidden = true
        buttons.isHidden = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    var preferredHeight: CGFloat {
        let headingHeight = max(76, labels.fittingSize.height)
        return 48 + headingHeight + (progress.isHidden ? 0 : 22)
            + (buttons.isHidden ? 0 : 66) + 24
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SketchPalette.paper.cgColor
            iconPlate.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = SketchPalette.ink
        }
    }
}

/// Presentation only; the update driver owns all update decisions and work.
@MainActor
final class UpdatePanel: NSWindowController, NSWindowDelegate {
    private let content = UpdatePanelContent(frame: NSRect(x: 0, y: 0, width: 460, height: 220))
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var closeAction: (() -> Void)?

    init() {
        let panel = UpdateFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.setFrame(NSRect(x: 0, y: 0, width: 460, height: 220), display: false)
        panel.appearance = NSAppearance(named: .aqua)
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = content
        super.init(window: panel)
        panel.delegate = self
        panel.onEscape = { [weak self] in self?.requestClose() }
        content.primary.target = self
        content.primary.action = #selector(primaryPressed)
        content.secondary.target = self
        content.secondary.action = #selector(secondaryPressed)
        panel.standardWindowButton(.closeButton)?.isEnabled = false
    }

    required init?(coder: NSCoder) { nil }

    func show(title: String, detail: String? = nil, progress: UpdatePanelProgress = .hidden,
              primaryTitle: String? = nil, primaryAction: (() -> Void)? = nil,
              secondaryTitle: String? = nil, secondaryAction: (() -> Void)? = nil,
              onClose: (() -> Void)? = nil) {
        guard let window else { return }
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        closeAction = onClose
        window.title = title
        content.titleLabel.stringValue = title
        updateDetail(detail)
        configure(content.primary, title: primaryTitle, enabled: primaryAction != nil)
        configure(content.secondary, title: secondaryTitle, enabled: secondaryAction != nil)
        content.buttons.isHidden = content.primary.isHidden && content.secondary.isHidden
        window.standardWindowButton(.closeButton)?.isEnabled = onClose != nil
        content.header.refreshActions()
        setProgress(progress)
        content.updateAppearance()
        window.setContentSize(NSSize(width: 460, height: content.preferredHeight))
        content.layoutSubtreeIfNeeded()
        window.recalculateKeyViewLoop()
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// A nil detail preserves the current status text.
    func setProgress(_ progress: UpdatePanelProgress, detail: String? = nil) {
        if let detail { updateDetail(detail) }
        content.progress.stopAnimation(nil)
        switch progress {
        case .hidden:
            content.progress.isHidden = true
        case .indeterminate:
            content.progress.isHidden = false
            content.progress.isIndeterminate = true
            content.progress.startAnimation(nil)
        case .fraction(let value):
            content.progress.isHidden = false
            content.progress.isIndeterminate = false
            content.progress.doubleValue = value.isFinite ? min(1, max(0, value)) : 0
        }
        if let window, abs((window.contentView?.bounds.height ?? 0) - content.preferredHeight) > 0.5 {
            window.setContentSize(NSSize(width: 460, height: content.preferredHeight))
        }
    }

    func focus() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Programmatic dismissal never invokes a cancellation callback.
    func dismiss() {
        content.progress.stopAnimation(nil)
        window?.orderOut(nil)
        primaryAction = nil
        secondaryAction = nil
        closeAction = nil
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        content.header.refreshActions()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestClose()
        return false
    }

    private func requestClose() {
        guard let action = closeAction else { return }
        dismiss()
        action()
    }

    @objc private func primaryPressed() {
        guard content.primary.isEnabled else { return }
        primaryAction?()
    }

    @objc private func secondaryPressed() {
        guard content.secondary.isEnabled else { return }
        secondaryAction?()
    }

    private func configure(_ button: NSButton, title: String?, enabled: Bool) {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        button.title = title
        button.isHidden = title.isEmpty
        button.isEnabled = enabled && !title.isEmpty
        button.setAccessibilityLabel(title)
    }

    private func updateDetail(_ detail: String?) {
        let text = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        content.detailLabel.stringValue = text
        content.detailLabel.isHidden = text.isEmpty
    }
}
