import AppKit
import MacOSXCore

@MainActor final class FileActionsModule {
  let service = FileActionService()
  private(set) var running = false
  private var panel: FileActionsPanel?
  private var view: FileActionsView?
  private var selectionProcess: Process?
  private var selectionToken: FileActionJob?
  private var selectionGeneration = UUID()
  private var monitor: Any?
  var beforeOpen: (() -> Void)?
  func start() { running = true }
  func stop() {
    running = false
    selectionGeneration = UUID()
    selectionToken?.cancel()
    selectionToken = nil
    if let p = selectionProcess, p.isRunning { p.terminate() }
    selectionProcess = nil
    service.cancel()
    hide()
    panel = nil
    view = nil
  }
  func prepareToTerminate(_ completion: @escaping @MainActor () -> Void) {
    stop()
    service.prepareToTerminate(completion)
  }
  func hide() {
    if panel?.isVisible == true { panel?.orderOut(nil) }
    if let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }
  func show() {
    guard running else { return }
    if panel == nil {
      let v = FileActionsView(service: service)
      let p = FileActionsPanel(
        contentRect: CGRect(x: 0, y: 0, width: 448, height: 470),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
      p.backgroundColor = .clear
      p.isOpaque = false
      p.hasShadow = true
      p.level = .popUpMenu
      p.hidesOnDeactivate = false
      p.isReleasedWhenClosed = false
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      p.onDismiss = { [weak self] in self?.hide() }
      p.contentView = v
      v.onClose = { [weak self] in self?.hide() }
      view = v
      panel = p
    }
    let point = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
    let w = min(448, area.width - 16)
    let h = min(470, area.height - 16)
    let frame = CGRect(
      x: min(max(area.minX + 8, point.x - 50), area.maxX - w - 8),
      y: min(max(area.minY + 8, point.y - h + 12), area.maxY - h - 8), width: w, height: h)
    beforeOpen?()
    panel?.setFrame(frame, display: true)
    panel?.orderFrontRegardless()
    panel?.makeKey()
    panel?.makeFirstResponder(view)
    view?.refresh()
    if monitor == nil {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
        [weak self] event in
        if let self, event.window !== self.panel { self.hide() }
        return event
      }
    }
  }
  func summonSelection() {
    guard running, !service.busy, selectionProcess == nil else {
      show()
      return
    }
    guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else {
      show()
      view?.notice(AppLanguage.text("请在访达或桌面选中一个文件，或拖入这里。"))
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = [
      "-e",
      "tell application \"Finder\"\nif (count of selection) is not 1 then return \"\"\nreturn URL of item 1 of selection\nend tell",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let epoch = UUID()
    let token = FileActionJob()
    selectionGeneration = epoch
    selectionProcess = process
    selectionToken = token
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var selected: URL?
      do {
        guard !token.isCancelled else { return }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if token.isCancelled { process.terminate() }
        if done.wait(timeout: .now() + 15) == .timedOut {
          process.terminate()
          if done.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            done.wait()
          }
        }
        let data = try pipe.fileHandleForReading.read(upToCount: 8192) ?? Data()
        if process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
            in: .whitespacesAndNewlines), let url = URL(string: text), url.isFileURL
        {
          selected = url
        }
      } catch {}
      let result = selected
      DispatchQueue.main.async { [weak self] in
        guard let self, self.running, self.selectionGeneration == epoch else { return }
        self.selectionProcess = nil
        self.selectionToken = nil
        self.show()
        if let result {
          self.view?.accept([result])
        } else {
          self.view?.notice(AppLanguage.text("请只选中一个文件；如访达访问被拒绝，可直接拖入文件。"))
        }
      }
    }
  }
  func makeGuide(shortcut: NSView) -> NSView {
    let guide = NSStackView()
    guide.orientation = .vertical
    guide.alignment = .centerX
    guide.spacing = 18
    let art = FileActionIllustration()
    art.heightAnchor.constraint(equalToConstant: 150).isActive = true
    art.widthAnchor.constraint(equalToConstant: 260).isActive = true
    let title = NSTextField(labelWithString: AppLanguage.text("选中文件，双击 Command"))
    title.font = SketchPalette.heading(21)
    title.textColor = SketchPalette.ink
    let note = NSTextField(wrappingLabelWithString: AppLanguage.text("一次一个 · 按文件显示操作 · 保留原件"))
    note.alignment = .center
    note.font = .systemFont(ofSize: 13)
    note.textColor = SketchPalette.muted
    let open = FileActionButton(AppLanguage.text("打开文件操作"))
    open.invoke = { [weak self] in self?.show() }
    for v in [art, title, note, shortcut, open] { guide.addArrangedSubview(v) }
    return guide
  }
}
final class FileActionsPanel: NSPanel {
  var onDismiss: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func cancelOperation(_ sender: Any?) { onDismiss?() }
  override func resignKey() {
    super.resignKey()
    if attachedSheet == nil { onDismiss?() }
  }
}
