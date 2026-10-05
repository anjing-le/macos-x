import AppKit

// Actual thumbnail service / cache / cancellation, asynchronous OS doubles only.
// Does not capture a screen, touch TCC, launch windows or focus applications.
let SCStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
enum SCStreamError { enum Code: Int { case userDeclined = -3801 } }
final class SCRunningApplication { let processID: pid_t = 314 }
final class SCWindow {
    let windowID: CGWindowID
    let owningApplication: SCRunningApplication? = SCRunningApplication()
    var frame = CGRect(x: 100, y: 200, width: 640, height: 400)
    init(_ id: UInt32) { windowID = id }
}
final class SCShareableContent {
    let windows = (1...80).map { SCWindow(UInt32($0)) }
    static func getExcludingDesktopWindows(_ exclude: Bool, onScreenWindowsOnly: Bool,
        completionHandler: @escaping (SCShareableContent?, Error?) -> Void) {
        MockThumbnail.metadata(onScreen: onScreenWindowsOnly, completionHandler)
    }
}
final class SCContentFilter {
    let window: SCWindow
    init(desktopIndependentWindow: SCWindow) { window = desktopIndependentWindow }
}
final class SCStreamConfiguration {
    var width = 0, height = 0
    var showsCursor = false, capturesAudio = false, ignoreShadowsSingleWindow = false
}
enum SCScreenshotManager {
    static func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration,
        completionHandler: @escaping (CGImage?, Error?) -> Void) {
        MockThumbnail.image(contentFilter.window.windowID, configuration, completionHandler)
    }
}
private enum MockThumbnail {
    private static let lock = NSLock()
    private static var contents: [(SCShareableContent?, Error?) -> Void] = []
    private static var images: [(CGImage?, Error?) -> Void] = []
    private static var captures: [UInt32] = []
    private static var boundsValid = true, allDesktops = true
    static var pendingContent: Int { lock.lock(); defer { lock.unlock() }; return contents.count }
    static var pendingImage: Int { lock.lock(); defer { lock.unlock() }; return images.count }
    static var capturedIDs: [UInt32] { lock.lock(); defer { lock.unlock() }; return captures }
    static var validBounds: Bool { lock.lock(); defer { lock.unlock() }; return boundsValid }
    static var includesOtherDesktops: Bool { lock.lock(); defer { lock.unlock() }; return allDesktops }
    static func metadata(onScreen: Bool, _ callback: @escaping (SCShareableContent?, Error?) -> Void) {
        lock.lock(); allDesktops = allDesktops && !onScreen; contents.append(callback); lock.unlock()
    }
    static func image(_ id: UInt32, _ config: SCStreamConfiguration, _ callback: @escaping (CGImage?, Error?) -> Void) {
        lock.lock()
        boundsValid = boundsValid && config.width <= 480 && config.height <= 300 && config.width > 0 && config.height > 0
            && !config.capturesAudio && !config.showsCursor && config.ignoreShadowsSingleWindow
        captures.append(id); images.append(callback); lock.unlock()
    }
    static func content(error: Error? = nil) {
        lock.lock(); let callback = contents.removeFirst(); lock.unlock()
        callback(error == nil ? SCShareableContent() : nil, error)
    }
    static func pixels(_ image: CGImage? = nil, error: Error? = nil) {
        lock.lock(); let callback = images.removeFirst(); lock.unlock(); callback(image, error)
    }
}
private struct Failure: Error { let message: String }
@main @MainActor private struct SwitcherRegression {
    static var checks = 0
    static func require(_ value: Bool, _ message: String) throws {
        checks += 1; if !value { throw Failure(message: message) }
    }
    static func wait(_ condition: () -> Bool, _ message: String) async throws {
        let end = Date().addingTimeInterval(4)
        while !condition() {
            if Date() > end { throw Failure(message: "timeout: " + message) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func settle() async throws { try await Task.sleep(nanoseconds: 40_000_000) }
    static func id(_ value: UInt32, pid: pid_t = 314) -> WindowThumbnailID { .init(window: value, process: pid) }
    static func image(width: Int = 4) -> CGImage {
        let c = CGContext(data: nil, width: width, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: 4))
        return c.makeImage()!
    }
    static func complete(_ count: Int, _ pixels: CGImage) async throws {
        try await wait({ MockThumbnail.pendingContent == 1 }, "metadata")
        MockThumbnail.content()
        for _ in 0..<count {
            try await wait({ MockThumbnail.pendingImage == 1 }, "one issued thumbnail")
            MockThumbnail.pixels(pixels)
        }
    }
    static func main() async {
        do {
            let service = WindowThumbnailService(), pixels = image()
            var received: [UInt32] = [], failures = 0
            let updated: (WindowThumbnailID, CGImage) -> Void = { id, _ in received.append(id.window) }
            let failed: (Error) -> Void = { _ in failures += 1 }
            let a = service.request([id(1), id(2)], updated: updated, failed: failed)
            try await wait({ MockThumbnail.pendingContent == 1 }, "first metadata")
            a.cancel()
            let b = service.request([id(3)], updated: updated, failed: failed)
            try await settle()
            try require(MockThumbnail.pendingContent == 1, "pending page cannot overlap issued metadata")
            MockThumbnail.content()
            try await wait({ MockThumbnail.pendingContent == 1 }, "latest metadata")
            MockThumbnail.content()
            try await wait({ MockThumbnail.pendingImage == 1 }, "B pixels")
            b.cancel()
            let c = service.request([id(4)], updated: updated, failed: failed)
            _ = service.request([id(5)], updated: updated, failed: failed)
            try await settle()
            try require(!c.valid && MockThumbnail.pendingImage == 1 && MockThumbnail.pendingContent == 0,
                        "latest pending page replaces old page without overlapping active pixels")
            MockThumbnail.pixels(pixels)
            try await complete(1, pixels)
            try await wait({ received == [5] }, "latest page receives only its own image")
            try require(MockThumbnail.capturedIDs == [3, 5], "cancelled/superseded metadata cannot issue old captures")
            _ = service.request([id(5)], updated: updated, failed: failed)
            try await wait({ received == [5, 5] }, "fresh cache hit")
            try require(MockThumbnail.pendingContent == 0 && MockThumbnail.pendingImage == 0, "fresh cached image needs no OS capture")

            _ = service.request([id(6)], updated: updated, failed: failed)
            try await wait({ MockThumbnail.pendingContent == 1 }, "clear during metadata")
            service.clear(); try await settle(); MockThumbnail.content(); try await settle()
            try require(received == [5, 5] && MockThumbnail.pendingImage == 0, "clear cancels in-flight delivery and cannot repopulate cache")
            _ = service.request([id(999)], updated: updated, failed: failed)
            try await wait({ MockThumbnail.pendingContent == 1 }, "missing window")
            MockThumbnail.content(); try await settle()
            try require(received == [5, 5] && failures == 0 && MockThumbnail.pendingImage == 0, "missing windows retain icons without errors or guessed captures")
            _ = service.request([id(5, pid: 777)], updated: updated, failed: failed)
            try await wait({ MockThumbnail.pendingContent == 1 }, "wrong owner")
            MockThumbnail.content(); try await settle()
            try require(MockThumbnail.pendingImage == 0, "window ID with different owner cannot reuse pixels")

            let refusal = NSError(domain: SCStreamErrorDomain, code: -3801)
            _ = service.request([id(7)], updated: updated, failed: failed)
            try await wait({ MockThumbnail.pendingContent == 1 }, "permission failure")
            MockThumbnail.content(error: refusal)
            try await wait({ failures == 1 }, "actual refusal is delivered")
            _ = service.request([id(7), id(8)], updated: updated, failed: failed)
            try await wait({ MockThumbnail.pendingContent == 1 }, "protected window")
            MockThumbnail.content()
            try await wait({ MockThumbnail.pendingImage == 1 }, "protected pixels")
            MockThumbnail.pixels(error: NSError(domain: "fixture.protected", code: 1))
            try await wait({ MockThumbnail.pendingImage == 1 }, "next eligible pixels")
            MockThumbnail.pixels(pixels)
            try await wait({ received.last == 8 }, "protected window does not block next card")
            try require(failures == 1, "nonpermission failure must not falsely demand permission")
            let beforeOversized = received.count
            _ = service.request([id(9)], updated: updated, failed: failed)
            try await complete(1, image(width: 481)); try await settle()
            try require(received.count == beforeOversized, "unexpected oversized image cannot enter UI or cache")

            // Exercise the real LRU bound using distinct window identities.
            for first: UInt32 in [10, 18, 26] {
                let before = received.count
                _ = service.request((first..<first+8).map { id($0) }, updated: updated, failed: failed)
                try await complete(8, pixels)
                try await wait({ received.count == before + 8 }, "cache-fill page")
            }
            let beforeEviction = received.count
            _ = service.request([id(10)], updated: updated, failed: failed)
            try await complete(1, pixels)
            try await wait({ received.count == beforeEviction + 1 }, "oldest entry was evicted")
            try require(MockThumbnail.capturedIDs.filter { $0 == 10 }.count == 2, "cache cannot keep all 24 distinct images")
            service.retain([id(10)])
            _ = service.request([id(33)], updated: updated, failed: failed)
            try await complete(1, pixels)
            try await settle()
            try require(MockThumbnail.capturedIDs.filter { $0 == 33 }.count == 2, "removed window identity loses its cached thumbnail")
            service.clear(); try await settle()
            let beforePage = received.count
            _ = service.request((40...60).map { id(UInt32($0)) }, updated: updated, failed: failed)
            try await complete(8, pixels)
            try await wait({ received.count == beforePage + 8 }, "bounded page")
            try require(MockThumbnail.capturedIDs.suffix(8) == Array(UInt32(40)...47), "requests are capped to the visible eight windows")
            try require(MockThumbnail.validBounds, "small pixel bounds, no cursor/audio and shadow-free windows")
            try require(MockThumbnail.includesOtherDesktops, "metadata includes off-screen windows")
            print("PASS switcher: \(checks) assertions; latest-page cancellation, one SCK request, cache/pruning bounds, PID identity, protected-window fallback; mocked OS only")
        } catch { print("FAIL switcher: \(error)"); exit(1) }
    }
}
