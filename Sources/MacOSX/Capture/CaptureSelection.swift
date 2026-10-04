import AppKit

@MainActor
final class CaptureSelection {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
    private var panels: [NSPanel] = []
    private var views: [SelectionView] = []
    private var startPoint: CGPoint?
    private var selection = CGRect.null
    private var completion: ((CGRect?) -> Void)?

    func present(_ frames: [CaptureFrame], completion: @escaping (CGRect?) -> Void) {
        dismiss()
        self.completion = completion
        for frame in frames {
            let panel = Panel(contentRect: frame.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let view = SelectionView(frame: CGRect(origin: .zero, size: frame.screen.frame.size), snapshot: frame)
            view.selection = { [weak self] in self?.selection ?? .null }
            view.onDown = { [weak self] point in self?.startPoint = point; self?.selection = .null; self?.redraw() }
            view.onDrag = { [weak self] point in
                guard let self, let start = self.startPoint else { return }
                self.selection = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                                        width: abs(start.x - point.x), height: abs(start.y - point.y))
                self.redraw()
            }
            view.onConfirm = { [weak self] fullScreen in
                guard let self else { return }
                let chosen = fullScreen || self.selection.isNull || self.selection.width < 2 || self.selection.height < 2
                    ? frame.screen.frame : self.selection
                self.finish(chosen)
            }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panel.orderFrontRegardless()
            panels.append(panel); views.append(view)
        }
        if let index = frames.firstIndex(where: { $0.screen.frame.contains(NSEvent.mouseLocation) }) {
            panels[index].makeKeyAndOrderFront(nil)
        } else { panels.first?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        completion = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll(); views.removeAll(); startPoint = nil; selection = .null
    }
    private func redraw() { views.forEach { $0.needsDisplay = true } }
    private func finish(_ region: CGRect?) {
        let callback = completion
        dismiss()
        callback?(region)
    }
}

@MainActor
private final class SelectionView: NSView {
    private let snapshot: CaptureFrame
    var selection: (() -> CGRect)?
    var onDown: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onConfirm: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect, snapshot: CaptureFrame) { self.snapshot = snapshot; super.init(frame: frame) }
    required init?(coder: NSCoder) { nil }
    private func global(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? .zero }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 { onConfirm?(true) } else { onDown?(global(event)) }
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(global(event)) }
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount < 2 else { return }
        onDrag?(global(event)); onConfirm?(false)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else if event.keyCode == 36 || event.keyCode == 76 { onConfirm?(false) }
        else if event.keyCode == 3 { onConfirm?(true) }
        else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: snapshot.image, size: snapshot.screen.frame.size).draw(in: bounds)
        let globalSelection = selection?() ?? .null
        let overlap = globalSelection.intersection(snapshot.screen.frame)
        let local = overlap.offsetBy(dx: -snapshot.screen.frame.minX, dy: -snapshot.screen.frame.minY)
        let shade = NSBezierPath(rect: bounds)
        if !overlap.isNull { shade.appendRect(local) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.38).setFill(); shade.fill()
        if !overlap.isNull {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: local); outline.lineWidth = 2; outline.stroke()
        }
        let tip = "拖动选择区域 · Enter 当前屏全屏 · F 全屏 · Esc 取消"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = (tip as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - 70, width: size.width, height: size.height)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: -15, dy: -10), xRadius: 9, yRadius: 9).fill()
        (tip as NSString).draw(in: rect, withAttributes: attributes)
    }
}
