import AppKit
import MacOSXCore

/// Copy-only prompt library. The shared input layer owns shortcut registration.
@MainActor final class PhraseWheelModule {
    private let defaults: UserDefaults
    private var entries: [PromptEntry]
    private var enabled = false
    private var settings: PromptSettingsView?
    private var panel: PhraseWheelPanel?
    private var saveWork: DispatchWorkItem?
    private static let key = "promptLibrary.entries"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), data.count <= 4_000_000,
           let stored = try? JSONDecoder().decode([PromptEntry].self, from: data) {
            entries = PromptLibrary.normalize(stored)
        } else if let old = defaults.stringArray(forKey: "phraseWheel.slots") {
            entries = PromptLibrary.migrate(old)
        } else { entries = PromptLibrary.presets }
    }
    var settingsView: NSView {
        if let settings { return settings }
        let view = PromptSettingsView(entries: entries)
        view.onChange = { [weak self] index, entry in
            guard let self, self.entries.indices.contains(index) else { return }
            self.entries[index] = entry
            self.saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.persist() }
            self.saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        view.onPreview = { [weak self] in self?.presentWheel() }
        settings = view; return view
    }
    private func persist() {
        saveWork?.cancel(); saveWork = nil
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
    func start() { enabled = true }
    func stop() { enabled = false; persist(); dismissWheel() }
    func summon() { guard enabled else { return }; presentWheel() }
    private func presentWheel() {
        dismissWheel()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let snapshot = entries
        let panel = PhraseWheelPanel(anchor: mouse, screen: screen.visibleFrame, entries: snapshot)
        panel.onChoose = { [weak self] index in
            guard snapshot.indices.contains(index), !snapshot[index].content.isEmpty else { return }
            self?.dismissWheel()
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snapshot[index].content, forType: .string)
        }
        panel.onCancel = { [weak self] in self?.dismissWheel() }
        self.panel = panel; panel.present()
    }
    private func dismissWheel() { let old = panel; panel = nil; old?.dismiss() }
}

@MainActor private final class PromptSettingsView: NSView, NSTextFieldDelegate, NSTextViewDelegate {
    var onChange: ((Int, PromptEntry) -> Void)?
    var onPreview: (() -> Void)?
    private var entries: [PromptEntry]
    private var selected = 0
    private let picker = MinimalPopUpButton()
    private let titleField = NSTextField(string: "")
    private let body = NSTextView()
    private let scroll = NSScrollView()
    private let preview = MinimalButton(title: "预览", target: nil, action: nil, style: .quiet)
    override var intrinsicContentSize: NSSize { NSSize(width: 320, height: 300) }
    init(entries: [PromptEntry]) {
        self.entries = entries
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        picker.target = self; picker.action = #selector(selectEntry); picker.setAccessibilityLabel("编辑常用提示词")
        titleField.placeholderString = "标题"; titleField.delegate = self
        titleField.font = .systemFont(ofSize: 14, weight: .medium); titleField.isBezeled = false; titleField.focusRingType = .none
        titleField.drawsBackground = false; titleField.setAccessibilityLabel("提示词标题")
        body.isRichText = false; body.isAutomaticQuoteSubstitutionEnabled = false; body.isAutomaticDashSubstitutionEnabled = false
        body.font = .systemFont(ofSize: 13); body.delegate = self; body.drawsBackground = false
        body.textContainerInset = NSSize(width: 10, height: 10); body.isHorizontallyResizable = false
        body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true
        body.setAccessibilityLabel("提示词内容")
        scroll.documentView = body; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 10
        preview.target = self; preview.action = #selector(previewPressed)
        for view in [picker, titleField, scroll, preview] { addSubview(view) }
        refreshPicker(); loadEntry()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        picker.frame = NSRect(x: 0, y: bounds.height - 34, width: max(80, bounds.width - 80), height: 30)
        preview.frame = NSRect(x: bounds.width - 68, y: bounds.height - 34, width: 64, height: 30)
        titleField.frame = NSRect(x: 10, y: bounds.height - 78, width: max(80, bounds.width - 20), height: 28)
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(80, bounds.height - 90))
        body.frame.size.width = scroll.contentSize.width
        scroll.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.025).cgColor
    }
    private func refreshPicker() {
        picker.removeAllItems()
        for (index, entry) in entries.enumerated() { picker.addItem(withTitle: "\(index + 1) · \(entry.title.isEmpty ? "未设置" : entry.title)") }
        picker.selectItem(at: selected)
    }
    private func loadEntry() { titleField.stringValue = entries[selected].title; body.string = entries[selected].content }
    @objc private func selectEntry() { selected = picker.indexOfSelectedItem; loadEntry() }
    @objc private func previewPressed() { window?.makeFirstResponder(nil); onPreview?() }
    func controlTextDidChange(_ notification: Notification) { changed() }
    func textDidChange(_ notification: Notification) { changed() }
    private func changed() {
        // Leave marked text intact until the input method commits it.
        if (titleField.currentEditor() as? NSTextView)?.hasMarkedText() == true || body.hasMarkedText() { return }
        let title = String(titleField.stringValue.prefix(PromptLibrary.titleLimit))
        let content = String(body.string.prefix(PromptLibrary.contentLimit))
        if titleField.stringValue != title { titleField.stringValue = title }; if body.string != content { body.string = content }
        entries[selected] = .init(title: title, content: content)
        picker.item(at: selected)?.title = "\(selected + 1) · \(title.isEmpty ? "未设置" : title)"
        onChange?(selected, entries[selected])
    }
}
