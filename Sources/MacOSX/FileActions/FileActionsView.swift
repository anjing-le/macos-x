import AppKit
import MacOSXCore

@MainActor final class FileActionButton: MinimalButton {
  var invoke: (() -> Void)?
  init(_ title: String, _ invoke: (() -> Void)? = nil) {
    self.invoke = invoke
    super.init(frame: .zero)
    self.title = title
    self.style = .standard
    target = self
    action = #selector(fire)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func fire() { invoke?() }
}
@MainActor final class FileActionsView: NSView, NSDraggingSource {
  let service: FileActionService
  private let clipboard: NSPasteboard
  var onClose: (() -> Void)?
  private(set) var input: URL?
  private(set) var operations: [FileActionOperation] = []
  private var current: FileActionOperation = .compress
  private let heading = NSTextField(labelWithString: AppLanguage.text("文件操作"))
  private let close = FileActionButton("×")
  private let file = NSTextField(wrappingLabelWithString: AppLanguage.text("拖入一个文件，或按 ⌘V"))
  private let choose = FileActionButton(AppLanguage.text("选择文件"))
  private var actions: [FileActionButton] = []
  private let quality = MinimalPopUpButton()
  private let size = MinimalPopUpButton()
  private let background = MinimalPopUpButton()
  private let pages = NSTextField(string: "")
  private let convert = FileActionButton(AppLanguage.text("转换"))
  private let cancel = FileActionButton(AppLanguage.text("取消"))
  private let destination = FileActionButton(AppLanguage.text("保存位置…"))
  private let copy = FileActionButton(AppLanguage.text("复制文件"))
  private let reveal = FileActionButton("Finder")
  private let resultLabel = NSTextField(wrappingLabelWithString: "")
  private let status = NSTextField(
    wrappingLabelWithString: AppLanguage.text("一次一个文件 · 本地处理 · 保留原件"))
  private var outputParent: URL?
  private var down: CGPoint?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(service: FileActionService, clipboard: NSPasteboard = .general) {
    self.service = service
    self.clipboard = clipboard
    super.init(frame: .zero)
    registerForDraggedTypes([.fileURL])
    heading.font = SketchPalette.heading(23)
    heading.textColor = SketchPalette.ink
    file.font = .systemFont(ofSize: 14, weight: .medium)
    file.maximumNumberOfLines = 2
    file.lineBreakMode = .byTruncatingMiddle
    resultLabel.font = .systemFont(ofSize: 12)
    resultLabel.textColor = SketchPalette.ink
    resultLabel.maximumNumberOfLines = 2
    status.font = .systemFont(ofSize: 12)
    status.textColor = SketchPalette.muted
    status.maximumNumberOfLines = 3
    quality.addItems(withTitles: [
      AppLanguage.text("清晰"), AppLanguage.text("均衡"), AppLanguage.text("更小"),
    ])
    quality.selectItem(at: 1)
    size.addItems(withTitles: ["1280 px", "1920 px", "2560 px"])
    size.selectItem(at: 1)
    background.addItems(withTitles: [
      AppLanguage.text("透明底：先不转换"), AppLanguage.text("白色底"), AppLanguage.text("黑色底"),
    ])
    for control in [quality, size, background] {
      control.target = self
      control.action = #selector(optionsChanged)
    }
    quality.setAccessibilityLabel(AppLanguage.text("图片质量"))
    size.setAccessibilityLabel(AppLanguage.text("最长边"))
    background.setAccessibilityLabel(AppLanguage.text("JPEG 底色"))
    pages.placeholderString = AppLanguage.text("全部页，或 1-3,5（最多 20 页）")
    pages.setAccessibilityLabel(AppLanguage.text("导出页码"))
    choose.invoke = { [weak self] in self?.chooseFile() }
    convert.invoke = { [weak self] in self?.run() }
    cancel.invoke = { [weak self] in self?.service.cancel() }
    close.invoke = { [weak self] in self?.onClose?() }
    copy.invoke = { [weak self] in self?.copyResult() }
    reveal.invoke = { [weak self] in
      if let url = self?.service.result?.url {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
    destination.invoke = { [weak self] in self?.chooseDestination() }
    for v in [
      heading, close, file, choose, quality, size, background, pages, convert, cancel, destination,
      copy, reveal, resultLabel, status,
    ] { addSubview(v) }
    service.onChange = { [weak self] in self?.refresh() }
    refresh()
  }
  required init?(coder: NSCoder) { nil }
  func notice(_ text: String) {
    status.stringValue = text
    needsLayout = true
  }
  @discardableResult func accept(_ urls: [URL]) -> Bool {
    guard !service.busy, urls.count == 1, urls[0].isFileURL else {
      notice(AppLanguage.text("每次只处理一个文件。"))
      return false
    }
    service.reset()
    input = urls[0]
    operations = FileActionPolicy.operations(extension: urls[0].pathExtension)
    current = operations.first ?? .compress
    outputParent = nil
    file.stringValue = urls[0].lastPathComponent
    actions.forEach { $0.removeFromSuperview() }
    actions = []
    for op in operations {
      let b = FileActionButton(op.title)
      b.invoke = { [weak self] in
        self?.current = op
        self?.refresh()
      }
      actions.append(b)
      addSubview(b)
    }
    status.stringValue =
      operations.isEmpty
      ? FileActionFailure.unsupported.message : AppLanguage.text("选择操作，结果保存为新文件。")
    refresh()
    return !operations.isEmpty
  }
  func refresh() {
    let busy = service.busy
    for (i, b) in actions.enumerated() {
      b.isEnabled = !busy
      b.contentTintColor = operations[i] == current ? SketchPalette.blue : SketchPalette.ink
    }
    choose.isEnabled = !busy
    convert.isEnabled = !busy && input != nil && !operations.isEmpty
    destination.isEnabled = !busy
    cancel.isHidden = !busy
    quality.isHidden = ![.jpeg, .compress, .resize].contains(current) || operations.isEmpty
    size.isHidden = current != .resize || operations.isEmpty
    background.isHidden = current != .jpeg || operations.isEmpty
    pages.isHidden = current != .pdfImages || operations.isEmpty
    for control in [quality, size, background, pages] as [NSControl] { control.isEnabled = !busy }
    let result = service.result
    copy.isHidden = result == nil
    reveal.isHidden = result == nil
    if let result {
      let a = ByteCountFormatter.string(fromByteCount: result.inputBytes, countStyle: .file)
      let b = ByteCountFormatter.string(fromByteCount: result.outputBytes, countStyle: .file)
      resultLabel.stringValue = result.url.lastPathComponent + "\n" + a + " → " + b
    } else {
      resultLabel.stringValue = ""
    }
    if !service.message.isEmpty { status.stringValue = service.message }
    needsLayout = true
    needsDisplay = true
  }
  override func layout() {
    super.layout()
    let w = max(240, bounds.width)
    let inset: CGFloat = 22
    let content = w - 44
    heading.frame = CGRect(x: inset, y: 18, width: content - 42, height: 32)
    close.frame = CGRect(x: w - 50, y: 18, width: 28, height: 28)
    file.frame = CGRect(x: inset + 10, y: 72, width: content - 116, height: 50)
    choose.frame = CGRect(x: w - 128, y: 78, width: 94, height: 32)
    let gap: CGFloat = 10
    let cell = (content - gap) / 2
    for (i, b) in actions.enumerated() {
      b.frame = CGRect(
        x: inset + CGFloat(i % 2) * (cell + gap), y: 140 + CGFloat(i / 2) * 42, width: cell,
        height: 32)
    }
    let y: CGFloat = operations.count > 2 ? 232 : 190
    quality.frame = CGRect(x: inset, y: y, width: 120, height: 30)
    size.frame = CGRect(x: inset + 130, y: y, width: content - 130, height: 30)
    background.frame = CGRect(x: inset + 130, y: y, width: content - 130, height: 30)
    pages.frame = CGRect(x: inset, y: y, width: content, height: 30)
    destination.frame = CGRect(x: inset, y: y + 42, width: 120, height: 30)
    convert.frame = CGRect(x: w - 128, y: y + 42, width: 106, height: 32)
    cancel.frame = CGRect(x: w - 208, y: y + 42, width: 70, height: 32)
    resultLabel.frame = CGRect(x: inset, y: y + 86, width: content - 142, height: 48)
    copy.frame = CGRect(x: w - 158, y: y + 86, width: 80, height: 30)
    reveal.frame = CGRect(x: w - 74, y: y + 86, width: 52, height: 30)
    status.frame = CGRect(x: inset, y: bounds.height - 72, width: content, height: 54)
  }
  override func draw(_ dirtyRect: NSRect) {
    SketchPalette.paper.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16).fill()
    SketchPencil.stroke(
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 15, yRadius: 15),
      color: SketchPalette.ink.withAlphaComponent(0.6), width: 1.2)
    SketchPencil.stroke(
      NSBezierPath(
        roundedRect: CGRect(x: 22, y: 64, width: bounds.width - 44, height: 64), xRadius: 8,
        yRadius: 8), color: SketchPalette.muted, width: 1)
  }
  private func chooseFile() {
    let p = NSOpenPanel()
    p.canChooseDirectories = false
    p.allowsMultipleSelection = false
    guard let window else { return }
    p.beginSheetModal(for: window) { [weak self] response in
      if response == .OK, let url = p.url { self?.accept([url]) }
    }
  }
  private func chooseDestination() {
    let p = NSOpenPanel()
    p.canChooseDirectories = true
    p.canChooseFiles = false
    p.allowsMultipleSelection = false
    guard let window else { return }
    p.beginSheetModal(for: window) { [weak self] response in
      if response == .OK {
        self?.outputParent = p.url
        self?.destination.toolTip = p.url?.path
      }
    }
  }
  private func run() {
    guard let input else { return }
    var options = FileActionOptions()
    options.quality = [0.92, 0.82, 0.65][max(0, quality.indexOfSelectedItem)]
    options.longestSide = [1280, 1920, 2560][max(0, size.indexOfSelectedItem)]
    options.background = ["ask", "white", "black"][max(0, background.indexOfSelectedItem)]
    options.pages = pages.stringValue
    service.run(input: input, operation: current, options: options, parent: outputParent)
  }
  @objc private func optionsChanged() { refresh() }
  private func copyResult() {
    guard let result = service.result else { return }
    clipboard.clearContents()
    clipboard.writeObjects([result.url as NSURL])
  }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onClose?()
      return
    }
    if event.keyCode == 36 {
      run()
      return
    }
    super.keyDown(with: event)
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    if service.result != nil, resultLabel.frame.contains(point) { return self }
    return super.hitTest(point)
  }
  override func resetCursorRects() {
    super.resetCursorRects()
    if service.result != nil { addCursorRect(resultLabel.frame, cursor: .openHand) }
  }
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if window?.firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
    if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
      if event.keyCode == 9 {
        let p = clipboard
        guard (p.pasteboardItems?.count ?? 0) == 1 else {
          notice(AppLanguage.text("每次只处理一个文件。"))
          return true
        }
        let urls =
          p.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
          as? [URL] ?? []
        accept(urls)
        return true
      }
      if event.keyCode == 8, service.result != nil {
        copyResult()
        return true
      }
    }
    return super.performKeyEquivalent(with: event)
  }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    service.busy ? [] : .copy
  }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    let p = sender.draggingPasteboard
    guard (p.pasteboardItems?.count ?? 0) == 1 else {
      notice(AppLanguage.text("每次只处理一个文件。"))
      return false
    }
    return accept(
      p.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        ?? [])
  }
  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    down = resultLabel.frame.contains(point) ? point : nil
    window?.makeFirstResponder(self)
  }
  override func mouseDragged(with event: NSEvent) {
    guard let down, let result = service.result,
      abs(event.locationInWindow.x - down.x) + abs(event.locationInWindow.y - down.y) > 5
    else { return }
    let item = NSDraggingItem(pasteboardWriter: result.url as NSURL)
    let icon =
      NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
      ?? NSImage(size: NSSize(width: 32, height: 32))
    item.setDraggingFrame(CGRect(origin: down, size: NSSize(width: 32, height: 32)), contents: icon)
    self.down = nil
    beginDraggingSession(with: [item], event: event, source: self)
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .copy }
}
