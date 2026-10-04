import AppKit
import MacOSXCore

/// A copy-only wheel. Shortcut registration belongs to the application input owner.
@MainActor
final class PhraseWheelModule {
    private static let storageKey = "phraseWheel.slots"
    private static let characterLimit = 4096
    private static let presets = [
        "(๑•̀ㅂ•́)و✧", "(≧▽≦)", "(´▽｀)", "(｡•̀ᴗ-)✧", "(づ｡◕‿‿◕｡)づ",
        "(・ω・)ノ", "(๑´ㅂ`๑)", "(｡•́︿•̀｡)", "(╯°□°）╯︵ ┻━┻", "谢谢～",
    ]
    private let defaults: UserDefaults
    private var phrases: [String]
    private var sessionPhrases: [String] = []
    private var enabled = false
    private var settings: PhraseWheelSettingsView?
    private var panel: PhraseWheelPanel?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.stringArray(forKey: Self.storageKey) {
            var normalized = Array(repeating: "", count: PhraseWheelGeometry.slotCount)
            for index in 0..<min(stored.count, normalized.count) {
                normalized[index] = String(stored[index].prefix(Self.characterLimit))
            }
            phrases = normalized
            if stored != normalized { defaults.set(normalized, forKey: Self.storageKey) }
        } else {
            phrases = Self.presets
        }
    }

    var settingsView: NSView {
        if let settings { return settings }
        let view = PhraseWheelSettingsView(phrases: phrases, characterLimit: Self.characterLimit)
        view.onChange = { [weak self] index, value in
            guard let self, self.phrases.indices.contains(index) else { return }
            self.phrases[index] = value
            self.defaults.set(self.phrases, forKey: Self.storageKey)
        }
        view.onPreview = { [weak self] in self?.presentWheel() }
        settings = view
        return view
    }

    func start() { enabled = true }

    func stop() {
        enabled = false
        dismissWheel()
    }

    func summon() {
        guard enabled else { return }
        presentWheel()
    }

    private func presentWheel() {
        dismissWheel()
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens.map {
            PhraseWheelGeometry.Rect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height)
        }
        guard let layout = PhraseWheelGeometry.layout(anchor: .init(x: mouse.x, y: mouse.y), screens: screens) else { return }
        sessionPhrases = phrases
        let panel = PhraseWheelPanel(layout: layout, phrases: sessionPhrases)
        panel.onChoose = { [weak self] index in self?.copyPhrase(at: index) }
        panel.onCancel = { [weak self] in self?.dismissWheel() }
        self.panel = panel
        panel.present()
    }

    private func copyPhrase(at index: Int) {
        guard sessionPhrases.indices.contains(index), !sessionPhrases[index].isEmpty else { return }
        let phrase = sessionPhrases[index]
        dismissWheel()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(phrase, forType: .string)
    }

    private func dismissWheel() {
        let old = panel
        panel = nil
        sessionPhrases.removeAll(keepingCapacity: false)
        old?.dismiss()
    }
}

@MainActor
private final class PhraseSlotsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class PhraseWheelSettingsView: NSView, NSTextFieldDelegate {
    var onChange: ((Int, String) -> Void)?
    var onPreview: (() -> Void)?
    private let characterLimit: Int
    private let scroll = NSScrollView()
    private let document = PhraseSlotsDocument()
    private let heading = NSTextField(labelWithString: "十个位置")
    private let preview = NSButton(title: "预览", target: nil, action: nil)
    private var fields: [NSTextField] = []
    private var labels: [NSTextField] = []

    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 412) }

    init(phrases: [String], characterLimit: Int) {
        self.characterLimit = characterLimit
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 412))
        heading.font = .systemFont(ofSize: 12)
        heading.textColor = .secondaryLabelColor
        addSubview(heading)
        preview.bezelStyle = .rounded
        preview.controlSize = .small
        preview.font = .systemFont(ofSize: 12)
        preview.target = self
        preview.action = #selector(previewPressed)
        addSubview(preview)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)
        for (index, phrase) in phrases.enumerated() {
            let digit = index == 9 ? "0" : String(index + 1)
            let label = NSTextField(labelWithString: digit)
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            let field = NSTextField(string: phrase)
            field.tag = index
            field.delegate = self
            field.font = .systemFont(ofSize: 13)
            field.usesSingleLineMode = true
            field.lineBreakMode = .byClipping
            field.setAccessibilityLabel("位置 \(digit)")
            document.addSubview(label)
            document.addSubview(field)
            labels.append(label)
            fields.append(field)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        heading.frame = NSRect(x: 0, y: max(0, bounds.height - 24), width: max(0, bounds.width - 72), height: 20)
        preview.frame = NSRect(x: max(0, bounds.width - 64), y: max(0, bounds.height - 27), width: 64, height: 26)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 40))
        let height = max(scroll.contentView.bounds.height, CGFloat(fields.count) * 36 + 12)
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentView.bounds.width, height: height)
        for index in fields.indices {
            let y = 12 + 36 * CGFloat(index)
            labels[index].frame = NSRect(x: 0, y: y + 4, width: 24, height: 20)
            fields[index].frame = NSRect(x: 32, y: y, width: max(40, document.bounds.width - 40), height: 28)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let text = String(field.stringValue.prefix(characterLimit))
        if field.stringValue != text { field.stringValue = text }
        onChange?(field.tag, text)
    }

    @objc private func previewPressed() { onPreview?() }
}
