import CoreGraphics
import Foundation
import ImageIO
import MacOSXCore
import PDFKit

enum Failure: Error { case invalid, limit, transparent, encrypted, pages, unsupported }
func writeImage(_ image: CGImage, to url: URL, png: Bool, quality: Double) throws {
  guard
    let destination = CGImageDestinationCreateWithURL(
      url as CFURL, (png ? "public.png" : "public.jpeg") as CFString, 1, nil)
  else { throw Failure.invalid }
  var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1]
  if !png { properties[kCGImageDestinationLossyCompressionQuality] = quality }
  CGImageDestinationAddImage(destination, image, properties as CFDictionary)
  guard CGImageDestinationFinalize(destination) else { throw Failure.invalid }
}
func image(
  _ input: URL, _ output: URL, _ mode: String, _ quality: Double, _ maxSide: Int,
  _ background: String
) throws {
  guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw Failure.invalid }
  guard CGImageSourceGetCount(source) == 1 else { throw Failure.unsupported }
  guard
    let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
    let w = props[kCGImagePropertyPixelWidth] as? Int,
    let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w <= 32768, h <= 32768,
    Int64(w) * Int64(h) <= FileActionPolicy.maximumPixels
  else { throw Failure.limit }
  let side = mode == "resize" ? min(maxSide, max(w, h)) : max(w, h)
  guard
    var image = CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary)
  else { throw Failure.invalid }
  let declared = props[kCGImagePropertyHasAlpha] as? Bool
  let alpha = declared ?? false
  let png =
    mode == "png"
    || ((mode == "compress" || mode == "resize")
      && (alpha || ["png", "tif", "tiff"].contains(input.pathExtension.lowercased())))
  if !png, [.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo) {
    let bytes = image.width * image.height * 4
    var data = [UInt8](repeating: 0, count: bytes)
    let transparent = data.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return true }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return stride(from: 3, to: bytes, by: 4).contains { buffer[$0] != 255 }
    }
    if transparent {
      guard ["white", "black"].contains(background) else { throw Failure.transparent }
      guard
        let c = CGContext(
          data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw Failure.invalid }
      c.setFillColor(
        (background == "black" ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1)))
      c.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard let flattened = c.makeImage() else { throw Failure.invalid }
      image = flattened
    }
  }
  let target = output.appendingPathComponent(png ? "result.png" : "result.jpg")
  try writeImage(image, to: target, png: png, quality: quality)
  if mode == "compress" {
    let new = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max
    let old = (try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
    if new >= old {
      try FileManager.default.removeItem(at: target)
      try FileManager.default.copyItem(
        at: input, to: output.appendingPathComponent("result." + input.pathExtension.lowercased()))
      try Data("unchanged".utf8).write(to: output.appendingPathComponent(".unchanged"))
    }
  }
}
func pdf(_ input: URL, _ output: URL, _ pages: String) throws {
  guard let doc = PDFDocument(url: input) else { throw Failure.invalid }
  guard !doc.isLocked else { throw Failure.encrypted }
  guard let selected = FileActionPolicy.pages(pages, count: doc.pageCount) else {
    throw Failure.pages
  }
  var totalPixels = 0
  for number in selected {
    guard let page = doc.page(at: number) else { throw Failure.invalid }
    let box = page.bounds(for: .mediaBox)
    guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
      throw Failure.invalid
    }
    let scale = min(2, 2400 / max(box.width, box.height))
    let w = max(1, Int(ceil(box.width * scale)))
    let h = max(1, Int(ceil(box.height * scale)))
    totalPixels += w * h
    guard totalPixels <= 48_000_000 else { throw Failure.limit }
    // PDFKit thumbnail honours page rotation and does not require a visible window.
    let ns = page.thumbnail(of: CGSize(width: w, height: h), for: .mediaBox)
    var rect = CGRect(x: 0, y: 0, width: ns.size.width, height: ns.size.height)
    guard let image = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
      throw Failure.invalid
    }
    try writeImage(
      image, to: output.appendingPathComponent(String(format: "page-%03d.png", number + 1)),
      png: true, quality: 1)
    let size =
      (try FileManager.default.contentsOfDirectory(
        at: output, includingPropertiesForKeys: [.fileSizeKey])).reduce(0) {
        $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    guard size <= FileActionPolicy.maximumOutput else { throw Failure.limit }
  }
}
let a = CommandLine.arguments
if a.count != 8 { exit(2) }
do {
  let input = URL(fileURLWithPath: a[1])
  let output = URL(fileURLWithPath: a[2])
  let operation = a[3]
  let values = try input.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
  guard values.isRegularFile == true,
    Int64(values.fileSize ?? Int.max) <= FileActionPolicy.maximumInput,
    let quality = Double(a[4]), quality.isFinite, (0.1...1).contains(quality), let side = Int(a[5]),
    (320...4096).contains(side)
  else { throw Failure.limit }
  guard ["jpeg", "png", "compress", "resize", "pdfImages"].contains(operation) else {
    throw Failure.unsupported
  }
  try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  if operation == "pdfImages" {
    try pdf(input, output, a[6])
  } else {
    try image(input, output, operation, quality, side, a[7])
  }
} catch {
  let token: String
  switch error {
  case Failure.limit: token = "limit"
  case Failure.transparent: token = "transparent"
  case Failure.encrypted: token = "encrypted"
  case Failure.pages: token = "pages"
  case Failure.unsupported: token = "unsupported"
  default: token = "invalid"
  }
  fputs(token + "\n", stderr)
  exit(1)
}
