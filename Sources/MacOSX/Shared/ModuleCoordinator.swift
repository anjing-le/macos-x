import AppKit
import ApplicationServices
import MacOSXCore

@MainActor
final class ModuleCoordinator {
    var onStateChanged: ((Tool) -> Void)?
    private let defaults: UserDefaults
    let shortcuts: ShortcutStore
    private let input = GlobalInput()
    private var tools = Set<Tool>()
    private var wheel: PhraseWheelModule?
    private var capture: CaptureModule?
    private var finishingCaptures: [UUID: CaptureModule] = [:]
    private var switcher: WindowSwitcherModule?
    private var issues: [ShortcutAction: String] = [:]
    private var tapIssue: String?
    private var activeObserver: NSObjectProtocol?
    private var synchronizing = false
    private var terminating = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults; shortcuts = ShortcutStore(defaults: defaults)
        input.onShortcut = { [weak self] action in
            guard let self else { return }
            switch action {
            case .wheel: self.wheel?.summon()
            case .capture: self.capture?.capture()
            case .pin: self.capture?.pinClipboard()
            case .recording: self.capture?.toggleRecording()
            }
        }
        input.onAdvance = { [weak self] reverse in self?.switcher?.advance(reverse: reverse) }
        input.onRelease = { [weak self] in self?.switcher?.releaseCommand() }
        input.onCancel = { [weak self] in self?.switcher?.cancel() }
        input.onMove = { [weak self] offset in self?.switcher?.moveSelection(by: offset) }
        input.onConfirm = { [weak self] in self?.switcher?.confirmSelection() }
        input.onTapUnavailable = { [weak self] in
            self?.tapIssue = "全局监听不可用，请检查辅助功能权限"
            self?.onStateChanged?(.windowSwitcher); self?.onStateChanged?(.kaomoji)
        }
        input.onTapAvailable = { [weak self] in
            self?.tapIssue = nil
            self?.onStateChanged?(.windowSwitcher); self?.onStateChanged?(.kaomoji)
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
    }

    func reconcile(_ added: [Tool]) {
        guard !terminating else { return }
        let next = Set(added)
        for tool in tools.subtracting(next) { stop(tool, remove: true) }
        tools = next
        for tool in tools { ensure(tool) }
        refreshPermissions()
    }

    func isEnabled(_ tool: Tool) -> Bool {
        tools.contains(tool) && (defaults.object(forKey: "enabled.\(tool.rawValue)") as? Bool ?? true)
    }

    func setEnabled(_ enabled: Bool, tool: Tool) {
        guard !terminating, tools.contains(tool) else { return }
        defaults.set(enabled, forKey: "enabled.\(tool.rawValue)")
        if enabled { start(tool) } else { stop(tool, remove: false) }
        configureInput(); onStateChanged?(tool)
    }

    private func ensure(_ tool: Tool) {
        switch tool {
        case .kaomoji: if wheel == nil { wheel = PhraseWheelModule(defaults: defaults) }
        case .capture:
            if capture == nil {
                capture = CaptureModule()
                capture?.onPermissionNeeded = { [weak self] in self?.requestScreenCapture() }
            }
        case .windowSwitcher:
            if switcher == nil {
                switcher = WindowSwitcherModule()
                switcher?.onReadinessChanged = { [weak self] _ in
                    guard let self, !self.synchronizing else { return }
                    self.configureInput(); self.onStateChanged?(.windowSwitcher)
                }
            }
        }
    }

    private func start(_ tool: Tool) {
        ensure(tool)
        switch tool { case .kaomoji: wheel?.start(); case .capture: capture?.start(); case .windowSwitcher: switcher?.start() }
    }
    private func stop(_ tool: Tool, remove: Bool) {
        switch tool {
        case .kaomoji: wheel?.stop(); if remove { wheel = nil }
        case .capture:
            capture?.stop()
            if remove, let retiring = capture {
                capture = nil
                let id = UUID(); finishingCaptures[id] = retiring
                retiring.prepareToTerminate { [weak self] in self?.finishingCaptures[id] = nil }
            }
        case .windowSwitcher: switcher?.stop(); if remove { switcher = nil }
        }
    }

    func refreshPermissions() {
        guard !terminating, !synchronizing else { return }
        synchronizing = true
        for tool in tools where isEnabled(tool) { start(tool) }
        synchronizing = false
        configureInput()
        for tool in tools { onStateChanged?(tool) }
    }

    private func configureInput() {
        guard !terminating else { return }
        var bindings: [ShortcutAction: ShortcutBinding] = [:]
        for action in ShortcutAction.allCases {
            let tool: Tool = action == .wheel ? .kaomoji : .capture
            guard isEnabled(tool) else { continue }
            let binding = shortcuts.binding(for: action)
            if let issue = shortcuts.conflict(binding, action: action) {
                issues[action] = issue
            } else { bindings[action] = binding; issues[action] = nil }
        }
        let registrationIssues = input.configure(bindings: bindings,
            switcherReady: isEnabled(.windowSwitcher) && (switcher?.isReady ?? false))
        issues.merge(registrationIssues) { _, current in current }
    }

    func settingsView(for tool: Tool) -> NSView {
        ensure(tool)
        switch tool {
        case .kaomoji: return wheel!.settingsView
        case .capture: return capture!.settingsView
        case .windowSwitcher: return switcher!.settingsView
        }
    }

    func shortcutPicker(_ action: ShortcutAction) -> NSView {
        ShortcutPicker(title: action == .wheel ? "唤起" : action.title,
            binding: shortcuts.binding(for: action), allowsDoubleTap: action == .wheel,
            recordingChanged: { [weak self] value in
                guard let self, !self.terminating else { return }
                self.input.setRecordingShortcut(value)
                if !value {
                    self.configureInput()
                    self.onStateChanged?(.kaomoji); self.onStateChanged?(.capture)
                }
            },
            accepts: { [weak self] value in
                guard let self else { return "请重试" }
                return self.shortcuts.conflict(value, action: action) ?? self.input.probe(value, for: action)
            }, didChange: { [weak self] value in
                guard let self else { return }
                self.shortcuts.set(value, for: action); self.configureInput()
                self.onStateChanged?(action == .wheel ? .kaomoji : .capture)
            })
    }

    func needsAccessibility(_ tool: Tool) -> Bool {
        (tool == .windowSwitcher || (tool == .kaomoji && shortcuts.binding(for: .wheel).kind == .doubleModifier))
            && !AXIsProcessTrusted()
    }
    func needsScreenCapture(_ tool: Tool) -> Bool { tool == .capture && !CGPreflightScreenCaptureAccess() }
    func issue(for tool: Tool) -> String? {
        if !isEnabled(tool) { return nil }
        if tool == .kaomoji {
            let usesTap = shortcuts.binding(for: .wheel).kind == .doubleModifier
            return issues[.wheel] ?? (usesTap && !needsAccessibility(tool) ? tapIssue : nil)
        }
        if tool == .capture { return [ShortcutAction.capture, .pin, .recording].compactMap { issues[$0] }.first }
        return needsAccessibility(tool) ? nil : tapIssue
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    func requestScreenCapture() {
        _ = CGRequestScreenCaptureAccess()
        if !CGPreflightScreenCaptureAccess(),
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refreshPermissions()
    }

    func stop() {
        terminating = true
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver); self.activeObserver = nil }
        input.stop()
        for tool in tools { stop(tool, remove: true) }
        tools.removeAll()
    }

    func prepareToTerminate(completion: @escaping () -> Void) {
        terminating = true
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver); self.activeObserver = nil }
        input.stop()
        wheel?.stop(); switcher?.stop()
        let captures = Array(finishingCaptures.values) + (capture.map { [$0] } ?? [])
        guard !captures.isEmpty else { DispatchQueue.main.async { completion() }; return }
        var outstanding = captures.count
        for module in captures {
            module.prepareToTerminate {
                outstanding -= 1
                if outstanding == 0 { completion() }
            }
        }
    }
}

@MainActor
final class ModuleSettingsHeader: NSStackView {
    private let module: ModuleCoordinator
    private let tool: Tool
    private let toggle = NSSwitch()
    private let accessibility = NSButton(title: "允许辅助功能", target: nil, action: nil)
    private let screenCapture = NSButton(title: "允许屏幕录制", target: nil, action: nil)
    private let issue = NSTextField(labelWithString: "")

    init(tool: Tool, module: ModuleCoordinator) {
        self.tool = tool; self.module = module
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 16
        let enabled = NSStackView(); enabled.orientation = .horizontal; enabled.spacing = 16
        let label = NSTextField(labelWithString: "启用"); label.font = .systemFont(ofSize: 13)
        enabled.addArrangedSubview(label); enabled.addArrangedSubview(toggle)
        toggle.target = self; toggle.action = #selector(changeEnabled); toggle.setAccessibilityLabel("启用\(tool.title)")
        addArrangedSubview(enabled)
        for button in [accessibility, screenCapture] { button.bezelStyle = .rounded; button.target = self; addArrangedSubview(button) }
        accessibility.action = #selector(allowAccessibility); screenCapture.action = #selector(allowScreenCapture)
        issue.font = .systemFont(ofSize: 11); issue.textColor = .secondaryLabelColor; issue.maximumNumberOfLines = 2
        addArrangedSubview(issue)
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        let active = module.isEnabled(tool)
        toggle.state = active ? .on : .off
        accessibility.isHidden = !active || !module.needsAccessibility(tool)
        screenCapture.isHidden = !active || !module.needsScreenCapture(tool)
        issue.stringValue = module.issue(for: tool) ?? ""
        issue.isHidden = issue.stringValue.isEmpty
    }
    @objc private func changeEnabled() { module.setEnabled(toggle.state == .on, tool: tool); refresh() }
    @objc private func allowAccessibility() { module.requestAccessibility() }
    @objc private func allowScreenCapture() { module.requestScreenCapture(); refresh() }
}
