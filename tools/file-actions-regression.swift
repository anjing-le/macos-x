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
    // Real offscreen controls and isolated pasteboard: no desktop or user clipboard.
    let board = NSPasteboard(name: NSPasteboard.Name("file-actions-fixture-" + UUID().uuidString))
    defer { board.releaseGlobally() }
    let service = FileActionService()
    let view = FileActionsView(service: service, clipboard: board)
    precondition(view.accept([source]))
    precondition(view.operations == [.jpeg, .png, .compress, .resize])
    precondition(!view.accept([source, doc]))
    precondition(view.input == source)
    precondition(view.accept([doc]))
    precondition(view.operations == [.markdown, .text])
    for width in [CGFloat(320), 448] {
      view.frame = CGRect(x: 0, y: 0, width: width, height: 470)
      view.layoutSubtreeIfNeeded()
      for sub in view.subviews where !sub.isHidden {
        precondition(sub.frame.minX >= 0 && sub.frame.maxX <= width + 1)
      }
    }
    let key = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
      context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
    board.writeObjects([source as NSURL])
    precondition(view.performKeyEquivalent(with: key))
    precondition(view.input == source)
    if let directory = ProcessInfo.processInfo.environment["FILE_ACTIONS_PREVIEW_DIRECTORY"] {
      try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
      for (name, url) in [("image", source), ("document", doc), ("pdf", pdf)] {
        view.accept([url])
        view.frame = CGRect(x: 0, y: 0, width: 448, height: 470)
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(
          to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
      }
    }
    service.run(
      input: doc, operation: .markdown, options: FileActionOptions(), parent: output,
      helperOverride: document)
    let deadline = Date().addingTimeInterval(8)
    while service.busy && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(!service.busy && service.result != nil)
    let copyKey = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
      context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    precondition(view.performKeyEquivalent(with: copyKey))
    let copied =
      board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL]
    precondition(copied?.first == service.result?.url)
    view.accept([source])
    precondition(service.result == nil)
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
    let module = FileActionsModule()
    module.start()
    module.stop()
    precondition(!module.running)
    print(
      "PASS file actions: real image/Markdown/assets/text/PDF output, transparency, compression fallback, no-overwrite, source preservation, damaged/locked/range/symlink/cancel cleanup, single-file native controls, named pasteboard and offscreen layouts; no Finder automation or live UI"
    )
  }
}
