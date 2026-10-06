import AppKit
import Carbon
import MacOSXCore

@MainActor
final class ShortcutStore {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func binding(for action: ShortcutAction) -> ShortcutBinding {
        guard let data = defaults.data(forKey: key(action)), data.count < 2048,
            let result = try? JSONDecoder().decode(ShortcutBinding.self, from: data), result.isValid,
            result.keyLabel.count <= 24 else { return action.defaultBinding }
        return result
    }
    func set(_ value: ShortcutBinding, for action: ShortcutAction) {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key(action))
    }
    private func key(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }

    func conflict(_ candidate: ShortcutBinding, action: ShortcutAction) -> String? {
        guard candidate.isValid else { return "请使用 F1–F20，或 Control / Command 组合键" }
        for other in ShortcutAction.allCases where other != action {
            if candidate.conflicts(with: binding(for: other)) { return "与“\(other.title)”重复" }
        }
        if candidate.kind == .doubleModifier {
            // Modifier-only system gestures do not expose an exclusive Carbon
            // registration. Keep Control double-taps away from Dictation.
            return [59, 62].contains(candidate.keyCode) ? "请用 Option 双击或组合键，避免听写冲突" : nil
        }
        // App-menu shortcuts are not returned by CopySymbolicHotKeys. Keep
        // common typing/navigation combinations out of the global registrar.
        if !candidate.isFunctionKey && (candidate.modifiers == 8 || candidate.modifiers == 12) {
            return "这是系统或应用常用组合，请换一个"
        }
        if candidate.keyCode == 53 && candidate.modifiers == 10 {
            return "与系统强制退出快捷键冲突"
        }
        var catalog: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&catalog) == noErr, let array = catalog?.takeRetainedValue() as? [[String: Any]] else {
            return "暂时无法检查系统快捷键，请重试"
        }
        let mask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        for item in array where (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true {
            guard let code = item[kHISymbolicHotKeyCode as String] as? NSNumber,
                let modifiers = item[kHISymbolicHotKeyModifiers as String] as? NSNumber else { continue }
            if code.uint16Value == candidate.keyCode && modifiers.uint32Value & mask == candidate.carbonModifiers {
                return "与系统快捷键冲突"
            }
        }
        return nil
    }
}

@MainActor
private final class ShortcutRecorder: MinimalButton {
    var onBinding: ((ShortcutBinding) -> Void)?
    var onRecording: ((Bool) -> Void)?
    private var recording = false
    private var previousTitle = ""
    private var observer: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }

    init() {
        super.init(frame: .zero)
        font = SketchPalette.heading(16)
        target = self; action = #selector(begin)
        toolTip = "点击后按下新快捷键；Escape 取消"
        setAccessibilityLabel("编辑快捷键")
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    @objc private func begin() {
        guard !recording else { finish(); return }
        previousTitle = title; recording = true; title = "按下快捷键…"
        window?.makeFirstResponder(self)
        onRecording?(true)
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
    }

    func finish() {
        guard recording else { return }
        recording = false; title = previousTitle
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        onRecording?(false)
    }

    override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { if window == nil { finish() }; super.viewDidMoveToWindow() }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finish(); return }
        let flags = event.modifierFlags
        let modifiers: UInt8 = (flags.contains(.control) ? 1 : 0) | (flags.contains(.option) ? 2 : 0)
            | (flags.contains(.shift) ? 4 : 0) | (flags.contains(.command) ? 8 : 0)
        let labels: [UInt16: String] = [49: "Space", 48: "Tab", 36: "Return", 51: "⌫", 117: "⌦",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4",
            96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let name = labels[event.keyCode] ?? (event.charactersIgnoringModifiers?.uppercased() ?? "键 \(event.keyCode)")
        let binding = ShortcutBinding(keyCode: event.keyCode, modifiers: modifiers, keyLabel: name)
        finish(); onBinding?(binding)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event); return true
    }
}

@MainActor
final class ShortcutPicker: NSStackView {
    private let recorder = ShortcutRecorder()
    private let mode = MinimalPopUpButton()
    private let notice = NSTextField(labelWithString: "")
    private var binding: ShortcutBinding
    private var editingChord = false
    private let accepts: (ShortcutBinding) -> String?
    private let didChange: (ShortcutBinding) -> Void

    init(title: String, binding: ShortcutBinding, allowsDoubleTap: Bool,
        recordingChanged: @escaping (Bool) -> Void,
        accepts: @escaping (ShortcutBinding) -> String?, didChange: @escaping (ShortcutBinding) -> Void) {
        self.binding = binding; self.accepts = accepts; self.didChange = didChange
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        let row = NSStackView(); row.orientation = .horizontal; row.spacing = 12
        let label = NSTextField(labelWithString: title); label.font = SketchPalette.heading(16); label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 88).isActive = true
        row.addArrangedSubview(label)
        if allowsDoubleTap {
            mode.addItems(withTitles: ["双击右 Option", "双击左 Option", "组合键"])
            mode.target = self; mode.action = #selector(selectTriggerMode)
            mode.setAccessibilityLabel("唤起方式")
            row.addArrangedSubview(mode)
        }
        row.addArrangedSubview(recorder)
        recorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        addArrangedSubview(row)
        notice.font = .systemFont(ofSize: 11); notice.textColor = .systemRed; notice.maximumNumberOfLines = 2
        addArrangedSubview(notice)
        recorder.onRecording = recordingChanged
        recorder.onBinding = { [weak self] value in self?.propose(value) }
        recorder.toolTip = "点击修改；功能键可能需要同时按 Fn，Escape 取消"
        refresh()
    }
    required init?(coder: NSCoder) { nil }

    private func refresh() {
        recorder.title = editingChord ? "设置快捷键…" : binding.displayName
        recorder.isHidden = binding.kind == .doubleModifier && !editingChord
        if binding.kind == .doubleModifier && !editingChord {
            mode.selectItem(at: [UInt16(61), 58].firstIndex(of: binding.keyCode) ?? 0)
        } else { mode.selectItem(at: 2) }
        notice.isHidden = notice.stringValue.isEmpty
    }
    private func propose(_ value: ShortcutBinding) {
        if let issue = accepts(value) { notice.stringValue = issue; refresh(); return }
        binding = value; editingChord = false; notice.stringValue = ""; didChange(value); refresh()
    }
    @objc private func selectTriggerMode() {
        let index = mode.indexOfSelectedItem
        if index < 2 {
            editingChord = false
            propose(.init(kind: .doubleModifier, keyCode: [61, 58][index], modifiers: 0, keyLabel: ""))
        } else if binding.kind == .doubleModifier {
            editingChord = true
            notice.stringValue = ""; refresh()
        }
    }
}
