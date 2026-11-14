import AppKit
import Darwin
import MacOSXCore

struct FileActionOptions: Sendable {
  var quality = 0.85
  var longestSide = 1920
  var pages = ""
  var background = "ask"
}
/// Keep the original inode alive until delivery, so stale cleanup cannot delete a replacement.
final class FileActionOutputOwnership: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32
  private let original: stat
  private let url: URL
  init(_ url: URL) throws {
    self.url = url
    descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
    var value = stat()
    guard descriptor >= 0, fstat(descriptor, &value) == 0 else {
      if descriptor >= 0 { close(descriptor) }
      throw FileActionFailure.invalid
    }
    original = value
  }
  func accept() {
    lock.lock()
    defer { lock.unlock() }
    if descriptor >= 0 {
      close(descriptor)
      descriptor = -1
    }
  }
  func discard() {
    lock.lock()
    defer { lock.unlock() }
    guard descriptor >= 0 else { return }
    var current = stat()
    if lstat(url.path, &current) == 0, current.st_ino == original.st_ino,
      current.st_dev == original.st_dev
    {
      try? FileManager.default.removeItem(at: url)
    }
    close(descriptor)
    descriptor = -1
  }
  deinit { if descriptor >= 0 { close(descriptor) } }
}
struct FileActionResult: Sendable {
  let url: URL
  let inputBytes: Int64
  let outputBytes: Int64
  let unchanged: Bool
  let ownership: FileActionOutputOwnership
}
enum FileActionFailure: Error {
  case invalid, limit, cancelled, transparent, encrypted, pages, unavailable, unsupported,
    unsupportedAsset
  var message: String {
    switch self {
    case .invalid: return AppLanguage.text("无法处理这个文件，请检查文件是否完整。")
    case .limit: return AppLanguage.text("文件超过处理上限：16 MB 输入、2400 万图片像素或文档展开预算。")
    case .cancelled: return AppLanguage.text("已取消，原文件未修改。")
    case .transparent: return AppLanguage.text("图片含透明区域，请选择 JPEG 底色。")
    case .encrypted: return AppLanguage.text("请先解锁 PDF，再导出页面。")
    case .pages: return AppLanguage.text("请输入有效页码，例如 1-3,5；每次最多 20 页。")
    case .unavailable: return AppLanguage.text("转换引擎不可用，请重新安装完整客户端。")
    case .unsupportedAsset: return AppLanguage.text("包含暂不支持的嵌入对象，可尝试纯文字。")
    case .unsupported: return AppLanguage.text("这个文件暂不支持转换。")
    }
  }
}
/// Owns only one disposable process. No worker, monitor or polling exists while idle.
final class FileActionJob: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var process: Process?
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func cancel() {
    lock.lock()
    cancelled = true
    let p = process
    lock.unlock()
    if let p, p.isRunning { p.terminate() }
  }
  func run(
    input: URL, operation: FileActionOperation, options: FileActionOptions, helper: URL,
    parent: URL? = nil, timeout: TimeInterval = 30
  ) throws -> FileActionResult {
    let fm = FileManager.default
    let v = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard v.isRegularFile == true, v.isSymbolicLink != true else { throw FileActionFailure.invalid }
    let original = Int64(v.fileSize ?? Int.max)
    guard original > 0, original <= FileActionPolicy.maximumInput else {
      throw FileActionFailure.limit
    }
    guard FileActionPolicy.operations(extension: input.pathExtension).contains(operation) else {
      throw FileActionFailure.unsupported
    }
    guard fm.isExecutableFile(atPath: helper.path) else { throw FileActionFailure.unavailable }
    let folder =
      parent
      ?? input.deletingLastPathComponent().appendingPathComponent(
        AppLanguage.text("转换结果"), isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let stage = folder.appendingPathComponent(
      ".file-actions-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(
      at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: stage) }
    if isCancelled { throw FileActionFailure.cancelled }
    let document = operation == .markdown || operation == .text
    let p = Process()
    p.executableURL = helper
    p.arguments =
      document
      ? [input.path, stage.path, operation.rawValue]
      : [
        input.path, stage.path, operation.rawValue, String(options.quality),
        String(options.longestSide), options.pages, options.background,
      ]
    p.standardOutput = FileHandle.nullDevice
    let errorFile = stage.appendingPathComponent(".stderr")
    fm.createFile(atPath: errorFile.path, contents: nil)
    let stderr = try FileHandle(forWritingTo: errorFile)
    defer { try? stderr.close() }
    p.standardError = stderr
    let terminated = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in terminated.signal() }
    lock.lock()
    process = p
    let alreadyCancelled = cancelled
    lock.unlock()
    if alreadyCancelled { throw FileActionFailure.cancelled }
    try p.run()
    if isCancelled, p.isRunning { p.terminate() }
    let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
    var limited = false
    while terminated.wait(timeout: .now() + 0.1) == .timedOut {
      var info = proc_taskinfo()
      let bytes = withUnsafeMutablePointer(to: &info) {
        proc_pidinfo(
          p.processIdentifier, PROC_PIDTASKINFO, 0, $0, Int32(MemoryLayout<proc_taskinfo>.size))
      }
      if ProcessInfo.processInfo.systemUptime > deadline
        || (bytes > 0 && info.pti_resident_size > 384 * 1024 * 1024)
        || ((try? errorFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 8192
      {
        limited = true
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
      }
      if isCancelled, p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }
    lock.lock()
    process = nil
    lock.unlock()
    if isCancelled { throw FileActionFailure.cancelled }
    if limited { throw FileActionFailure.limit }
    guard p.terminationReason == .exit, p.terminationStatus == 0 else {
      let token =
        (try? String(contentsOf: errorFile, encoding: .utf8))?.split(whereSeparator: \.isNewline)
        .last.map(String.init) ?? ""
      switch token {
      case "transparent": throw FileActionFailure.transparent
      case "encrypted": throw FileActionFailure.encrypted
      case "pages": throw FileActionFailure.pages
      case "limit": throw FileActionFailure.limit
      case "asset": throw FileActionFailure.unsupportedAsset
      case "unsupported": throw FileActionFailure.unsupported
      default: throw FileActionFailure.invalid
      }
    }
    let files = try fm.contentsOfDirectory(
      at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsHiddenFiles])
    guard !files.isEmpty else { throw FileActionFailure.invalid }
    var total: Int64 = 0
    guard
      let contents = fm.enumerator(
        at: stage, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
    else { throw FileActionFailure.invalid }
    for case let file as URL in contents {
      let value = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
      guard value.isSymbolicLink != true else { throw FileActionFailure.invalid }
      total += Int64(value.fileSize ?? 0)
      if total > FileActionPolicy.maximumOutput { throw FileActionFailure.limit }
    }
    let unchanged = fm.fileExists(atPath: stage.appendingPathComponent(".unchanged").path)
    try? fm.removeItem(at: errorFile)
    try? fm.removeItem(at: stage.appendingPathComponent(".unchanged"))
    let single = files.count == 1 && operation != .pdfImages
    var stem = ""
    for ch in input.deletingPathExtension().lastPathComponent {
      if (stem + String(ch)).utf8.count > 160 { break }
      stem.append(ch)
    }
    if stem.isEmpty { stem = "file" }
    let suffix = single ? "." + files[0].pathExtension : ""
    for n in 1...999 {
      if isCancelled { throw FileActionFailure.cancelled }
      let target = folder.appendingPathComponent(
        stem + "-" + operation.rawValue + (n == 1 ? "" : " (\(n))") + suffix)
      do {
        try fm.moveItem(at: single ? files[0] : stage, to: target)
        let ownership = try FileActionOutputOwnership(target)
        if isCancelled {
          ownership.discard()
          throw FileActionFailure.cancelled
        }
        return FileActionResult(
          url: target, inputBytes: original, outputBytes: total, unchanged: unchanged,
          ownership: ownership)
      } catch let error as NSError
        where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
      { continue }
    }
    throw FileActionFailure.invalid
  }
}

@MainActor final class FileActionService {
  var onChange: (() -> Void)?
  private(set) var busy = false
  private(set) var result: FileActionResult?
  private(set) var message = ""
  private var generation = UUID()
  private var job: FileActionJob?
  private let queue = DispatchQueue(label: "macos-x.file-actions", qos: .userInitiated)
  func prepareToTerminate(_ completion: @escaping @MainActor () -> Void) {
    cancel()
    queue.async { DispatchQueue.main.async { completion() } }
  }
  func reset() {
    guard !busy else { return }
    result = nil
    message = ""
  }
  func cancel() {
    generation = UUID()
    job?.cancel()
    job = nil
    busy = false
    message = FileActionFailure.cancelled.message
    onChange?()
  }
  func run(
    input: URL, operation: FileActionOperation, options: FileActionOptions, parent: URL? = nil,
    helperOverride: URL? = nil
  ) {
    guard !busy else { return }
    let document = operation == .markdown || operation == .text
    let helper =
      helperOverride
      ?? Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Helpers/" + (document ? "FileDocumentWorker" : "FileActionsWorker"))
    let next = FileActionJob()
    job = next
    let epoch = UUID()
    generation = epoch
    busy = true
    result = nil
    message = AppLanguage.text("正在处理…")
    onChange?()
    let cleanup = queue
    queue.async { [weak self] in
      let outcome = Result {
        try next.run(
          input: input, operation: operation, options: options, helper: helper, parent: parent)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == epoch else {
          if case .success(let result) = outcome {
            cleanup.async { result.ownership.discard() }
          }
          return
        }
        self.busy = false
        self.job = nil
        switch outcome {
        case .success(let result):
          result.ownership.accept()
          self.result = result
          self.message =
            result.unchanged
            ? AppLanguage.text("未能进一步缩小，已保留原始文件。") : AppLanguage.text("已完成，原文件未修改。")
        case .failure(let error):
          self.message =
            (error as? FileActionFailure)?.message ?? AppLanguage.text("无法保存结果，请选择有写入权限的文件夹。")
        }
        self.onChange?()
      }
    }
  }
}
