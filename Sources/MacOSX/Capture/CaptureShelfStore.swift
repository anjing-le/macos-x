import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Only explicitly shelved images are stored. All file work belongs to the
/// shelf's serial queue; the UI retains thumbnails, never the full collection.
final class CaptureShelfStore: @unchecked Sendable {
    struct Item: Codable, Equatable {
        let id: UUID
        let width: Int
        let height: Int
        let bytes: Int
        var positions: [String:Double]? = nil
    }
    static let limit = 40
    static let byteLimit = 128_000_000
    let directory: URL
    private(set) var items: [Item] = []
    private var removed: (Item, Int)?
    init(directory: URL) { self.directory = directory }
    private var manifest: URL { directory.appendingPathComponent("items.json") }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".png") }
    private func write(_ next: [Item]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        items = next
    }
    func load() throws -> [Item] {
        removed = nil
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let size = try manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 131_072 else { throw Failure.message("收纳目录索引过大，未加载。") }
        let decoded = try JSONDecoder().decode([Item].self, from: Data(contentsOf: manifest))
        guard decoded.count <= Self.limit, Set(decoded.map(\.id)).count == decoded.count,
              decoded.allSatisfy({ $0.bytes > 0 && $0.bytes <= 32_000_000 && $0.width > 0 && $0.height > 0 && $0.width <= 32_768 && $0.height <= 32_768 && Int64($0.width) * Int64($0.height) <= 16_000_000 }),
              decoded.reduce(0, { $0 + $1.bytes }) <= Self.byteLimit,
              decoded.allSatisfy({ item in
                  guard let positions=item.positions else { return true }
                  return positions.count <= 16 && positions.allSatisfy { !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.isFinite && (0...1).contains($0.value) }
              }) else { throw Failure.message("收纳索引无效，未加载。") }
        let valid = decoded.filter { item in
            (try? file(item.id).resourceValues(forKeys: [.fileSizeKey]).fileSize) == item.bytes
        }
        items = valid
        // Files left by an interrupted write are private to this directory.
        let retained = Set(valid.map { $0.id.uuidString + ".png" })
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if url.pathExtension == "png", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
               !retained.contains(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
        return valid
    }
    func add(_ image: CGImage) throws -> Item {
        guard items.count < Self.limit else { throw Failure.message("晾衣杆已满（40 张），请先整理。") }
        guard image.width <= 32_768, image.height <= 32_768, Int64(image.width) * Int64(image.height) <= 16_000_000 else { throw Failure.message("图片超过 1600 万像素，请缩小范围后收纳。") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw Failure.message("图片编码失败。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= 32_000_000,
              items.reduce(removed?.0.bytes ?? 0, { $0 + $1.bytes }) + data.length <= Self.byteLimit else { throw Failure.message("收纳空间已满（128 MB），请先整理。") }
        let item = Item(id: UUID(), width: image.width, height: image.height, bytes: data.length)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data as Data).write(to: file(item.id), options: .atomic)
        do { try write([item] + items) }
        catch { try? FileManager.default.removeItem(at: file(item.id)); throw error }
        return item
    }
    func image(_ id: UUID, maximum: Int? = nil) -> CGImage? {
        guard let item = (items + (removed.map { [$0.0] } ?? [])).first(where: { $0.id == id }),
              (try? file(id).resourceValues(forKeys: [.fileSizeKey]).fileSize) == item.bytes,
              let source = CGImageSourceCreateWithURL(file(id) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == item.width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == item.height else { return nil }
        if let maximum {
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
    func move(_ id: UUID, to index: Int) throws {
        guard let old = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items; let item = next.remove(at: old)
        next.insert(item, at: max(0, min(index, next.count))); try write(next)
    }
    /// A drag commits its final order and display-relative positions together.
    /// Intermediate mouse events never write files or decode images.
    func arrange(on display: String, order: [UUID], positions: [UUID:Double]) throws {
        guard !display.isEmpty, display.utf8.count <= 128,
              order.count == items.count, Set(order).count == order.count, Set(order) == Set(items.map(\.id)),
              Set(positions.keys).isSubset(of:Set(order)), positions.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw Failure.message("收纳位置无效，原位置已保留。")
        }
        let indexed=Dictionary(uniqueKeysWithValues:items.map { ($0.id,$0) })
        let next=try order.map { id -> Item in
            var item=indexed[id]!
            if let position=positions[id] {
                var saved=item.positions ?? [:]; saved[display]=position
                guard saved.count <= 16 else { throw Failure.message("已保存的显示器位置过多，原位置已保留。") }
                item.positions=saved
            }
            return item
        }
        try write(next)
    }
    func remove(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items; let item = next.remove(at: index); try write(next)
        if let previous = removed { try? FileManager.default.removeItem(at: file(previous.0.id)) }
        removed = (item, index)
    }
    func undo() throws {
        guard let (item, index) = removed else { return }
        guard items.count < Self.limit else { throw Failure.message("晾衣杆已满，请先腾出位置再撤销。") }
        var next = items; next.insert(item, at: min(index, next.count)); try write(next); removed = nil
    }
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}
