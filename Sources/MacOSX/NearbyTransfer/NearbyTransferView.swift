import AppKit
import MacOSXCore

@MainActor final class NearbyTransferView: SketchSurface {
    let service: NearbyTransferService
    var onSettings: (() -> Void)?
    private let title = NSTextField(labelWithString: AppLanguage.text("附近互传"))
    private let settings = NSButton(title: "", target: nil, action: nil)
    private let devices = NSButton(title: "", target: nil, action: nil)
    private let connectedDevice = NSTextField(labelWithString: "")
    private var deviceMenu: SketchSurface?
    private var deviceButtons: [NSButton] = []
    private let disconnectButton = NSButton(title: AppLanguage.text("断开"), target: nil, action: nil)
    private let connection = NSTextField(labelWithString: "")
    private let accept = NSButton(title: AppLanguage.text("允许连接"), target: nil, action: nil)
    private let reject = NSButton(title: AppLanguage.text("拒绝"), target: nil, action: nil)
    private let drop: NearbyDropView
    private let recent = NSTextField(labelWithString: AppLanguage.text("最近传输"))
    private let scroll = NSScrollView()
    private let list = NearbyFlippedView()
    private var rows: [NearbyTransferRow] = []
    private let empty = NSTextField(labelWithString: AppLanguage.text("收到的文件、文字和图片会出现在这里"))
    private let autoLabel = NSTextField(labelWithString: AppLanguage.text("接收后自动复制"))
    private let autoToggle = NSSwitch()
    private let note = NSTextField(wrappingLabelWithString: "")
    private var deviceChoices: [NearbyDevice] = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 420, height: 548) }

    init(service: NearbyTransferService) {
        self.service = service; drop = NearbyDropView(service: service)
        super.init(frame: CGRect(x: 0, y: 0, width: 420, height: 548))
        radius = 18
        for view in [title, settings, devices, connectedDevice, disconnectButton, connection, accept, reject, drop, recent, scroll, empty, autoLabel, autoToggle, note] { addSubview(view) }
        title.font = SketchPalette.heading(27); title.textColor = SketchPalette.ink
        recent.font = SketchPalette.heading(17); recent.textColor = SketchPalette.ink
        autoLabel.font = SketchPalette.heading(15); autoLabel.textColor = SketchPalette.ink
        connection.font = .systemFont(ofSize: 12); connection.textColor = SketchPalette.muted
        note.font = .systemFont(ofSize: 11); note.textColor = SketchPalette.muted; note.maximumNumberOfLines = 2
        empty.font = .systemFont(ofSize: 12); empty.textColor = SketchPalette.muted; empty.alignment = .center
        settings.image = SketchIcons.image(.settings, size: 22); settings.isBordered = false
        settings.toolTip = AppLanguage.text("打开附近互传设置"); settings.setAccessibilityLabel(settings.toolTip)
        settings.target = self; settings.action = #selector(openSettings)
        devices.isBordered = false; devices.font = .systemFont(ofSize: 15); devices.alignment = .left
        devices.target = self; devices.action = #selector(selectDevice)
        devices.setAccessibilityLabel(AppLanguage.text("连接设备"))
        connectedDevice.font = .systemFont(ofSize: 15); connectedDevice.textColor = SketchPalette.ink
        connectedDevice.lineBreakMode = .byTruncatingTail
        for button in [disconnectButton, accept, reject] { button.isBordered = false; button.font = SketchPalette.heading(14); button.contentTintColor = SketchPalette.ink; button.target = self }
        disconnectButton.action = #selector(disconnect); accept.action = #selector(confirm); reject.action = #selector(decline)
        autoToggle.target = self; autoToggle.action = #selector(changeAutoCopy); autoToggle.setAccessibilityLabel(AppLanguage.text("接收后自动复制"))
        autoToggle.toolTip = AppLanguage.text("仅本次连接有效；收到文字或图片后覆盖本机剪贴板。")
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder; scroll.documentView = list
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    func refresh() {
        let focusedRow = rows.firstIndex(where: { $0.containsResponder(window?.firstResponder) }).map { rows[$0].id }
        if let device = service.device {
            closeDeviceMenu()
            devices.title = (service.ready ? "● " : "○ ") + device.name
            let text = NSMutableAttributedString(string: devices.title, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: SketchPalette.ink])
            text.addAttribute(.foregroundColor, value: service.ready ? SketchPalette.green : SketchPalette.muted, range: NSRange(location: 0, length: 1))
            connectedDevice.attributedStringValue = text; connectedDevice.isHidden = false; devices.isHidden = true
            devices.isEnabled = false; disconnectButton.isHidden = false
        } else {
            connectedDevice.isHidden = true; devices.isHidden = false
            let next = service.devices
            if next != deviceChoices {
                deviceChoices = next
                if deviceMenu != nil { closeDeviceMenu(); openDeviceMenu() }
            }
            devices.title = (service.running ? AppLanguage.text("选择附近的 Mac") : AppLanguage.text("功能已关闭")) + "  ⌄"
            devices.isEnabled = service.running; disconnectButton.isHidden = true
            if !service.running { closeDeviceMenu() }
        }
        let pairing = service.pairingCode != nil && !service.ready
        let invitation = service.incomingInvitation
        accept.isHidden = !(pairing || invitation); reject.isHidden = accept.isHidden
        accept.title = invitation ? AppLanguage.text("允许连接") : (service.confirmed ? AppLanguage.text("等待对方确认") : AppLanguage.text("配对码一致"))
        accept.isEnabled = invitation || !service.confirmed
        if let code = service.pairingCode, !service.ready {
            connection.stringValue = AppLanguage.text("配对码 {0} · 请核对另一台 Mac", code)
        } else if invitation { connection.stringValue = AppLanguage.text("对方请求连接，是否允许？") }
        else { connection.stringValue = service.ready ? AppLanguage.text("已连接 · 同一网络内互传") : AppLanguage.text("两台 Mac 均需开启附近互传") }
        autoToggle.state = service.autoCopy ? .on : .off; autoToggle.isEnabled = service.ready
        note.stringValue = service.status
        drop.needsDisplay = true; drop.setAccessibilityLabel(service.ready ? AppLanguage.text("拖入文件，或 ⌘V 发送") : AppLanguage.text("先连接附近的 Mac"))
        let values = service.records
        // Progress updates keep row controls and keyboard focus intact.
        if rows.map(\.id) != values.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = values.map { record in let row = NearbyTransferRow(record: record, service: service); list.addSubview(row); return row }
            if let focusedRow, let row = rows.first(where: { $0.id == focusedRow }) { window?.makeFirstResponder(row.primaryAction) }
        }
        for (row, value) in zip(rows, values) { row.update(value) }
        empty.isHidden = !values.isEmpty
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout(); let w = bounds.width, inset: CGFloat = 20
        title.frame = CGRect(x: inset, y: 20, width: w - 80, height: 36)
        settings.frame = CGRect(x: w - 52, y: 23, width: 30, height: 30)
        devices.frame = CGRect(x: inset + 24, y: 70, width: max(100, w - 140), height: 30)
        connectedDevice.frame = CGRect(x: inset + 24, y: 74, width: max(100, w - 140), height: 24)
        disconnectButton.frame = CGRect(x: w - 76, y: 70, width: 58, height: 30)
        connection.frame = CGRect(x: inset, y: 105, width: w - inset * 2, height: 18)
        let prompt = !accept.isHidden
        if prompt {
            accept.frame = CGRect(x: inset, y: 132, width: 190, height: 28)
            reject.frame = CGRect(x: w - 80, y: 132, width: 60, height: 28)
        }
        let top: CGFloat = prompt ? 172 : 134
        drop.frame = CGRect(x: inset, y: top, width: w - inset * 2, height: prompt ? 72 : 110)
        recent.frame = CGRect(x: inset, y: 258, width: w - 40, height: 24)
        scroll.frame = CGRect(x: inset, y: 288, width: w - 40, height: max(56, bounds.height - 380))
        list.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, CGFloat(rows.count) * 56))
        for (i, row) in rows.enumerated() { row.frame = CGRect(x: 0, y: CGFloat(i) * 56, width: list.bounds.width, height: 56) }
        empty.frame = CGRect(x: inset, y: 322, width: w - 40, height: 36)
        autoLabel.frame = CGRect(x: inset, y: bounds.height - 70, width: w - 100, height: 25)
        autoToggle.frame = CGRect(x: w - 64, y: bounds.height - 72, width: 44, height: 28)
        note.frame = CGRect(x: inset, y: bounds.height - 38, width: w - 40, height: 30)
        if let menu = deviceMenu {
            menu.frame = CGRect(x: inset, y: 104, width: w - 40, height: min(242, CGFloat(max(1, deviceButtons.count)) * 34 + 12))
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let line = NSBezierPath(); line.move(to: CGPoint(x: 20, y: 129)); line.line(to: CGPoint(x: bounds.width - 20, y: 129))
        line.move(to: CGPoint(x: 20, y: bounds.height - 81)); line.line(to: CGPoint(x: bounds.width - 20, y: bounds.height - 81))
        SketchPencil.stroke(line, color: SketchPalette.line.withAlphaComponent(0.35), width: 0.7)
        let icon = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        icon?.draw(in: CGRect(x: 20, y: 77, width: 20, height: 18))
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
            if !event.isARepeat { service.paste() }; return true
        }
        return super.performKeyEquivalent(with: event)
    }
    @objc func paste(_ sender: Any?) { service.paste() }
    @objc private func selectDevice() { deviceMenu == nil ? openDeviceMenu() : closeDeviceMenu() }
    private func closeDeviceMenu() { deviceMenu?.removeFromSuperview(); deviceMenu = nil; deviceButtons.removeAll() }
    private func openDeviceMenu() {
        let menu = SketchSurface(); menu.radius = 10
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let document = NearbyFlippedView()
        deviceButtons = deviceChoices.enumerated().map { index, device in
            let button = NSButton(title: device.name, target: self, action: #selector(chooseDevice(_:)))
            button.tag = index; button.isBordered = false; button.alignment = .left; button.font = .systemFont(ofSize: 14)
            document.addSubview(button); return button
        }
        if deviceButtons.isEmpty {
            let button = NSButton(title: AppLanguage.text("暂无附近设备"), target: nil, action: nil)
            button.isEnabled = false; button.isBordered = false; document.addSubview(button); deviceButtons = [button]
        }
        let height = min(242, CGFloat(deviceButtons.count) * 34 + 12), width = bounds.width - 40
        menu.frame = CGRect(x: 20, y: 104, width: width, height: height)
        scroll.frame = CGRect(x: 6, y: 6, width: width - 12, height: height - 12)
        document.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(deviceButtons.count) * 34)
        for (i, button) in deviceButtons.enumerated() { button.frame = CGRect(x: 8, y: CGFloat(i) * 34, width: document.bounds.width - 16, height: 34) }
        scroll.documentView = document; menu.addSubview(scroll); addSubview(menu); deviceMenu = menu
    }
    @objc private func chooseDevice(_ sender: NSButton) {
        let index = sender.tag; closeDeviceMenu()
        if deviceChoices.indices.contains(index) { service.connect(deviceChoices[index]) }
    }
    @objc private func disconnect() { service.disconnect() }
    @objc private func confirm() { service.incomingInvitation ? service.answer(true) : service.confirmPairing() }
    @objc private func decline() { service.incomingInvitation ? service.answer(false) : service.disconnect() }
    @objc private func changeAutoCopy() { service.autoCopy = autoToggle.state == .on }
    @objc private func openSettings() { onSettings?() }
}

@MainActor private final class NearbyFlippedView: NSView { override var isFlipped: Bool { true } }

@MainActor private final class NearbyDropView: NSView {
    private let service: NearbyTransferService
    private var targeted = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(service: NearbyTransferService) {
        self.service = service; super.init(frame: .zero)
        registerForDraggedTypes([.fileURL]); setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { nil }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        targeted = service.ready; needsDisplay = true; return targeted ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { service.ready ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false; needsDisplay = true
        guard service.ready, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        service.sendFiles(urls); return true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(superview)
        chooseFiles()
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 49), !event.isARepeat { chooseFiles() }
        else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard service.ready else { return false }; chooseFiles(); return true
    }
    private func chooseFiles() {
        guard service.ready else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.service.sendFiles(panel.urls) }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        let path = SketchPencil.outline(in: bounds.insetBy(dx: 2, dy: 2), radius: 14)
        let dash: [CGFloat] = [5, 5]; path.setLineDash(dash, count: 2, phase: 0)
        SketchPencil.stroke(path, color: targeted ? SketchPalette.blue : SketchPalette.line.withAlphaComponent(0.6), width: targeted ? 2 : 1)
        if let art = SketchCardArt.image("folder.badge.person.crop"), bounds.height > 90 {
            art.draw(in: CGRect(x: (bounds.width - 152) / 2, y: 6, width: 152, height: 64),
                     from: CGRect(x: 0, y: 64, width: 256, height: 108), operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let iconSize: CGFloat = bounds.height > 90 ? 56 : 24
            SketchIcons.image(.nearby, size: iconSize).draw(in: CGRect(x: (bounds.width - iconSize) / 2, y: 10, width: iconSize, height: iconSize))
        }
        let text = service.ready ? AppLanguage.text("拖入文件，或 ⌘V 发送") : AppLanguage.text("先连接附近的 Mac")
        let font = SketchPalette.heading(17)
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        (text as NSString).draw(at: CGPoint(x: max(8, (bounds.width - width) / 2), y: bounds.height - 35), withAttributes: [.font: font, .foregroundColor: SketchPalette.ink])
    }
}

@MainActor private final class NearbyTransferRow: NSView {
    let id: UUID
    private let service: NearbyTransferService
    private var record: NearbyTransferRecord
    let primaryAction = NSButton(title: "", target: nil, action: nil)
    private let secondAction = NSButton(title: AppLanguage.text("贴图"), target: nil, action: nil)
    private let name = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    override var isFlipped: Bool { true }
    init(record: NearbyTransferRecord, service: NearbyTransferService) {
        id = record.id; self.record = record; self.service = service; super.init(frame: .zero)
        for view in [name, detail, primaryAction, secondAction] { addSubview(view) }
        name.font = .systemFont(ofSize: 13, weight: .medium); name.textColor = SketchPalette.ink; name.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11); detail.textColor = SketchPalette.muted; detail.lineBreakMode = .byTruncatingTail
        for button in [primaryAction, secondAction] { button.isBordered = false; button.font = SketchPalette.heading(12); button.target = self }
        primaryAction.action = #selector(primary); secondAction.action = #selector(pin)
        update(record)
    }
    required init?(coder: NSCoder) { nil }
    func containsResponder(_ responder: NSResponder?) -> Bool { guard let view = responder as? NSView else { return false }; return view === self || view.isDescendant(of: self) }
    func update(_ record: NearbyTransferRecord) {
        self.record = record; name.stringValue = record.name.replacingOccurrences(of: "\n", with: " "); name.toolTip = record.name
        switch record.state {
        case .sending: detail.stringValue = (record.incoming ? AppLanguage.text("正在接收") : AppLanguage.text("正在发送")) + " · \(record.size == 0 ? 0 : min(100, record.completed * 100 / record.size))%"
        case .received: detail.stringValue = AppLanguage.text("已收到") + " · " + ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file)
        case .sent: detail.stringValue = AppLanguage.text("已发送")
        case .failed: detail.stringValue = AppLanguage.text("传输失败")
        case .cancelled: detail.stringValue = AppLanguage.text("已取消")
        }
        primaryAction.title = record.state == .sending ? AppLanguage.text("取消") : (record.kind == "file" ? "Finder" : AppLanguage.text("复制"))
        primaryAction.isHidden = record.state != .sending && record.state != .received
        secondAction.isHidden = record.state != .received || record.kind != "image" || service.onPin == nil
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout(); let actions: CGFloat = secondAction.isHidden ? 62 : 110
        name.frame = CGRect(x: 40, y: 6, width: max(40, bounds.width - 42 - actions), height: 20)
        detail.frame = CGRect(x: 40, y: 28, width: max(40, bounds.width - 42 - actions), height: 17)
        primaryAction.frame = CGRect(x: bounds.width - actions, y: 17, width: 56, height: 27)
        secondAction.frame = CGRect(x: bounds.width - 52, y: 17, width: 52, height: 27)
    }
    override func draw(_ dirtyRect: NSRect) {
        let symbol = record.kind == "image" ? "photo" : record.kind == "text" ? "text.quote" : "doc"
        if let thumbnail = record.thumbnail {
            let scale = min(32 / CGFloat(thumbnail.width), 36 / CGFloat(thumbnail.height))
            let size = CGSize(width: CGFloat(thumbnail.width) * scale, height: CGFloat(thumbnail.height) * scale)
            NSImage(cgImage: thumbnail, size: size).draw(in: CGRect(x: (34 - size.width) / 2, y: (56 - size.height) / 2, width: size.width, height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else { NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.draw(in: CGRect(x: 3, y: 12, width: 27, height: 30)) }
        let line = NSBezierPath(); line.move(to: CGPoint(x: 0, y: 55)); line.line(to: CGPoint(x: bounds.width, y: 55))
        SketchPencil.stroke(line, color: SketchPalette.line.withAlphaComponent(0.2), width: 0.6)
        if record.state == .sending {
            let progress = record.size == 0 ? 0 : min(1, CGFloat(record.completed) / CGFloat(record.size))
            let base = CGRect(x: 40, y: 48, width: bounds.width - 48, height: 2)
            SketchPalette.line.withAlphaComponent(0.2).setFill(); base.fill()
            let fill = NSBezierPath(roundedRect: CGRect(x: base.minX, y: base.minY, width: base.width * progress, height: 2), xRadius: 1, yRadius: 1)
            SketchPalette.fill(fill, color: SketchPalette.blue)
        }
    }
    @objc private func primary() {
        if record.state == .sending { service.cancel(id) }
        else if record.kind == "file" { service.reveal(id) }
        else { service.copy(id) }
    }
    @objc private func pin() { service.copy(id, pin: true) }
}
