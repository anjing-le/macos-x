import Foundation
import CryptoKit
import MacOSXCore

/// Each pipe owns a serial file queue. Only one chunk is in flight, with an
/// acknowledgement after disk write. No whole-file Data or main-thread IO.
final class NearbyFilePipe {
    let id: UUID
    let url: URL
    let size: Int64
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.nearby.file", qos: .utility)
    private let lock = NSLock()
    private var cancelled = false
    private var handle: FileHandle?
    private var hash = SHA256()
    private var offset: Int64 = 0
    private let receiving: Bool
    init(id: UUID, url: URL, size: Int64, receiving: Bool) {
        self.id = id; self.url = url; self.size = size; self.receiving = receiving
    }
    private var valid: Bool { lock.lock(); defer { lock.unlock() }; return !cancelled }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        queue.async { [self] in
            try? handle?.close(); handle = nil
            if receiving { try? FileManager.default.removeItem(at: url) }
        }
    }
    func read(_ completion: @escaping (Result<(Data, Int64, Data?), Error>) -> Void) {
        queue.async { [self] in
            let result = Result<(Data, Int64, Data?), Error> {
                guard valid else { throw CancellationError() }
                if handle == nil { handle = try FileHandle(forReadingFrom: url) }
                let start = offset
                let data = try handle!.read(upToCount: NearbyMessage.chunkBytes) ?? Data()
                guard data.count <= Int(size - offset) else { throw NearbyFailure.invalid }
                offset += Int64(data.count); hash.update(data: data)
                if data.isEmpty {
                    guard offset == size else { throw NearbyFailure.invalid }
                    try handle?.close(); handle = nil
                    return (data, start, Data(hash.finalize()))
                }
                return (data, start, nil)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func write(_ data: Data, at expected: Int64, completion: @escaping (Result<Int64, Error>) -> Void) {
        queue.async { [self] in
            let result = Result<Int64, Error> {
                guard valid, expected == offset, data.count <= NearbyMessage.chunkBytes,
                      Int64(data.count) <= size - offset else { throw NearbyFailure.invalid }
                if handle == nil {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: url.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                    handle = try FileHandle(forWritingTo: url)
                }
                try handle?.write(contentsOf: data); hash.update(data: data); offset += Int64(data.count)
                return offset
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func finish(digest: Data, name: String, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            let result = Result<URL, Error> {
                guard valid, offset == size, digest == Data(hash.finalize()),
                      NearbyMessage.safeName(name) == name else { throw NearbyFailure.invalid }
                // An empty file has no preceding write() call.
                if handle == nil, size == 0 {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                }
                try handle?.synchronize(); try handle?.close(); handle = nil
                let folder = url.deletingLastPathComponent()
                let original = URL(fileURLWithPath: name)
                var suffix = 1
                while suffix < 10_000 {
                    guard valid else { throw CancellationError() }
                    let candidate = folder.appendingPathComponent(suffix == 1 ? name :
                        original.deletingPathExtension().lastPathComponent + " (\(suffix))" +
                        (original.pathExtension.isEmpty ? "" : "." + original.pathExtension))
                    do { try FileManager.default.moveItem(at: url, to: candidate); return candidate }
                    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { suffix += 1 }
                }
                throw CocoaError(.fileWriteFileExists)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
