import AppKit
import ApplicationServices
import MacOSXCore

@MainActor
final class ModuleCoordinator {
    var onStateChanged: ((Tool) -> Void)?
    var onScreenCapturePermissionNeeded: (() -> Void)?
    private let defaults: UserDefaults
    let shortcuts: ShortcutStore
    private let input = GlobalInput()
    private var tools = Set<Tool>()
    private var wheel: PhraseWheelModule?
    private var capture: CaptureModule?
    private var finishingCaptures: [UUID: CaptureModule] = [:]
    private var switcher: WindowSwitcherModule?
    private var layout:WindowLayoutModule?
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
            case .capture:
                self.layout?.cancelDrag()
                self.input.endSwitcherSession()
                let finished = self.switcher?.freezeForCapture()
                if self.capture?.capture(snapshotReady: finished) != true { finished?() }
            case .pin: self.capture?.pin()
            case .recording: self.capture?.toggleRecording()
            case .togglePins: self.capture?.togglePins()
            case .layoutLeft:self.layout?.perform(.left)
            case .layoutRight:self.layout?.perform(.right)
            case .layoutUp:self.layout?.perform(.top)
            case .layoutDown:self.layout?.perform(.bottom)
            }
        }
        input.onAdvance = { [weak self] reverse in self?.switcher?.advance(reverse: reverse) }
        input.onRelease = { [weak self] in self?.switcher?.releaseCommand() }
        input.onCancel = { [weak self] in self?.switcher?.cancel() }
        input.onMove = { [weak self] horizontal, vertical in self?.switcher?.moveSelection(horizontal: horizontal, vertical: vertical) }
        input.onConfirm = { [weak self] in self?.switcher?.confirmSelection() }
        input.onTapUnavailable = { [weak self] in
            self?.tapIssue = "快捷键监听失败 · 当前使用原生 ⌘Tab"
            self?.switcher?.setInputAvailable(false)
            self?.onStateChanged?(.windowSwitcher); self?.onStateChanged?(.kaomoji)
        }
        input.onTapAvailable = { [weak self] in
            self?.tapIssue = nil
            self?.switcher?.setInputAvailable(true)
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
        case .windowLayout:
            if layout == nil { layout=WindowLayoutModule(); layout?.onStatusChange={ [weak self] in self?.onStateChanged?(.windowLayout) } }
        case .kaomoji: if wheel == nil { wheel = PhraseWheelModule(defaults: defaults) }
        case .capture:
            if capture == nil {
                capture = CaptureModule()
                capture?.onPermissionNeeded = { [weak self] in self?.onScreenCapturePermissionNeeded?() }
                capture?.onStatusChange = { [weak self] _ in self?.onStateChanged?(.capture) }
            }
        case .windowSwitcher:
            if switcher == nil {
                switcher = WindowSwitcherModule(defaults: defaults)
                switcher?.onPreviewSettingsChanged = { [weak self] in self?.onStateChanged?(.windowSwitcher) }
                switcher?.onReadinessChanged = { [weak self] _ in
                    guard let self, !self.synchronizing else { return }
                    self.configureInput(); self.onStateChanged?(.windowSwitcher)
                }
            }
        }
    }

    private func start(_ tool: Tool) {
        ensure(tool)
        switch tool { case .kaomoji: wheel?.start(); case .capture: capture?.start(); case .windowSwitcher: switcher?.start();case .windowLayout:layout?.start(); layout?.refreshPermission() }
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
        case .windowLayout:layout?.stop(); if remove { layout=nil }
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
        let activeActions=Set(ShortcutAction.allCases.filter { isEnabled(Tool(rawValue:$0.moduleKey)!) })
        for action in ShortcutAction.allCases {
            let tool=Tool(rawValue:action.moduleKey)!
            guard isEnabled(tool) else { continue }
            let binding = shortcuts.binding(for: action)
            if let issue = shortcuts.conflict(binding, action: action,activeActions:activeActions) {
                issues[action] = issue
            } else { bindings[action] = binding; issues[action] = nil }
        }
        let registrationIssues = input.configure(bindings: bindings,
            switcherReady: isEnabled(.windowSwitcher) && (switcher?.isReady ?? false))
        switcher?.setInputAvailable(input.hasActiveTap)
        issues.merge(registrationIssues) { _, current in current }
    }

    func settingsView(for tool: Tool) -> NSView {
        ensure(tool)
        switch tool {
        case .kaomoji: return wheel!.settingsView
        case .capture: return capture!.settingsView
        case .windowSwitcher: return switcher!.settingsView
        case .windowLayout:return layout!.settingsView
        }
    }

    func shortcutPicker(_ action: ShortcutAction, showsTitle: Bool = true) -> NSView {
        let label=action == .wheel ? "唤起" : action.title
        let picker = ShortcutPicker(title: showsTitle ? label : "",
            binding: shortcuts.binding(for: action), allowsDoubleTap: action == .wheel,
            recordingChanged: { [weak self] value in
                guard let self, !self.terminating else { return }
                self.input.setRecordingShortcut(value)
                if !value {
                    self.configureInput()
                    self.onStateChanged?(.kaomoji); self.onStateChanged?(.capture); self.onStateChanged?(.windowLayout)
                }
            },
            accepts: { [weak self] value in
                guard let self else { return "请重试" }
                return self.shortcuts.conflict(value, action: action,activeActions:Set(ShortcutAction.allCases.filter { self.isEnabled(Tool(rawValue:$0.moduleKey)!) })) ?? self.input.probe(value, for: action)
            }, didChange: { [weak self] value in
                guard let self else { return }
                self.shortcuts.set(value, for: action); self.configureInput()
                self.onStateChanged?(Tool(rawValue:action.moduleKey)!)
            })
        if action == .togglePins { picker.toolTip = "暂时隐藏或显示桌面的全部贴图，不会删除图片。" }
        if action == .pin { picker.toolTip = "框选或标注时固定当前区域；其他时候贴出剪贴板内容。" }
        return picker
    }

    func needsAccessibility(_ tool: Tool) -> Bool {
        (tool == .windowSwitcher || tool == .windowLayout || (tool == .kaomoji && shortcuts.binding(for: .wheel).kind == .doubleModifier))
            && !AXIsProcessTrusted()
    }
    func needsScreenCapture(_ tool: Tool) -> Bool {
        let needed = tool == .capture ? capture?.hasConfirmedScreenCaptureAccess != true
            : tool == .windowSwitcher && switcher?.thumbnailsEnabled == true && switcher?.hasConfirmedThumbnailAccess != true
        return needed && (!CGPreflightScreenCaptureAccess() || (tool == .windowSwitcher && switcher?.thumbnailPermissionDenied == true))
    }
    func issue(for tool: Tool) -> String? {
        if !isEnabled(tool) { return nil }
        if tool == .kaomoji {
            let usesTap = shortcuts.binding(for: .wheel).kind == .doubleModifier
            return issues[.wheel] ?? (usesTap && !needsAccessibility(tool) ? tapIssue : nil)
        }
        if tool == .capture {
            return [ShortcutAction.capture, .pin, .togglePins, .recording].compactMap { issues[$0] }.first
        }
        if tool == .windowLayout { return [ShortcutAction.layoutLeft,.layoutRight,.layoutUp,.layoutDown].compactMap { issues[$0] }.first }
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
        guard !terminating else { return }
        let granted = CGRequestScreenCaptureAccess()
        if granted { switcher?.retryThumbnailPermission() }
        if !granted,
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
        wheel?.stop(); switcher?.stop(); layout?.stop()
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
    private let toggle = ModuleEnableButton(title:"功能",target:nil,action:nil)
    private let accessibility = MinimalButton(title: "允许辅助功能", target: nil, action: nil, style: .standard)
    private let screenCapture = MinimalButton(title: "屏幕权限", target: nil, action: nil, style: .standard)
    private let issue = NSTextField(labelWithString: "")

    init(tool: Tool, module: ModuleCoordinator) {
        self.tool = tool; self.module = module
        super.init(frame: .zero)
        orientation = .vertical; alignment = tool == .capture ? .trailing : .leading; spacing = 8
        let enabled = NSStackView(); enabled.orientation = .horizontal; enabled.spacing = 12
        let label = NSTextField(labelWithString: "启用"); label.font = SketchPalette.heading(16)
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 88).isActive = true
        enabled.addArrangedSubview(label); enabled.addArrangedSubview(toggle)
        toggle.widthAnchor.constraint(equalToConstant:68).isActive=true
        toggle.heightAnchor.constraint(equalToConstant:30).isActive=true
        toggle.target = self; toggle.action = #selector(changeEnabled); toggle.setAccessibilityLabel("启用\(tool.title)")
        addArrangedSubview(enabled)
        for button in [accessibility, screenCapture] { button.target = self; addArrangedSubview(button) }
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
