import AppKit
import ImageIO
import MacOSXCore
import PDFKit

@main struct FileActionsRegression {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[2])
    let native = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FileActionsWorker")
    let document = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/FileDocumentWorker")
    let source = root.appendingPathComponent("source.png")
    let context = CGContext(
      data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 0.5))
    context.fill(CGRect(x: 20, y: 20, width: 280, height: 140))
    let dest = CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, context.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(dest))
    let original = try Data(contentsOf: source)
    let output = root.appendingPathComponent("results")
    try fm.createDirectory(at: output, withIntermediateDirectories: true)
    func run(_ input: URL, _ op: FileActionOperation, _ o: FileActionOptions = FileActionOptions())
      throws -> FileActionResult
    {
      try FileActionJob().run(
        input: input, operation: op, options: o,
        helper: op == .markdown || op == .text ? document : native, parent: output)
    }
    let png = try run(source, .png)
    precondition(fm.fileExists(atPath: png.url.path))
    do {
      _ = try run(source, .jpeg)
      preconditionFailure("transparent JPEG accepted without a background")
    } catch FileActionFailure.transparent {}
    var o = FileActionOptions()
    o.background = "white"
    let jpeg = try run(source, .jpeg, o)
    let decoded = CGImageSourceCreateWithURL(jpeg.url as CFURL, nil)!
    let props = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as! [CFString: Any]
    precondition(props[kCGImagePropertyPixelWidth] as? Int == 320)
    let compressed = try run(source, .compress)
    precondition(compressed.outputBytes <= Int64(original.count))
    if compressed.unchanged { precondition((try? Data(contentsOf: compressed.url)) == original) }
    let again = try run(source, .png)
    precondition(again.url != png.url)
    precondition((try? Data(contentsOf: source)) == original)
    let doc = fixtures.appendingPathComponent("rich.docx")
    let docBytes = try Data(contentsOf: doc)
    let md = try run(doc, .markdown)
    let markdownURL = md.url.appendingPathComponent("result.md")
    let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
    precondition(
      markdown.contains("中文不能丢失") && markdown.contains("**重要结论**") && markdown.contains("!["))
    let regex = try NSRegularExpression(pattern: "assets/image-[0-9]+\\.png")
    let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown))
    precondition(!matches.isEmpty)
    for match in matches {
      let path = (markdown as NSString).substring(with: match.range)
      precondition(fm.fileExists(atPath: md.url.appendingPathComponent(path).path))
    }
    let text = try run(doc, .text)
    let txt = try String(contentsOf: text.url, encoding: .utf8)
    precondition(txt.contains("中文不能丢失") && !txt.contains("**重要结论**"))
    precondition((try? Data(contentsOf: doc)) == docBytes)
    for name in [
      "text.doc", "sheet.xls", "pres.ppt", "text.odt", "book.epub", "pres.pptx", "sheet.xlsx",
      "sheet.ods", "pres.odp", "text.rtf", "table.csv",
    ] {
      for op in FileActionPolicy.operations(extension: URL(fileURLWithPath: name).pathExtension) {
        let sample = try run(fixtures.appendingPathComponent(name), op)
        precondition(sample.outputBytes > 0)
      }
    }
    let invalid = root.appendingPathComponent("broken.docx")
    try Data("broken".utf8).write(to: invalid)
    do {
      _ = try run(invalid, .markdown)
      preconditionFailure("broken input succeeded")
    } catch {}
    let pdf = root.appendingPathComponent("sample.pdf")
    var box = CGRect(x: 0, y: 0, width: 320, height: 200)
    let c = CGContext(pdf as CFURL, mediaBox: &box, nil)!
    for _ in 0..<3 {
      c.beginPDFPage(nil)
      c.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.5, alpha: 1))
      c.fill(CGRect(x: 10, y: 10, width: 300, height: 180))
      c.endPDFPage()
    }
    c.closePDF()
    o = FileActionOptions()
    o.pages = "1,3"
    let pages = try run(pdf, .pdfImages, o)
    let pageNames = try fm.contentsOfDirectory(atPath: pages.url.path)
    precondition(pageNames.sorted() == ["page-001.png", "page-003.png"])
    o.pages = "4"
    do {
      _ = try run(pdf, .pdfImages, o)
      preconditionFailure("invalid PDF page accepted")
    } catch FileActionFailure.pages {}
    let locked = root.appendingPathComponent("locked.pdf")
    let pd = PDFDocument(url: pdf)!
    precondition(
      pd.write(
        to: locked, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "password"]))
    do {
      _ = try run(locked, .pdfImages)
      preconditionFailure("locked PDF accepted")
    } catch FileActionFailure.encrypted {}
    let alias = root.appendingPathComponent("alias.png")
    try fm.createSymbolicLink(at: alias, withDestinationURL: source)
    do {
      _ = try run(alias, .png)
      preconditionFailure("symlink accepted")
    } catch FileActionFailure.invalid {}
    let stopped = FileActionJob()
    stopped.cancel()
    do {
      _ = try stopped.run(
        input: source, operation: .png, options: FileActionOptions(), helper: native, parent: output
      )
      preconditionFailure("cancelled job ran")
    } catch FileActionFailure.cancelled {}
    let temporary = try fm.contentsOfDirectory(atPath: output.path).filter {
      $0.hasPrefix(".file-actions-")
    }
    precondition(temporary.isEmpty)
    // Inspect actual native contextual menu without opening it or reading Finder.
    let service = FileActionService()
    let actions = FileActionsMenu()
    var selected: (FileActionOperation, FileActionOptions)?
    actions.onRun = { selected = ($0, $1) }
    func invoke(_ item: NSMenuItem) {
      precondition(item.isEnabled && item.action != nil && item.target != nil)
      precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
    }
    let imageMenu = actions.make(input: source)
    precondition(imageMenu.items.count == 5) // filename + four applicable operations
    invoke(imageMenu.items[2])
    precondition(selected?.0 == .png)
    invoke(imageMenu.items[1].submenu!.items[1])
    precondition(selected?.0 == .jpeg && selected?.1.background == "black")
    invoke(imageMenu.items[3].submenu!.items[2])
    precondition(selected?.0 == .compress && selected?.1.quality == 0.65)
    invoke(imageMenu.items[4].submenu!.items[0])
    precondition(selected?.0 == .resize && selected?.1.longestSide == 1280)
    let documentMenu = actions.make(input: doc)
    precondition(documentMenu.items.count == 3)
    invoke(documentMenu.items[1])
    precondition(selected?.0 == .markdown)
    invoke(documentMenu.items[2])
    precondition(selected?.0 == .text)
    let pdfMenu = actions.make(input: pdf)
    let pdfItems = pdfMenu.items[1].submenu!.items
    invoke(pdfItems[0])
    precondition(selected?.0 == .pdfImages && selected?.1.pages == "")
    let entry = pdfItems[1].view as! FileActionPageEntry
    entry.pages.stringValue = "1,3"
    entry.run.performClick(nil)
    precondition(selected?.0 == .pdfImages && selected?.1.pages == "1,3")
    var cancelled = false
    actions.onCancel = { cancelled = true }
    let busyMenu = actions.make(input: source, busy: true)
    precondition(busyMenu.items.count == 2)
    invoke(busyMenu.items[1]); precondition(cancelled)
    precondition(actions.make(input: nil).items.isEmpty)
    let invalidMenu = actions.make(input: root.appendingPathComponent("unsupported.zip"))
    precondition(invalidMenu.items.isEmpty)
    precondition(FileActionsSelection.supported(source) && FileActionsSelection.supported(doc))
    precondition(!FileActionsSelection.supported(root) && !FileActionsSelection.supported(root.appendingPathComponent("missing.png")))
    // Default output must be beside the original, including collision numbering.
    let beside = try FileActionJob().run(input: source, operation: .png,
      options: FileActionOptions(), helper: native)
    let besideAgain = try FileActionJob().run(input: source, operation: .png,
      options: FileActionOptions(), helper: native)
    precondition(beside.url.deletingLastPathComponent() == source.deletingLastPathComponent())
    precondition(besideAgain.url != beside.url)
    let preservedSource = try Data(contentsOf: source)
    precondition(preservedSource == original)
    precondition(!fm.fileExists(atPath: root.appendingPathComponent(AppLanguage.text("转换结果")).path))
    service.run(input: source, operation: .png, options: FileActionOptions(), helperOverride: native)
    let deadline = Date().addingTimeInterval(8)
    while service.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(!service.busy && service.result?.url.deletingLastPathComponent() == root)
    let delayed = root.appendingPathComponent("delayed-worker")
    try Data("#!/bin/sh\nexec /bin/sleep 20\n".utf8).write(to: delayed)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: delayed.path)
    do {
      _ = try FileActionJob().run(
        input: source, operation: .png, options: FileActionOptions(), helper: delayed,
        parent: output, timeout: 0.05)
      preconditionFailure("timeout did not stop worker")
    } catch FileActionFailure.limit {}
    let active = FileActionJob()
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { completed.signal() }
      do {
        _ = try active.run(
          input: source, operation: .png, options: FileActionOptions(), helper: delayed,
          parent: output)
        preconditionFailure("cancelled worker completed")
      } catch FileActionFailure.cancelled {} catch {
        preconditionFailure("unexpected cancellation result")
      }
    }
    Thread.sleep(forTimeInterval: 0.05)
    active.cancel()
    precondition(completed.wait(timeout: .now() + 2) == .success)
    precondition(
      (try! fm.contentsOfDirectory(atPath: output.path)).allSatisfy {
        !$0.hasPrefix(".file-actions-")
      })
    // Actual shortcut control over the generated board; no visible window or input tap.
    let guidePicker = ShortcutPicker(
      title: "", binding: ShortcutAction.fileActions.defaultBinding, allowsDoubleTap: true,
      recordingChanged: { _ in }, accepts: { _ in nil }, didChange: { _ in })
    let guide = FileActionsGuide(shortcut: guidePicker)
    for width in [CGFloat(312), 840, 912] {
      guide.frame = CGRect(x: 0, y: 0, width: width, height: 468)
      guide.layoutSubtreeIfNeeded()
      let scroll = guide.subviews.compactMap { $0 as? NSScrollView }.first!
      let canvas = scroll.documentView as! FileActionsGuideCanvas
      precondition(canvas.artworkFrame.contains(guidePicker.frame))
      precondition(guidePicker.frame.width > 200)
      let row = guidePicker.arrangedSubviews[0] as! NSStackView
      let mode = row.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first!
      mode.selectItem(at: 4)
      mode.sendAction(mode.action!, to: mode.target)
      guidePicker.layoutSubtreeIfNeeded()
      for control in row.arrangedSubviews where !control.isHidden {
        precondition(guidePicker.bounds.contains(control.convert(control.bounds, to: guidePicker)), "guide width=\(width) picker=\(guidePicker.bounds) row=\(row.frame) control=\(type(of: control)) frame=\(control.convert(control.bounds, to: guidePicker)) fitting=\(guidePicker.fittingSize)")
      }
      mode.selectItem(at: 2)
      mode.sendAction(mode.action!, to: mode.target)
    }
    precondition(guide.subviews.compactMap { $0 as? FileActionButton }.isEmpty)
    if let directory = ProcessInfo.processInfo.environment["FILE_ACTIONS_PREVIEW_DIRECTORY"] {
      guide.frame = CGRect(x: 0, y: 0, width: 840, height: 468)
      guide.layoutSubtreeIfNeeded()
      let bitmap = guide.bitmapImageRepForCachingDisplay(in: guide.bounds)!
      guide.cacheDisplay(in: guide.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("guide.png"))
    }
    // The real source must resolve Finder's selection before counting it.
    precondition(FileActionsFinderQuery.script.contains("set selectedItems to (get selection)"))
    precondition(!FileActionsFinderQuery.script.contains("count of selection"))
    precondition(FileActionsFinderQuery.process().arguments == ["-e", FileActionsFinderQuery.script])
    // Full trigger -> worker -> validated file -> actual menu pipeline, without
    // Finder, real menu presentation, clipboard access or global key events.
    let selectionModule = FileActionsModule()
    selectionModule.finderIsFrontmost = { true }
    var presented: [NSMenu] = []
    selectionModule.presentMenuOverride = { presented.append($0) }
    func fakeSelection(_ url: URL?) -> Process {
      let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
      p.arguments = ["%s", url?.absoluteString ?? ""]
      return p
    }
    selectionModule.selectionProcessFactory = { fakeSelection(source) }
    selectionModule.start()
    selectionModule.summonSelection()
    let selectionDeadline = Date().addingTimeInterval(5)
    while presented.isEmpty && Date() < selectionDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(presented.count == 1 && presented[0].items.count == 5, "Selected image reaches the menu")
    selectionModule.selectionProcessFactory = { fakeSelection(doc) }
    selectionModule.summonSelection()
    let documentDeadline = Date().addingTimeInterval(5)
    while presented.count < 2 && Date() < documentDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(presented.count == 2 && presented[1].items.count == 3, "Selected document reaches its own operations")
    selectionModule.selectionProcessFactory = { fakeSelection(nil) }
    selectionModule.summonSelection()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    precondition(presented.count == 2, "No selection stays silent")
    selectionModule.selectionProcessFactory = { fakeSelection(source) }
    selectionModule.summonSelection()
    selectionModule.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    precondition(presented.count == 2, "Stopping invalidates pending menu presentation")
    let module = FileActionsModule()
    module.start()
    module.stop()
    precondition(!module.running)
    print(
      "PASS file actions: real image/Markdown/assets/text/PDF output, transparency, compression fallback, no-overwrite, source preservation, damaged/locked/range/symlink/cancel cleanup, single-file contextual menu dispatch, original-directory outputs and offscreen layouts; no Finder automation or live UI"
    )
  }
}
