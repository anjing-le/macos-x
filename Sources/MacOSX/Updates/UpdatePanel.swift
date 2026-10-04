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
private final class UpdatePanelContent: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(wrappingLabelWithString: "")
    let progress = NSProgressIndicator()
    let primary = UpdatePanelButton(title: "", target: nil, action: nil, style: .primary)
    let secondary = UpdatePanelButton(title: "", target: nil, action: nil, style: .quiet)
    let buttons = NSView()
    private let iconPlate = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
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
        iconPlate.layer?.cornerRadius = 9
        iconPlate.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 19, weight: .medium)
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.preferredMaxLayoutWidth = 244
        for label in [titleLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let header = NSStackView(views: [iconPlate, labels])
        header.orientation = .horizontal
        header.distribution = .fill
        header.alignment = .centerY
        header.spacing = 12

        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isDisplayedWhenStopped = true
        progress.usesThreadedAnimation = true

        for button in [primary, secondary] {
            button.setButtonType(.momentaryPushIn)
            button.font = .systemFont(ofSize: 13, weight: button === primary ? .medium : .regular)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        primary.keyEquivalent = "\r"
        let actions = NSStackView(views: [secondary, primary])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.alignment = .centerY
        buttons.addSubview(actions)
        actions.translatesAutoresizingMaskIntoConstraints = false

        let space = NSView()
        let stack = NSStackView(views: [header, progress, space, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for view in [iconPlate, labels, header, progress, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            iconPlate.widthAnchor.constraint(equalToConstant: 36),
            iconPlate.heightAnchor.constraint(equalToConstant: 36),
            icon.leadingAnchor.constraint(equalTo: iconPlate.leadingAnchor, constant: 7),
            icon.trailingAnchor.constraint(equalTo: iconPlate.trailingAnchor, constant: -7),
            icon.topAnchor.constraint(equalTo: iconPlate.topAnchor, constant: 5),
            icon.bottomAnchor.constraint(equalTo: iconPlate.bottomAnchor, constant: -5),
            titleLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: labels.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 4),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 30),
            actions.trailingAnchor.constraint(equalTo: buttons.trailingAnchor),
            actions.leadingAnchor.constraint(greaterThanOrEqualTo: buttons.leadingAnchor),
            actions.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            space.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        detailLabel.isHidden = true
        progress.isHidden = true
        primary.isHidden = true
        secondary.isHidden = true
        buttons.isHidden = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            iconPlate.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.035).cgColor
            titleLabel.textColor = .labelColor
        }
    }
}

/// Presentation only; the update driver owns all update decisions and work.
@MainActor
final class UpdatePanel: NSWindowController, NSWindowDelegate {
    private let content = UpdatePanelContent(frame: NSRect(x: 0, y: 0, width: 340, height: 210))
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?
    private var closeAction: (() -> Void)?

    init() {
        let panel = UpdateFloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 210),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.setFrame(NSRect(x: 0, y: 0, width: 340, height: 210), display: false)
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
        setProgress(progress)
        content.updateAppearance()
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
