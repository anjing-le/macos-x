import Foundation

public enum FileActionOperation: String, CaseIterable, Sendable {
  case jpeg, png, compress, resize, markdown, text, pdfImages
  public var title: String {
    switch self {
    case .jpeg: return AppLanguage.text("转为 JPEG")
    case .png: return AppLanguage.text("转为 PNG")
    case .compress: return AppLanguage.text("压缩图片")
    case .resize: return AppLanguage.text("缩小尺寸")
    case .markdown: return "Markdown"
    case .text: return AppLanguage.text("纯文字")
    case .pdfImages: return AppLanguage.text("导出 PDF 页面")
    }
  }
}
public enum FileActionPolicy {
  public static let maximumInput: Int64 = 16 * 1024 * 1024
  public static let maximumOutput: Int64 = 64 * 1024 * 1024
  public static let maximumPixels = 24_000_000
  public static let maximumPages = 20
  public static let documentExtensions: Set<String> = [
    "doc", "docx", "rtf", "odt", "ppt", "pptx", "xls", "xlsx", "ods", "odp", "csv", "epub",
  ]
  public static func operations(extension ext: String) -> [FileActionOperation] {
    let ext = ext.lowercased()
    if ext == "odp" { return [.text] }
    if ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "webp"].contains(ext) {
      return [.jpeg, .png, .compress, .resize]
    }
    if ext == "pdf" { return [.pdfImages] }
    return documentExtensions.contains(ext) ? [.markdown, .text] : []
  }
  public static func pages(_ value: String, count: Int) -> [Int]? {
    guard count > 0 else { return nil }
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return count <= maximumPages ? Array(0..<count) : nil }
    guard value.count <= 120 else { return nil }
    var result = Set<Int>()
    for part in value.split(separator: ",", omittingEmptySubsequences: false) {
      let ends = part.trimmingCharacters(in: .whitespaces).split(
        separator: "-", omittingEmptySubsequences: false)
      guard (1...2).contains(ends.count), let a = Int(ends[0]), a > 0 else { return nil }
      let b = ends.count == 1 ? a : (Int(ends[1]) ?? 0)
      guard b >= a, b <= count, b - a < maximumPages else { return nil }
      for n in a...b {
        result.insert(n - 1)
        if result.count > maximumPages { return nil }
      }
    }
    return result.sorted()
  }
}
