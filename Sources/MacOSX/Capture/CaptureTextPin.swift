import AppKit
import UniformTypeIdentifiers

/// A floating read-only document. TextKit keeps tables and inline attributes;
/// only the viewport is drawn during reading. No WebView or remote resources.
@MainActor final class CaptureTextPin: NSObject, CapturePinnedItem, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    let window: NSPanel
    let document: CaptureTextDocument
    let content: Content
    private let clipboard: NSPasteboard
    private static let exportQueue = DispatchQueue(label:"cc.anjing.macos-x.text-pin-export",qos:.userInitiated)
    private static var copyInFlight = false
    private let lifetime = CaptureImageService.Ticket()
    private var closed = false
    private var savePanel: NSSavePanel?
    var onClose: (() -> Void)?
    var onStatus: ((String) -> Void)?
    var isActive: Bool { window.isKeyWindow }
    var recovery: CapturePinRecovery { .text(document,window.frame,content.scroll.contentView.bounds.origin) }

    init(document: CaptureTextDocument, frame: CGRect? = nil, position: NSPoint = .zero, clipboard: NSPasteboard = .general) {
        self.document = document
        self.clipboard = clipboard
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x:0,y:0,width:1100,height:800)
        var width = min(880,max(240,available.width-64))
        let height = min(720,max(180,available.height-64))
        if frame == nil, document.attributed.length < 600 {
            var hasTable = false
            document.attributed.enumerateAttribute(.paragraphStyle,in:NSRange(location:0,length:document.attributed.length)) { value,_,stop in
                if (value as? NSParagraphStyle)?.textBlocks.isEmpty == false { hasTable = true; stop.pointee = true }
            }
            if !hasTable {
                let measured = document.attributed.boundingRect(with:CGSize(width:width-28,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading])
                width = min(width,max(280,measured.width.rounded(.up)+32))
            }
        }
        let rect = frame ?? CGRect(x:available.midX-width/2,y:available.midY-height/2,width:width,height:height)
        content = Content(document:document)
        window = Panel(contentRect:rect,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        super.init()
        window.title = "文字贴图"; window.isReleasedWhenClosed = false; window.delegate = self
        window.animationBehavior = .none; window.level = .floating
        window.isOpaque = true; window.backgroundColor = .white; window.hasShadow = false
        window.hidesOnDeactivate = false; window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        window.contentView = content; window.initialFirstResponder = content.text
        window.setFrame(rect,display:false); content.layoutSubtreeIfNeeded()
        if frame == nil, let manager = content.text.layoutManager, let container = content.text.textContainer {
            let fitted = min(height,max(96,manager.usedRect(for:container).maxY+42))
            window.setFrame(CGRect(x:rect.minX,y:rect.maxY-fitted,width:rect.width,height:fitted),display:false)
            content.layoutSubtreeIfNeeded()
        }
        content.scroll.contentView.scroll(to:position); content.scroll.reflectScrolledClipView(content.scroll.contentView)
        content.onCopy = { [weak self] in self?.copyDocument() }
        content.onSave = { [weak self] in self?.savePDF() }
        content.onClose = { [weak self] in self?.window.close() }
    }
    func present(focus: Bool) {
        guard !closed else { return }
        if focus { window.makeKeyAndOrderFront(nil); window.makeFirstResponder(content.text) }
        else { window.orderFrontRegardless() }
    }
    func setOutline(_ visible: Bool) { content.showsOutline = visible }
    func applyEditIfKey() -> Bool { false }
    func dispose() { onClose = nil; window.close(); if !closed { windowWillClose(Notification(name:NSWindow.willCloseNotification)) } }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true; lifetime.cancel(); savePanel?.cancel(nil); savePanel = nil
        content.onCopy = nil; content.onSave = nil; content.onClose = nil
        onClose?(); onClose = nil; onStatus = nil; window.delegate = nil
    }
    private func copyDocument() {
        guard !closed else { return }
        guard !Self.copyInFlight else { announce("正在准备图文，请稍候。"); return }
        Self.copyInFlight = true
        let image = content.image(), source = document.source, rtf = document.rtf, ticket = lifetime
        content.showStatus("正在准备完整图文…")
        Self.exportQueue.async { [weak self] in
            let png = ticket.valid ? image.flatMap { Content.encodePNG($0) } : nil
            DispatchQueue.main.async {
                Self.copyInFlight = false
                guard let self, !self.closed, ticket.valid else { return }
                // Rich editors get RTF; image destinations get complete PNG;
                // plain editors retain Markdown. Never crop to the viewport.
                let item = NSPasteboardItem(); item.setString(source,forType:.string)
                if let rtf { item.setData(rtf,forType:.rtf) }
                if let png { item.setData(png,forType:.png) }
                item.setData(Data([1]),forType:.init("cc.anjing.macos-x.text-document"))
                self.clipboard.clearContents()
                guard self.clipboard.writeObjects([item]) else { self.announce("复制失败，请重试。"); return }
                self.announce(png == nil ? "已复制完整富文本；长图过大，可导出 PDF。" : "已复制完整图文。")
            }
        }
    }
    private func savePDF() {
        guard !closed, savePanel == nil else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "文字贴图.pdf"
        savePanel = panel
        panel.begin { [weak self] response in
            guard let self, !self.closed else { return }
            self.savePanel = nil
            guard response == .OK, let url = panel.url else { return }
            let data = self.content.text.dataWithPDF(inside:self.content.text.bounds)
            let ticket = self.lifetime
            Self.exportQueue.async { [weak self] in
                guard ticket.valid else { return }
                let saved = (try? data.write(to:url,options:.atomic)) != nil
                DispatchQueue.main.async { if let self, !self.closed, ticket.valid { self.announce(saved ? "已保存完整 PDF。" : "保存失败，请重试。") } }
            }
        }
    }
    func shelve(_ save: @escaping (CGImage, @escaping (Bool) -> Void) -> Void) {
        guard !closed else { return }
        guard let image = content.image() else {
            announce("长图过大，请用 ⌘S 导出完整 PDF。"); return
        }
        save(image) { [weak self] saved in if let self, !self.closed, saved { self.window.close() } }
    }
    private func announce(_ text: String) { content.showStatus(text); onStatus?(text) }

    final class Reader: NSTextView {
        var onCopyAll: (() -> Void)?, onSave: (() -> Void)?, onClose: (() -> Void)?
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.keyCode {
                case 8: copy(nil); return true
                case 1: onSave?(); return true
                case 13: onClose?(); return true
                default: break
                }
            }
            return super.performKeyEquivalent(with:event)
        }
        override func copy(_ sender: Any?) {
            if selectedRange().length > 0 { super.copy(sender) } else { onCopyAll?() }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onClose?(); return }
            if !performKeyEquivalent(with:event) { super.keyDown(with:event) }
        }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = super.menu(for:event) ?? NSMenu()
            menu.addItem(.separator())
            let all = NSMenuItem(title:"复制完整图文",action:#selector(copyAll),keyEquivalent:""); all.target = self; menu.addItem(all)
            let save = NSMenuItem(title:"导出完整 PDF…",action:#selector(exportPDF),keyEquivalent:""); save.target = self; menu.addItem(save)
            return menu
        }
        @objc private func copyAll() { onCopyAll?() }
        @objc private func exportPDF() { onSave?() }
    }

    final class Content: NSView {
        let scroll = NSScrollView(), text = Reader(frame:.zero)
        private let message = NSTextField(labelWithString:"")
        private var dismissal: DispatchWorkItem?
        private var tracking: NSTrackingArea?
        private var hover = false
        var showsOutline = false { didSet { needsDisplay = true; needsLayout = true } }
        var onCopy: (() -> Void)? { didSet { text.onCopyAll = onCopy } }
        var onSave: (() -> Void)? { didSet { text.onSave = onSave } }
        var onClose: (() -> Void)? { didSet { text.onClose = onClose } }
        override var isFlipped: Bool { true }
        init(document: CaptureTextDocument) {
            super.init(frame:.zero)
            scroll.borderType = .noBorder; scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay; scroll.drawsBackground = true; scroll.backgroundColor = .white
            scroll.autohidesScrollers = true
            text.isEditable = false; text.isSelectable = true; text.isRichText = true
            text.drawsBackground = true; text.backgroundColor = .white; text.textColor = NSColor(white:0.16,alpha:1)
            text.textContainerInset = CGSize(width:14,height:8)
            text.textContainer?.lineFragmentPadding = 0
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.minSize = .zero; text.maxSize = CGSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
            text.textStorage?.setAttributedString(document.attributed)
            text.setAccessibilityLabel("文字贴图正文，可滚动和选择文字")
            scroll.documentView = text; addSubview(scroll)
            message.font = NSFont.systemFont(ofSize:11); message.textColor = NSColor(white:0.4,alpha:1)
            message.isHidden = true; addSubview(message)
            toolTip = "顶部拖动移动 · 滚轮阅读 · ⌘C 复制图文 · ⌘S 导出 PDF · ⌘W 关闭"
        }
        required init?(coder:NSCoder) { nil }
        override func layout() {
            super.layout()
            let edge:CGFloat = showsOutline ? 2 : 0
            scroll.frame = CGRect(x:edge,y:20,width:max(0,bounds.width-2*edge),height:max(0,bounds.height-20-edge))
            let width = max(120,scroll.contentSize.width)
            text.setFrameSize(CGSize(width:width,height:max(text.frame.height,scroll.contentSize.height)))
            text.textContainer?.containerSize = CGSize(width:max(1,width-28),height:CGFloat.greatestFiniteMagnitude)
            text.layoutManager?.ensureLayout(for:text.textContainer!)
            let height = text.layoutManager?.usedRect(for:text.textContainer!).maxY ?? 0
            text.setFrameSize(CGSize(width:width,height:max(scroll.contentSize.height,height+20)))
            message.frame = CGRect(x:10,y:2,width:max(0,bounds.width-40),height:16)
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect:.zero,options:[.inVisibleRect,.mouseEnteredAndExited,.activeAlways],owner:self)
            addTrackingArea(area); tracking = area
        }
        override func mouseEntered(with event:NSEvent) { hover = true; needsDisplay = true }
        override func mouseExited(with event:NSEvent) { hover = false; needsDisplay = true }
        override func mouseDown(with event:NSEvent) {
            let point = convert(event.locationInWindow,from:nil)
            if point.y <= 20, point.x >= bounds.width-26 { onClose?() }
            else if point.y <= 20 { window?.performDrag(with:event) }
        }
        override func draw(_ dirtyRect:NSRect) {
            NSColor.white.setFill(); bounds.fill()
            NSColor(white:0.65,alpha:1).setStroke()
            let grip = NSBezierPath(); grip.move(to:CGPoint(x:bounds.midX-12,y:8)); grip.line(to:CGPoint(x:bounds.midX+12,y:8)); grip.lineWidth = 1.5; grip.stroke()
            if hover {
                let close = NSBezierPath(); close.move(to:CGPoint(x:bounds.width-17,y:6)); close.line(to:CGPoint(x:bounds.width-10,y:13))
                close.move(to:CGPoint(x:bounds.width-10,y:6)); close.line(to:CGPoint(x:bounds.width-17,y:13)); close.lineWidth = 1; close.stroke()
            }
            if showsOutline, let context = NSGraphicsContext.current?.cgContext { CapturePinHighlight.draw(in:context,bounds:bounds) }
        }
        func showStatus(_ value:String) {
            dismissal?.cancel(); message.stringValue = value; message.isHidden = false
            let work = DispatchWorkItem { [weak self] in self?.message.isHidden = true }
            dismissal = work; DispatchQueue.main.asyncAfter(deadline:.now()+2.5,execute:work)
        }
        /// Full document only, never the scrolled viewport. Bounded allocation;
        /// larger documents keep rich-text copy and vector PDF without truncation.
        func image() -> CGImage? {
            layoutSubtreeIfNeeded()
            guard text.bounds.width.isFinite, text.bounds.height.isFinite,
                  text.bounds.width <= 16_000, text.bounds.height <= 16_000_000 else { return nil }
            let width = Int(text.bounds.width.rounded(.up)), height = Int(text.bounds.height.rounded(.up))
            guard width > 0, height > 0, width <= 16_000_000 / height else { return nil }
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:width*4,bitsPerPixel:32),
                  let graphics = NSGraphicsContext(bitmapImageRep:bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            NSColor.white.setFill(); NSRect(x:0,y:0,width:width,height:height).fill()
            graphics.cgContext.translateBy(x:0,y:CGFloat(height)); graphics.cgContext.scaleBy(x:1,y:-1)
            // TextKit's glyph drawing also consults isFlipped; a CTM flip
            // alone puts baselines in place but mirrors individual glyphs.
            NSGraphicsContext.current = NSGraphicsContext(cgContext:graphics.cgContext,flipped:true)
            text.layoutManager?.drawBackground(forGlyphRange:NSRange(location:0,length:text.layoutManager?.numberOfGlyphs ?? 0),at:CGPoint(x:14,y:8))
            text.layoutManager?.drawGlyphs(forGlyphRange:NSRange(location:0,length:text.layoutManager?.numberOfGlyphs ?? 0),at:CGPoint(x:14,y:8))
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.cgImage
        }
        func png() -> Data? { image().flatMap { Self.encodePNG($0) } }
        nonisolated static func encodePNG(_ image:CGImage) -> Data? {
            let data = NSMutableData()
            guard let target = CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { return nil }
            CGImageDestinationAddImage(target,image,nil)
            return CGImageDestinationFinalize(target) ? data as Data : nil
        }
    }
}
