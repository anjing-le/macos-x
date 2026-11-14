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
/// A contextual menu for one already-selected file. Choosing a leaf executes it;
/// there is no file picker, destination picker, or separate conversion form.
@MainActor final class FileActionsMenu: NSObject {
  private var commands: [FileActionMenuCommand] = []
  var onRun: ((FileActionOperation, FileActionOptions) -> Void)?
  var onCancel: (() -> Void)?
  var onReveal: (() -> Void)?
  func make(input: URL?, busy: Bool = false, message: String = "", result: URL? = nil) -> NSMenu {
    commands.removeAll()
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.font = SketchPalette.heading(15)
    menu.minimumWidth = 236
    func label(_ text: String) {
      let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    if let input { label(input.lastPathComponent) }
    if !message.isEmpty { label(message) }
    if busy {
      add(AppLanguage.text("取消"), to: menu) { [weak self] in self?.onCancel?() }
      return menu
    }
    guard let input else {
      label(AppLanguage.text("请在访达或桌面选中一个文件。"))
      return menu
    }
    let operations = FileActionPolicy.operations(extension: input.pathExtension)
    if operations.isEmpty { label(FileActionFailure.unsupported.message) }
    for operation in operations {
      switch operation {
      case .png, .markdown, .text:
        leaf(operation.title, operation, to: menu)
      case .jpeg:
        let submenu = child(operation.title, in: menu)
        for (title, color) in [(AppLanguage.text("白色底"), "white"), (AppLanguage.text("黑色底"), "black")] {
          var options = FileActionOptions(); options.background = color
          leaf(title, operation, options, to: submenu)
        }
      case .compress:
        let submenu = child(operation.title, in: menu)
        for (title, quality) in [(AppLanguage.text("清晰"), 0.92), (AppLanguage.text("均衡"), 0.82), (AppLanguage.text("更小"), 0.65)] {
          var options = FileActionOptions(); options.quality = quality
          leaf(title, operation, options, to: submenu)
        }
      case .resize:
        let submenu = child(operation.title, in: menu)
        for side in [1280, 1920, 2560] {
          var options = FileActionOptions(); options.longestSide = side
          leaf("\(side) px", operation, options, to: submenu)
        }
      case .pdfImages:
        let submenu = child(operation.title, in: menu)
        leaf(AppLanguage.text("全部页（最多 20 页）"), operation, to: submenu)
        let item = NSMenuItem()
        let entry = FileActionPageEntry()
        entry.onRun = { [weak self, weak menu] pages in
          menu?.cancelTracking()
          var options = FileActionOptions(); options.pages = pages
          self?.onRun?(operation, options)
        }
        item.view = entry
        submenu.addItem(item)
      }
    }
    if result != nil {
      menu.addItem(.separator())
      add("Finder", to: menu) { [weak self] in self?.onReveal?() }
    }
    return menu
  }
  private func child(_ title: String, in menu: NSMenu) -> NSMenu {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let submenu = NSMenu(); submenu.autoenablesItems = false; submenu.font = menu.font
    item.submenu = submenu; menu.addItem(item)
    return submenu
  }
  private func leaf(_ title: String, _ operation: FileActionOperation,
                    _ options: FileActionOptions = FileActionOptions(), to menu: NSMenu) {
    add(title, to: menu) { [weak self] in self?.onRun?(operation, options) }
  }
  private func add(_ title: String, to menu: NSMenu, action: @escaping () -> Void) {
    let command = FileActionMenuCommand(action)
    commands.append(command)
    let item = NSMenuItem(title: title, action: #selector(FileActionMenuCommand.execute), keyEquivalent: "")
    item.target = command
    menu.addItem(item)
  }
}
@MainActor private final class FileActionMenuCommand: NSObject {
  let action: () -> Void
  init(_ action: @escaping () -> Void) { self.action = action }
  @objc func execute() { action() }
}
/// Only PDF page ranges require text entry; this compact row stays in its submenu.
@MainActor final class FileActionPageEntry: NSView {
  let pages = NSTextField(string: "")
  let run = FileActionButton(AppLanguage.text("转换"))
  var onRun: ((String) -> Void)?
  init() {
    super.init(frame: CGRect(x: 0, y: 0, width: 300, height: 76))
    pages.placeholderString = AppLanguage.text("全部页，或 1-3,5（最多 20 页）")
    pages.setAccessibilityLabel(AppLanguage.text("导出页码"))
    pages.frame = CGRect(x: 12, y: 41, width: 276, height: 24)
    run.frame = CGRect(x: 218, y: 6, width: 70, height: 28)
    run.invoke = { [weak self] in guard let self else { return }; self.onRun?(self.pages.stringValue) }
    addSubview(pages); addSubview(run)
  }
  required init?(coder: NSCoder) { nil }
}
