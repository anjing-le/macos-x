import AppKit
import MacOSXCore
import os

enum FileActionsSelection {
  // Called only on the selection worker, never from the input callback.
  static func supported(_ url: URL) -> Bool {
    guard url.isFileURL, !FileActionPolicy.operations(extension: url.pathExtension).isEmpty,
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
      values.isRegularFile == true, values.isSymbolicLink != true else { return false }
    let size = Int64(values.fileSize ?? 0)
    return size > 0 && size <= FileActionPolicy.maximumInput
  }
}

enum FileActionsFinderQuery {
  // Finder's `count of selection` is a remote count specifier, not a count
  // of the resolved selection list. Resolve once before checking and indexing.
  static let script = """
    tell application id "com.apple.finder"
      set selectedItems to (get selection)
      if (count of selectedItems) is not 1 then return ""
      set selectedItem to item 1 of selectedItems
      return (get URL of selectedItem) as text
    end tell
    """
  static func process() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    return process
  }
}

@MainActor final class FileActionsModule {
  let service = FileActionService()
  private(set) var running = false
  private var menu: NSMenu?
  private let actions = FileActionsMenu()
  private var input: URL?
  private var selectionProcess: Process?
  private var selectionToken: FileActionJob?
  private var selectionGeneration = UUID()
  var beforeOpen: (() -> Void)?
  var finderIsFrontmost: () -> Bool = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" }
  var selectionProcessFactory: () -> Process = FileActionsFinderQuery.process
  var presentMenuOverride: ((NSMenu) -> Void)?
  private let logger = Logger(subsystem: "cc.anjing.macos-x", category: "file-actions-selection")
  func start() {
    running = true
    service.onChange = { [weak self] in
      guard let self, self.running, !self.service.busy,
        self.service.result == nil, !self.service.message.isEmpty,
        self.service.message != FileActionFailure.cancelled.message else { return }
      // A failed command must have a visible outcome, never a blank form.
      self.show()
    }
  }
  func stop() {
    running = false
    selectionGeneration = UUID()
    selectionToken?.cancel()
    selectionToken = nil
    if let p = selectionProcess, p.isRunning { p.terminate() }
    selectionProcess = nil
    service.cancel()
    hide()
    menu = nil
    input = nil
  }
  func prepareToTerminate(_ completion: @escaping @MainActor () -> Void) {
    stop()
    service.prepareToTerminate(completion)
  }
  func hide() { menu?.cancelTracking(); menu = nil }
  func show() {
    guard running else { return }
    hide()
    actions.onRun = { [weak self] operation, options in
      guard let self, let input = self.input, self.running, !self.service.busy else { return }
      self.service.run(input: input, operation: operation, options: options)
    }
    actions.onCancel = { [weak self] in self?.service.cancel() }
    actions.onReveal = { [weak self] in
      if let result = self?.service.result { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
    }
    let menu = actions.make(input: input, busy: service.busy,
      message: service.message, result: service.result?.url)
    self.menu = menu
    guard !menu.items.isEmpty else { self.menu = nil; return }
    beforeOpen?()
    if let presentMenuOverride { presentMenuOverride(menu) }
    else { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
  }
  func summonSelection() {
    guard running else { return }
    if service.busy { show(); return }
    guard selectionProcess == nil else { return }
    input = nil
    service.reset()
    guard finderIsFrontmost() else {
      show()
      return
    }
    let process = selectionProcessFactory()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let epoch = UUID()
    let token = FileActionJob()
    selectionGeneration = epoch
    selectionProcess = process
    selectionToken = token
    let logger = self.logger
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
        logger.info("Finder query exited status=\(process.terminationStatus) bytes=\(data.count)")
        if process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
            in: .whitespacesAndNewlines), let url = URL(string: text), url.isFileURL
        {
          if FileActionsSelection.supported(url) { selected = url }
        }
      } catch { logger.error("Finder query failed before receiving a selection") }
      logger.info("Finder query selectedSupportedFile=\(selected != nil)")
      let result = selected
      DispatchQueue.main.async { [weak self] in
        guard let self, self.running, self.selectionGeneration == epoch else { return }
        self.selectionProcess = nil
        self.selectionToken = nil
        self.input = result
        self.show()
      }
    }
  }
  func makeGuide(shortcut: NSView) -> NSView {
    FileActionsGuide(shortcut: shortcut)
  }
}
