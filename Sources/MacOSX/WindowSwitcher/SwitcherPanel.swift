import AppKit
import MacOSXCore

/// Nonactivating switch UI. Pixels arrive later; the cached icon cards are
/// immediately navigable and never wait for permission or ScreenCaptureKit.
@MainActor final class SwitcherPanel {
    private final class Panel: NSPanel {
        var acceptsPreviewKeyboard = false
        var onMove: ((Int, Int) -> Void)?
        var onConfirm: (() -> Void)?
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { acceptsPreviewKeyboard }
        override var canBecomeMain: Bool { false }
        override func keyDown(with event: NSEvent) {
            guard acceptsPreviewKeyboard else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 53: onCancel?()
            case 36, 76: onConfirm?()
            case 48: onMove?(event.modifierFlags.contains(.shift) ? -1 : 1, 0)
            case 123: onMove?(-1, 0)
            case 124: onMove?(1, 0)
            case 126: onMove?(0, -1)
            case 125: onMove?(0, 1)
            default: super.keyDown(with: event)
            }
        }
        override func cancelOperation(_ sender: Any?) {
            if acceptsPreviewKeyboard { onCancel?() } else { super.cancelOperation(sender) }
        }
        override func resignKey() { super.resignKey(); if acceptsPreviewKeyboard { onCancel?() } }
    }
    private let panel: Panel
    private let canvas = SwitcherCanvas()
    private let backdrop = SwitcherBackdrop()
    private let scroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let previous = MinimalButton(title: "‹", target: nil, action: nil, style: .quiet)
    private let next = MinimalButton(title: "›", target: nil, action: nil, style: .quiet)
    private var scrollObserver: NSObjectProtocol?
    private var lastSelection: CGWindowID?
    private var lastMode: SwitcherPresentation?
    private var configuring = false
    var onViewportChanged: (() -> Void)?
    var onChoose: ((CGWindowID) -> Void)? { didSet { canvas.onChoose = onChoose } }
    var onHighlight: ((CGWindowID) -> Void)? { didSet { canvas.onHighlight = onHighlight } }
    var onMove: ((Int, Int) -> Void)? { didSet { panel.onMove = onMove } }
    var onConfirm: (() -> Void)? { didSet { panel.onConfirm = onConfirm } }
    var onCancel: (() -> Void)? { didSet { panel.onCancel = onCancel } }
    var isVisible: Bool { panel.isVisible }
    var columnCount: Int { canvas.layout.columns }
    var visibleWindows: [SwitcherWindow] { canvas.visibleWindows }

    init() {
        panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)
        panel.title = "窗口切换"; panel.animationBehavior = .none
        panel.level = .popUpMenu; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false; panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = backdrop; panel.isReleasedWhenClosed = false
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.documentView = canvas; scroll.contentView.postsBoundsChangedNotifications = true
        backdrop.addSubview(scroll); backdrop.addSubview(footer)
        footer.font = .systemFont(ofSize: 12, weight: .medium); footer.textColor = SketchPalette.ink
        for button in [previous, next] {
            button.target = self; button.action = #selector(changePage(_:)); backdrop.addSubview(button)
        }
        previous.tag = -1; next.tag = 1
        previous.setAccessibilityLabel("上一页窗口"); next.setAccessibilityLabel("下一页窗口")
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.configuring, self.panel.isVisible else { return }
                    self.canvas.updateChoices(); self.canvas.needsDisplay = true; self.updateFooter(); self.onViewportChanged?()
                }
            }
    }
    deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
    @objc private func changePage(_ sender: NSButton) {
        panel.onMove?(sender.tag * canvas.layout.capacity, 0)
    }
    private func updateFooter() {
        let count = canvas.windowCount
        if canvas.layout.presentation == .all {
            let indices = canvas.visibleIndices
            let range = indices.first.map { "\($0 + 1)–\((indices.last ?? $0) + 1)" } ?? "0"
            footer.stringValue = "共 \(count) 个窗口 · 当前 \(range)" + (canvas.frame.height > scroll.contentView.bounds.height ? " · 滚动查看更多" : "")
            previous.isHidden = true; next.isHidden = true
        } else {
            let capacity = canvas.layout.capacity
            let page = canvas.currentPageStart / capacity + 1
            let pages = max(1, (count + capacity - 1) / capacity)
            footer.stringValue = "共 \(count) 个窗口 · 第 \(page) / \(pages) 页" + (pages > 1 ? " · Tab 继续切换" : "")
            previous.isHidden = pages == 1; next.isHidden = pages == 1
        }
    }

    func show(windows: [SwitcherWindow], selectedID: CGWindowID?, thumbnails: [CGWindowID: CGImage], preview: Bool, presentation: SwitcherPresentation = .twoRows) {
        configuring = true; defer { configuring = false }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let layout = SwitcherLayout(windowCount: windows.count, available: area.size, presentation: presentation)
        let selectedIndex = windows.firstIndex { $0.id == selectedID } ?? 0
        let size = presentation == .all ? layout.size : layout.pageSize(visibleCount: windows.count - layout.pageStart(selectedIndex: selectedIndex))
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        let previousOffset = scroll.contentView.bounds.origin
        scroll.hasVerticalScroller = presentation == .all
        scroll.frame = CGRect(x: 0, y: 38, width: size.width, height: size.height - 38)
        let documentSize = layout.pageSize(visibleCount: presentation == .all ? windows.count : windows.count - layout.pageStart(selectedIndex: selectedIndex))
        canvas.frame = CGRect(x: 0, y: 0, width: size.width, height: documentSize.height - 38)
        canvas.configure(windows, selectedID, layout, thumbnails)
        if presentation == .all {
            scroll.contentView.scroll(to: previousOffset)
            if selectedID != lastSelection || presentation != lastMode {
                canvas.scrollToVisible(layout.card(at: selectedIndex).insetBy(dx: -4, dy: -4))
            }
        } else { scroll.contentView.scroll(to: .zero) }
        scroll.reflectScrolledClipView(scroll.contentView)
        canvas.updateChoices()
        lastSelection = selectedID; lastMode = presentation
        footer.frame = CGRect(x: 16, y: 11, width: size.width - 32 - (presentation == .twoRows && windows.count > layout.capacity ? 76 : 0), height: 18)
        previous.frame = CGRect(x: size.width - 82, y: 5, width: 32, height: 28)
        next.frame = CGRect(x: size.width - 46, y: 5, width: 32, height: 28)
        updateFooter()
        panel.ignoresMouseEvents = false
        panel.acceptsPreviewKeyboard = preview
        if preview && !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(nil) }
        else { panel.orderFrontRegardless() }
    }
    func freezeForCapture() { panel.acceptsPreviewKeyboard = false; panel.ignoresMouseEvents = true }
    func hide() { panel.acceptsPreviewKeyboard = false; panel.orderOut(nil); canvas.clearImages(); lastSelection = nil; lastMode = nil }
    func clear() { hide(); canvas.configure([], nil, canvas.layout, [:]) }
}

@MainActor private final class SwitcherBackdrop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        SketchPalette.paper.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18).fill()
        SketchPencil.stroke(SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 18), color: SketchPalette.line, width: 1)
    }
}

@MainActor final class SwitcherCanvas: NSView {
    private final class ChoiceButton: NSButton {
        override func draw(_ dirtyRect: NSRect) {} // Canvas paints one consistent card.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    private var windows: [SwitcherWindow] = []
    private var selectedID: CGWindowID?
    private var images: [CGWindowID: NSImage] = [:]
    private var choices: [ChoiceButton] = []
    private var tracking: NSTrackingArea?
    private(set) var layout = SwitcherLayout(windowCount: 1, available: CGSize(width: 1200, height: 800))
    var onChoose: ((CGWindowID) -> Void)?
    var onHighlight: ((CGWindowID) -> Void)?
    override var isFlipped: Bool { true }
    private var pageStart: Int { layout.pageStart(selectedIndex: windows.firstIndex { $0.id == selectedID } ?? 0) }
    var windowCount: Int { windows.count }
    var currentPageStart: Int { pageStart }
    var visibleIndices: [Int] {
        layout.visibleIndices(in: visibleRect, count: page.count)
    }
    var visibleWindows: [SwitcherWindow] { visibleIndices.map { page[$0] } }
    var page: [SwitcherWindow] { Array(windows.dropFirst(pageStart).prefix(layout.capacity)) }

    func configure(_ windows: [SwitcherWindow], _ selectedID: CGWindowID?, _ layout: SwitcherLayout, _ thumbnails: [CGWindowID: CGImage]) {
        self.windows = windows; self.selectedID = selectedID; self.layout = layout
        images = Dictionary(uniqueKeysWithValues: thumbnails.map {
            ($0.key, NSImage(cgImage: $0.value, size: CGSize(width: $0.value.width, height: $0.value.height)))
        })
        updateChoices()
        needsDisplay = true
        setAccessibilityLabel("窗口切换")
        setAccessibilityValue(windows.first { $0.id == selectedID }.map { $0.applicationName + "，" + $0.title })
    }
    func updateChoices() {
        let indices = visibleIndices
        let current = page
        let visible = indices.map { current[$0] }
        while choices.count < visible.count {
            let button = ChoiceButton(frame: layout.card(at: choices.count))
            button.title = ""; button.isBordered = false; button.focusRingType = .none
            button.setButtonType(.momentaryPushIn); button.target = self; button.action = #selector(choose(_:))
            addSubview(button); choices.append(button)
        }
        for (index, button) in choices.enumerated() {
            button.isHidden = index >= visible.count
            guard index < visible.count else { continue }
            let window = visible[index]
            button.frame = layout.card(at: indices[index])
            button.tag = Int(window.id); button.toolTip = window.title
            button.setAccessibilityLabel(window.applicationName + "，" + window.title)
            button.setAccessibilityValue(window.id == selectedID ? "已选中" : "")
        }
    }
    func clearImages() { images.removeAll() }
    @objc private func choose(_ sender: NSButton) { onChoose?(CGWindowID(sender.tag)) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, window) in page.enumerated() where layout.card(at: index).contains(point) {
            if window.id != selectedID { onHighlight?(window.id) }; return
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 32, bounds.height > 25 else { return }
        for (index, window) in page.enumerated() where layout.card(at: index).intersects(dirtyRect) {
            let rect = layout.card(at: index), selected = window.id == selectedID
            let outline = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            SketchPalette.paper.setFill(); outline.fill()
            SketchPencil.stroke(SketchPencil.outline(in: rect, radius: 10), color: selected ? SketchPalette.yellow : SketchPalette.line.withAlphaComponent(0.4), width: selected ? 1.8 : 0.75)
            let picture = CGRect(x: rect.minX + 10, y: rect.minY + 10, width: rect.width - 20, height: rect.height - 48)
            if let image = images[window.id] {
                let ratio = min(picture.width / max(1, image.size.width), picture.height / max(1, image.size.height))
                let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                image.draw(in: CGRect(x: picture.midX - size.width / 2, y: picture.midY - size.height / 2,
                                      width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            } else if let icon = window.icon {
                icon.draw(in: CGRect(x: picture.midX - 26, y: picture.midY - 26, width: 52, height: 52),
                          from: .zero, operation: .sourceOver, fraction: window.isMinimized || window.isHidden ? 0.65 : 1,
                          respectFlipped: true, hints: nil)
            }
            window.icon?.draw(in: CGRect(x: rect.minX + 10, y: rect.maxY - 27, width: 16, height: 16),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            text(window.applicationName, rect: CGRect(x: rect.minX + 32, y: rect.maxY - 33, width: rect.width - 42, height: 14),
                 font: .systemFont(ofSize: 11, weight: .medium), color: SketchPalette.ink)
            text(window.title == window.applicationName ? "" : window.title,
                 rect: CGRect(x: rect.minX + 32, y: rect.maxY - 19, width: rect.width - 42, height: 13),
                 font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
            let badge = window.isMinimized ? "最小化" : window.isHidden ? "隐藏" : !window.isOnScreen ? "未显示" : ""
            if !badge.isEmpty {
                text(badge, rect: CGRect(x: picture.minX + 4, y: picture.minY + 2, width: picture.width - 8, height: 16),
                     font: .systemFont(ofSize: 9), color: .secondaryLabelColor)
            }
        }

    }
    private func text(_ value: String, rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail; style.alignment = alignment
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}
