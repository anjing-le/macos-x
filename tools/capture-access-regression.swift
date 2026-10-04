import AppKit
import AVFoundation
import UniformTypeIdentifiers

// Exercises the actual service, module and recorder state machines. Only OS
// capture calls and presenting UI are replaced; no real capture, TCC request,
// window presentation or clipboard access occurs. These mocks are not SCK E2E.
let SCStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
enum SCStreamError { enum Code: Int { case userDeclined = -3801 } }
final class SCDisplay { let displayID: UInt32; init(_ id: UInt32) { displayID = id } }
final class SCShareableContent {
    let displays = [SCDisplay(7)]
    static func getExcludingDesktopWindows(_ exclude: Bool, onScreenWindowsOnly: Bool,
        completionHandler: @escaping (SCShareableContent?, Error?) -> Void) { MockCapture.holdContent(completionHandler) }
}
final class SCContentFilter { init(display: SCDisplay, excludingWindows: [Any]) {} }
final class SCStreamConfiguration {
    var width = 0, height = 0, queueDepth = 0
    var showsCursor = false, capturesAudio = false
    var minimumFrameInterval = CMTime.zero
    var pixelFormat: OSType = 0
}
enum SCScreenshotManager {
    static func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration,
        completionHandler: @escaping (CGImage?, Error?) -> Void) { MockCapture.holdImage(completionHandler) }
}
enum SCStreamOutputType { case screen }
enum SCStreamFrameInfo: Hashable { case status }
enum SCFrameStatus: Int { case complete = 0 }
protocol SCStreamOutput: AnyObject {}
protocol SCStreamDelegate: AnyObject {}
final class SCStream {
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate) {}
    func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue) throws {}
    func startCapture(completionHandler: @escaping (Error?) -> Void) { MockCapture.holdStart(completionHandler) }
    func stopCapture(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }
}

private enum MockCapture {
    private static let lock = NSLock()
    private static var contents: [(SCShareableContent?, Error?) -> Void] = []
    private static var images: [(CGImage?, Error?) -> Void] = []
    private static var starts: [(Error?) -> Void] = []
    private static var preflights = 0
    static var pendingContent: Int { lock.lock(); defer { lock.unlock() }; return contents.count }
    static var pendingImage: Int { lock.lock(); defer { lock.unlock() }; return images.count }
    static var pendingStart: Int { lock.lock(); defer { lock.unlock() }; return starts.count }
    static var preflightCalls: Int { lock.lock(); defer { lock.unlock() }; return preflights }
    static func falsePreflight() -> Bool { lock.lock(); preflights += 1; lock.unlock(); return false }
    static func holdContent(_ callback: @escaping (SCShareableContent?, Error?) -> Void) { lock.lock(); contents.append(callback); lock.unlock() }
    static func holdImage(_ callback: @escaping (CGImage?, Error?) -> Void) { lock.lock(); images.append(callback); lock.unlock() }
    static func holdStart(_ callback: @escaping (Error?) -> Void) { lock.lock(); starts.append(callback); lock.unlock() }
    static func content(error: Error? = nil) {
        lock.lock(); let callback = contents.removeFirst(); lock.unlock()
        callback(error == nil ? SCShareableContent() : nil, error)
    }
    static func image(_ image: CGImage? = nil, error: Error? = nil) {
        lock.lock(); let callback = images.removeFirst(); lock.unlock(); callback(image, error)
    }
    static func started(error: Error? = nil) {
        lock.lock(); let callback = starts.removeFirst(); lock.unlock(); callback(error)
    }
}
// Shadow the advisory and desktop metadata APIs so a reintroduced guard cannot
// silently touch TCC, and successful fake capture cannot scan real windows.
func CGPreflightScreenCaptureAccess() -> Bool { MockCapture.falsePreflight() }
func CGWindowListCopyWindowInfo(_ options: CGWindowListOption, _ window: CGWindowID) -> CFArray? { nil }

final class NSScreen {
    static let screens = [NSScreen()]
    let frame = CGRect(x: -100, y: -50, width: 400, height: 300)
    let backingScaleFactor: CGFloat = 2
    let deviceDescription: [NSDeviceDescriptionKey: Any] = [NSDeviceDescriptionKey("NSScreenNumber"): UInt32(7)]
}
enum NSEvent { static let mouseLocation = CGPoint.zero }
final class NSSavePanel {
    static var pending: NSSavePanel?
    var allowedContentTypes: [UTType] = [], nameFieldStringValue = "", message = ""
    var url = FileManager.default.temporaryDirectory.appendingPathComponent("capture-access-test-\(UUID().uuidString).mp4") as URL?
    private var completion: ((NSApplication.ModalResponse) -> Void)?
    func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) { completion = completionHandler; Self.pending = self }
    func cancel(_ sender: Any?) { resolve(.cancel) }
    func resolve(_ response: NSApplication.ModalResponse) {
        let callback = completion; completion = nil
        if Self.pending === self { Self.pending = nil }; callback?(response)
    }
}
enum CaptureTool { case rectangle }
@MainActor final class CaptureSelection {
    enum Result { case copy(CGRect), pin(CGRect), edit(CGRect), color(String), cancel }
    private(set) var selectedTool = CaptureTool.rectangle
    static var presentations = 0
    func present(_ frames: [CaptureFrame], previousRegion: CGRect?, windows: [CGRect], completion: @escaping (Result) -> Void) { Self.presentations += 1 }
    func dismiss() {}
    func pinCurrentSelection() {}
}
@MainActor final class CapturePins {
    var onStatus: ((String) -> Void)?
    var canAdd = true
    func add(_ image: CGImage, at frame: CGRect? = nil) {}
    func restoreLastClosed() -> Bool { false }
    func toggleAll() {}
    func closeAll() {}
}
@MainActor final class CaptureEditor {
    var onExport: (() -> Void)?, onClose: (() -> Void)?, onPin: ((CGImage) -> Void)?
    init(image: CGImage, selectionFrame: CGRect, initialTool: CaptureTool) {}
    func present() {}
    func close() { let callback = onClose; onClose = nil; callback?() }
    func pinCurrentImage() {}
    nonisolated static func pngData(_ image: CGImage) -> Data? { nil }
}
enum CaptureClipboard {
    static func image(from data: Data) -> CGImage? { nil }
    static func text(_ value: String) -> CGImage? { nil }
}
enum NSPasteboard {
    enum Kind { case png, tiff, string }
    final class Board {
        func data(forType: Kind) -> Data? { fatalError("Test must not read clipboard") }
        func string(forType: Kind) -> String? { fatalError("Test must not read clipboard") }
        func clearContents() { fatalError("Test must not write clipboard") }
        @discardableResult func setString(_ value: String, forType: Kind) -> Bool { fatalError("Test must not write clipboard") }
        @discardableResult func setData(_ value: Data, forType: Kind) -> Bool { fatalError("Test must not write clipboard") }
    }
    static let general = Board()
}

private struct CheckFailure: Error { let message: String }
@main @MainActor private struct AccessRegression {
    static var checks = 0
    static let screen = CaptureScreen(id: 7, frame: CGRect(x: -2, y: -2, width: 2, height: 2), scale: 2)
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1; guard value() else { throw CheckFailure(message: message) }
    }
    static func wait(_ predicate: @escaping () -> Bool, _ message: String) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw CheckFailure(message: "Timed out: " + message) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func settle() async throws { try await Task.sleep(nanoseconds: 30_000_000) }
    static func fixture() -> CGImage {
        let context = CaptureRaster.context(width: 4, height: 4)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4)); return context.makeImage()!
    }
    static func succeedImage(_ image: CGImage) async throws {
        try await wait({ MockCapture.pendingContent == 1 }, "content request")
        MockCapture.content()
        try await wait({ MockCapture.pendingImage == 1 }, "screenshot request")
        MockCapture.image(image)
    }
    static func main() async {
        do {
            let image = fixture()
            let refusal = NSError(domain: SCStreamErrorDomain, code: -3801)
            let unrelated = NSError(domain: SCStreamErrorDomain, code: -3811)
            let wrongDomain = NSError(domain: "fixture.other", code: -3801)
            let service = CaptureImageService()
            var result: Result<[CaptureFrame], Error>?
            service.capture([screen]) { result = $0 }
            try await succeedImage(image)
            try await wait({ result != nil }, "successful image completion")
            if case .success(let frames) = result { try require(frames.count == 1 && frames[0].image.width == 4, "actual image result must pass despite false advisory") }
            else { throw CheckFailure(message: "false advisory blocked actual successful image") }
            try require(MockCapture.preflightCalls == 0, "capture must not use advisory as a hard gate")

            result = nil; service.capture([screen]) { result = $0 }
            try await wait({ MockCapture.pendingContent == 1 }, "refusal metadata")
            MockCapture.content(error: refusal)
            try await wait({ result != nil }, "refusal completion")
            if case .failure(let error) = result { try require(isPermission(error), "documented refusal must map to permission") }
            else { throw CheckFailure(message: "expected refusal") }
            result = nil; service.capture([screen]) { result = $0 }
            try await wait({ MockCapture.pendingContent == 1 }, "image failure metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 }, "image failure")
            MockCapture.image(error: unrelated)
            try await wait({ result != nil }, "unrelated completion")
            if case .failure(let error) = result { try require((error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == -3811, "nonauthorization image error retains domain/code") }
            else { throw CheckFailure(message: "expected unrelated image failure") }
            result = nil; service.capture([screen]) { result = $0 }
            try await wait({ MockCapture.pendingContent == 1 }, "image refusal metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 }, "image refusal")
            MockCapture.image(error: refusal)
            try await wait({ result != nil }, "image refusal completion")
            if case .failure(let error) = result { try require(isPermission(error), "actual screenshot refusal must map to permission") }
            else { throw CheckFailure(message: "expected actual image refusal") }

            var cancelledCalls = 0
            let cancelled = service.capture([screen]) { _ in cancelledCalls += 1 }
            try await wait({ MockCapture.pendingContent == 1 }, "cancelled metadata")
            cancelled.cancel(); MockCapture.content()
            try await settle()
            try require(cancelledCalls == 0 && MockCapture.pendingImage == 0, "cancelled metadata cannot invoke screenshot or completion")
            var oldCalls = 0, latestCalls = 0
            service.capture([screen]) { _ in oldCalls += 1 }
            try await wait({ MockCapture.pendingContent == 1 }, "old metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 }, "old screenshot")
            service.capture([screen]) { _ in latestCalls += 1 }
            MockCapture.image(image)
            try await succeedImage(image)
            try await wait({ latestCalls == 1 }, "latest screenshot")
            try require(oldCalls == 0, "late superseded image must never complete")

            let module = CaptureModule(); var permissionEvents = 0
            module.onPermissionNeeded = { permissionEvents += 1 }; module.start()
            try require(!module.hasConfirmedScreenCaptureAccess, "start alone is not capture proof")
            module.capture(); try await succeedImage(image)
            try await wait({ module.hasConfirmedScreenCaptureAccess }, "module capture proof")
            try require(permissionEvents == 0 && CaptureSelection.presentations == 1, "success reaches selection without false permission prompt")
            for error in [wrongDomain, unrelated] {
                module.capture()
                try await wait({ MockCapture.pendingContent == 1 }, "nonpermission module metadata")
                MockCapture.content(error: error); try await settle()
                try require(module.hasConfirmedScreenCaptureAccess && permissionEvents == 0, "other errors do not revoke observed success or request permission")
            }
            module.capture()
            try await wait({ MockCapture.pendingContent == 1 }, "module actual refusal")
            MockCapture.content(error: refusal)
            try await wait({ permissionEvents == 1 }, "module permission callback")
            try require(!module.hasConfirmedScreenCaptureAccess, "actual refusal clears prior success")
            let presentations = CaptureSelection.presentations
            module.capture()
            try await wait({ MockCapture.pendingContent == 1 }, "late stopped metadata")
            module.stop(); MockCapture.content(); try await settle()
            try require(!module.hasConfirmedScreenCaptureAccess && CaptureSelection.presentations == presentations,
                        "stop/generation change suppresses late capture proof and UI")
            module.start(); module.capture()
            try await wait({ MockCapture.pendingContent == 1 }, "late stopped image metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 }, "late stopped image request")
            module.stop(); MockCapture.image(image); try await settle()
            try require(!module.hasConfirmedScreenCaptureAccess && CaptureSelection.presentations == presentations,
                        "stop after issuing screenshot suppresses late successful CGImage proof and UI")

            module.start(); module.toggleRecording()
            try require(NSSavePanel.pending != nil && !module.hasConfirmedScreenCaptureAccess, "save destination alone is not recording proof")
            NSSavePanel.pending!.resolve(.cancel)
            try require(!module.isRecording && !module.hasConfirmedScreenCaptureAccess, "cancelled save has no proof or capture request")
            module.toggleRecording(); NSSavePanel.pending!.resolve(.OK)
            try await wait({ MockCapture.pendingContent == 1 }, "record metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "record start")
            try require(!module.hasConfirmedScreenCaptureAccess, "metadata alone is not capture proof")
            MockCapture.started()
            try await wait({ module.hasConfirmedScreenCaptureAccess }, "record successful start proof")
            try require(MockCapture.preflightCalls == 0 && permissionEvents == 1, "record start must bypass false advisory without permission request")
            module.toggleRecording()
            try await wait({ !module.isRecording }, "record safe stop")
            try require(module.hasConfirmedScreenCaptureAccess, "normal stop/nonpermission no-frame error does not forge or revoke proof")
            module.toggleRecording(); NSSavePanel.pending!.resolve(.OK)
            try await wait({ MockCapture.pendingContent == 1 }, "record start refusal metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "record actual stream start refusal")
            MockCapture.started(error: refusal)
            try await wait({ !module.isRecording && permissionEvents == 2 }, "record start refusal callback")
            try require(!module.hasConfirmedScreenCaptureAccess, "stream start refusal clears prior successful capture proof")
            module.toggleRecording(); NSSavePanel.pending!.resolve(.OK)
            try await wait({ MockCapture.pendingContent == 1 }, "record actual refusal")
            MockCapture.content(error: refusal)
            try await wait({ !module.isRecording && permissionEvents == 3 }, "record refusal callback")
            try require(!module.hasConfirmedScreenCaptureAccess, "record refusal clears capture proof")

            module.toggleRecording(); NSSavePanel.pending!.resolve(.OK)
            try await wait({ MockCapture.pendingContent == 1 }, "record cancelled start metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "record cancelled start")
            module.stop(); MockCapture.started()
            try await wait({ !module.isRecording }, "record cancelled start flush")
            try require(!module.hasConfirmedScreenCaptureAccess && permissionEvents == 3, "late stopped stream start cannot confirm access or request permission")
            var flushed = 0
            module.prepareToTerminate { flushed += 1 }
            try await wait({ flushed == 1 }, "termination flush")
            try await settle(); try require(flushed == 1, "termination completion occurs exactly once")
            try require(MockCapture.preflightCalls == 0, "all active paths avoid advisory checks")
            try require(CGPreflightScreenCaptureAccess() == false, "mock advisory really returns false")
            print("PASS capture access: \(checks) assertions; false advisory + actual API success, exact refusal classification, other errors, cancellation, latest request, process proof, recording start/stop, and termination; no capture/TCC/UI/clipboard")
        } catch {
            FileHandle.standardError.write(Data("FAIL capture access: \(error)\n".utf8)); exit(1)
        }
    }
    static func isPermission(_ error: Error) -> Bool { if case CaptureFailure.permission = error { return true }; return false }
}
