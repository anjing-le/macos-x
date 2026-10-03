import AppKit

@MainActor
final class SwitcherPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private let panel: NSPanel
    private let canvas = SwitcherCanvas()
    var onChoose: ((CGWindowID) -> Void)? {
        didSet { canvas.onChoose = onChoose }
    }
    var isVisible: Bool { panel.isVisible }
    var displayedWindows: [SwitcherWindow] { canvas.displayedWindows }

    init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = canvas
        panel.isReleasedWhenClosed = false
    }

    func show(windows: [SwitcherWindow], selectedID: CGWindowID?, thumbnails: [CGWindowID: NSImage]) {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let columns = max(1, min(4, Int((area.width - 64) / 220)))
        let rows = max(1, min(3, Int((area.height - 126) / 166)))
        canvas.configure(windows: windows, selectedID: selectedID, thumbnails: thumbnails,
                         columns: columns, capacity: min(12, columns * rows))
        let size = canvas.preferredSize
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func updateSelection(_ selectedID: CGWindowID?, thumbnails: [CGWindowID: NSImage]) {
        canvas.selectedID = selectedID
        canvas.thumbnails = thumbnails
        canvas.needsDisplay = true
    }

    func hide() { panel.orderOut(nil) }
    func clear() { hide(); canvas.configure(windows: [], selectedID: nil, thumbnails: [:], columns: 4, capacity: 12) }
}

@MainActor
private final class SwitcherCanvas: NSView {
    var windows: [SwitcherWindow] = []
    var selectedID: CGWindowID?
    var thumbnails: [CGWindowID: NSImage] = [:]
    var onChoose: ((CGWindowID) -> Void)?
    private var columns = 4
    private var capacity = 12
    override var isFlipped: Bool { true }

    private var pageStart: Int {
        let index = windows.firstIndex(where: { $0.id == selectedID }) ?? 0
        return index / capacity * capacity
    }
    var displayedWindows: [SwitcherWindow] { Array(windows.dropFirst(pageStart).prefix(capacity)) }
    var preferredSize: NSSize {
        let count = min(capacity, windows.count)
        let rows = max(1, (count + columns - 1) / columns)
        return NSSize(width: CGFloat(columns) * 216 + 40, height: CGFloat(rows) * 166 + 90)
    }

    func configure(windows: [SwitcherWindow], selectedID: CGWindowID?, thumbnails: [CGWindowID: NSImage], columns: Int, capacity: Int) {
        self.windows = windows; self.selectedID = selectedID; self.thumbnails = thumbnails; self.columns = columns
        self.capacity = capacity
        needsDisplay = true
    }

    private func cellRect(_ index: Int) -> NSRect {
        NSRect(x: 20 + CGFloat(index % columns) * 216, y: 50 + CGFloat(index / columns) * 166, width: 208, height: 158)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 18, yRadius: 18).fill()
        drawText("窗口切换", in: NSRect(x: 24, y: 17, width: bounds.width - 48, height: 22), font: .boldSystemFont(ofSize: 15), color: .labelColor)
        for (index, window) in displayedWindows.enumerated() {
            let cell = cellRect(index)
            let selected = window.id == selectedID
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.14) : NSColor.controlBackgroundColor).setFill()
            NSBezierPath(roundedRect: cell, xRadius: 10, yRadius: 10).fill()
            if selected {
                NSColor.controlAccentColor.setStroke()
                let outline = NSBezierPath(roundedRect: cell.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
                outline.lineWidth = 2; outline.stroke()
            }
            let preview = NSRect(x: cell.minX + 10, y: cell.minY + 8, width: cell.width - 20, height: 104)
            if let image = thumbnails[window.id] {
                drawImage(image, fitting: preview)
            } else if let icon = window.icon {
                drawImage(icon, fitting: preview.insetBy(dx: 57, dy: 18))
            }
            if let icon = window.icon {
                icon.draw(in: NSRect(x: cell.minX + 10, y: cell.minY + 119, width: 18, height: 18),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            drawText(window.title, in: NSRect(x: cell.minX + 34, y: cell.minY + 117, width: cell.width - 44, height: 18),
                     font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
            drawText(window.applicationName, in: NSRect(x: cell.minX + 10, y: cell.minY + 138, width: cell.width - 20, height: 16),
                     font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        }
        let footer = "Option + Tab 下一窗口 · Shift 反向 · 松开 Option 切换 · Esc 取消    \(windows.count) 个窗口"
        drawText(footer, in: NSRect(x: 24, y: bounds.height - 29, width: bounds.width - 48, height: 17),
                 font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    private func drawImage(_ image: NSImage, fitting rect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let ratio = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, window) in displayedWindows.enumerated() where cellRect(index).contains(point) {
            onChoose?(window.id); return
        }
    }
}
