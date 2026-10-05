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
    var sourceRect = CGRect.zero
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
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate) { MockCapture.configuration(configuration) }
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
    private static var recordedConfiguration: SCStreamConfiguration?
    static var lastConfiguration: SCStreamConfiguration? { lock.lock(); defer { lock.unlock() }; return recordedConfiguration }
    static func configuration(_ value: SCStreamConfiguration) { lock.lock(); recordedConfiguration = value; lock.unlock() }
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
@MainActor final class CaptureSelection {
    enum Mode { case screenshot, recording }
    enum Result { case copy(CGRect), pin(CGRect), edit(CGRect), color(String), cancel }
    static var presentations = 0
    static var dismissals = 0
    static var lastCompletion: ((Result) -> Void)?
    func present(_ frames: [CaptureFrame], mode: Mode = .screenshot, previousRegion: CGRect? = nil, windows: [CGRect] = [], completion: @escaping (Result) -> Void) {
        Self.presentations += 1; Self.lastCompletion = completion
    }
    func dismiss() { Self.dismissals += 1; Self.lastCompletion = nil }
    func pinCurrentSelection() {}
    func color(at point: CGPoint, rgb: Bool) -> String? { nil }
    func resume() {}
}
@MainActor final class CapturePins {
    var onStatus: ((String) -> Void)?
    var canAdd = true
    static var pending: [(Bool) -> Void] = []
    static var frames: [CGRect?] = []
    func add(_ image: CGImage, at frame: CGRect? = nil, onPresent: ((Bool) -> Void)? = nil) {
        Self.frames.append(frame)
        if let onPresent { Self.pending.append(onPresent) }
    }
    func restoreLastClosed() -> Bool { false }
    func toggleAll() {}
    func closeAll() {}
}
@MainActor final class CaptureEditor {
    var onExport: (() -> Void)?, onCopied: (() -> Void)?, onClose: (() -> Void)?, onPin: ((CGImage) -> Void)?
    var onReselect: (() -> Void)?, colorAtPointer: ((Bool) -> String?)?
    static weak var current: CaptureEditor?
    let image: CGImage
    init(image: CGImage, selectionFrame: CGRect) { self.image = image }
    func present() { Self.current = self }
    func close() {
        if Self.current === self { Self.current = nil }
        let callback = onClose; onClose = nil; callback?()
    }
    func pinCurrentImage() { onPin?(image) }
    nonisolated static func pngData(_ image: CGImage) -> Data? { nil }
}
enum CaptureClipboard {
    static var fixtureImage: CGImage?
    static func image(from data: Data) -> CGImage? { fixtureImage }
    static func text(_ value: String) -> CGImage? { nil }
}
enum NSPasteboard {
    enum Kind { case png, tiff, string }
    final class Board {
        var changeCount = 0
        var fixturePNG: Data?
        func data(forType: Kind) -> Data? { fixturePNG }
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

            let recordingRegion = CGRect(x: -80, y: -20, width: 120, height: 80)
            let recordingGeometry = CaptureRecordingRegion(screen: CaptureScreen(id: 7, frame: NSScreen.screens[0].frame, scale: 2), region: recordingRegion)
            try require(recordingGeometry?.source == CGRect(x: 20, y: 190, width: 120, height: 80), "negative display origin and top-left recording crop")
            try require(recordingGeometry?.width == 240 && recordingGeometry?.height == 160, "Retina recording uses selected dimensions")
            let largeScreen = CaptureScreen(id: 7, frame: CGRect(x: 0, y: 0, width: 3000, height: 2000), scale: 2)
            let capped = CaptureRecordingRegion(screen: largeScreen, region: largeScreen.frame)
            try require(capped?.width == 1920 && capped?.height == 1280, "record encoding bounded at 1920 with aspect ratio")
            try require(CaptureRecordingRegion(screen: largeScreen, region: CGRect(x: -1, y: 0, width: 100, height: 100)) == nil, "reject cross-display recording rather than silently shift or crop")
            module.start(); module.toggleRecording()
            try await wait({ MockCapture.pendingContent == 1 }, "cancel record selection acquisition")
            module.toggleRecording(); MockCapture.content()
            try await settle()
            try require(!module.isRecording && MockCapture.pendingImage == 0, "repeated shortcut cancels pending selection without late overlay")
            module.toggleRecording()
            try require(NSSavePanel.pending == nil, "record shortcut must not present destination dialog")
            try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "record region selection")
            try require(MockCapture.pendingStart == 0 && module.isRecording, "region preview is not an active recording")
            CaptureSelection.lastCompletion?(.cancel)
            try require(!module.isRecording, "cancel region without starting a stream")
            func beginRecordingSelection() async throws {
                module.toggleRecording(); try await succeedImage(image)
                try await wait({ CaptureSelection.lastCompletion != nil }, "record selection ready")
                CaptureSelection.lastCompletion?(.edit(recordingRegion))
                try await wait({ MockCapture.pendingContent == 1 }, "record metadata")
            }
            try await beginRecordingSelection()
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "record start")
            try require(MockCapture.lastConfiguration?.sourceRect == recordingGeometry?.source,
                        "selected region reaches SCK source rectangle unchanged")
            try require(MockCapture.lastConfiguration?.width == 240 && MockCapture.lastConfiguration?.height == 160,
                        "encoder dimensions follow crop rather than full display")
            MockCapture.started()
            try await wait({ module.hasConfirmedScreenCaptureAccess }, "record successful start proof")
            try await settle()
            try require(MockCapture.preflightCalls == 0 && permissionEvents == 1, "record start must bypass false advisory without permission request")
            module.toggleRecording()
            try await wait({ !module.isRecording }, "record safe stop")
            try require(module.hasConfirmedScreenCaptureAccess, "normal stop/nonpermission no-frame error does not forge or revoke proof")
            try await beginRecordingSelection()
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "record actual stream start refusal")
            MockCapture.started(error: refusal)
            try await wait({ !module.isRecording && permissionEvents == 2 }, "record start refusal callback")
            try require(!module.hasConfirmedScreenCaptureAccess, "stream start refusal clears prior successful capture proof")
            try await beginRecordingSelection()
            MockCapture.content(error: refusal)
            try await wait({ !module.isRecording && permissionEvents == 3 }, "record refusal callback")
            try require(!module.hasConfirmedScreenCaptureAccess, "record refusal clears capture proof")

            try await beginRecordingSelection()
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "record cancelled start")
            module.stop(); MockCapture.started()
            try await wait({ !module.isRecording }, "record cancelled start flush")
            try require(module.hasConfirmedScreenCaptureAccess && permissionEvents == 3, "late stopped stream preserves actual preview proof without requesting permission")
            var flushed = 0
            module.prepareToTerminate { flushed += 1 }
            try await wait({ flushed == 1 }, "termination flush")
            try await settle(); try require(flushed == 1, "termination completion occurs exactly once")
            let pinModule = CaptureModule(); pinModule.start(); pinModule.capture()
            try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "pin selection")
            let region = CGRect(x: -100, y: -50, width: 400, height: 300)
            let beforePin = CaptureSelection.dismissals
            CaptureSelection.lastCompletion?(.pin(region))
            try await wait({ CapturePins.pending.count == 1 }, "pin presentation held")
            try require(CaptureSelection.dismissals == beforePin, "F3 must retain backdrop until pin is presented")
            CapturePins.pending.removeFirst()(true)
            try require(CaptureSelection.dismissals == beforePin + 1, "presented pin releases backdrop once")
            pinModule.capture(); try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "editor selection")
            let beforeEditor = CaptureSelection.dismissals
            CaptureSelection.lastCompletion?(.edit(region))
            pinModule.pin()
            try await wait({ CapturePins.pending.count == 1 }, "queued F3 reaches editor")
            try require(CaptureEditor.current != nil && CaptureSelection.dismissals == beforeEditor,
                        "editor and backdrop survive until pin presentation")
            CapturePins.pending.removeFirst()(true)
            try require(CaptureEditor.current == nil && CaptureSelection.dismissals == beforeEditor + 1,
                        "editor pin closes only after presentation")
            pinModule.capture(); try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "late pin selection")
            CaptureSelection.lastCompletion?(.pin(region))
            try await wait({ CapturePins.pending.count == 1 }, "late pin presentation held")
            pinModule.capture()
            let newSession = CaptureSelection.dismissals
            CapturePins.pending.removeFirst()(true)
            try require(CaptureSelection.dismissals == newSession, "late pin cannot dismiss a newer screenshot session")
            try await wait({ MockCapture.pendingContent == 1 }, "new session metadata")
            pinModule.stop(); MockCapture.content(error: unrelated); try await settle()
            let placementModule = CaptureModule(); placementModule.start(); placementModule.capture()
            try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "copied screenshot selection")
            CaptureSelection.lastCompletion?(.edit(region))
            try await wait({ CaptureEditor.current != nil }, "copied screenshot editor")
            NSPasteboard.general.fixturePNG = Data([1]); NSPasteboard.general.changeCount = 37
            CaptureClipboard.fixtureImage = image
            CaptureEditor.current?.onCopied?(); CaptureEditor.current?.close()
            let copiedPins = CapturePins.frames.count
            placementModule.pin()
            try await wait({ CapturePins.frames.count == copiedPins + 1 }, "owned clipboard pin")
            try require(CapturePins.frames.last! == region, "own copied screenshot keeps original point size and location")
            NSPasteboard.general.changeCount += 1
            placementModule.pin()
            try await wait({ CapturePins.frames.count == copiedPins + 2 }, "external clipboard pin")
            try require(CapturePins.frames.last! == nil, "changed clipboard must not reuse unrelated screenshot placement")
            placementModule.stop(); NSPasteboard.general.fixturePNG = nil; CaptureClipboard.fixtureImage = nil
            try require(MockCapture.preflightCalls == 0, "all active paths avoid advisory checks")
            try require(CGPreflightScreenCaptureAccess() == false, "mock advisory really returns false")
            print("PASS capture access: \(checks) assertions; false advisory + actual API success, exact refusal classification, other errors, cancellation, latest request, process proof, recording start/stop, and termination; no capture/TCC/UI/clipboard")
        } catch {
            FileHandle.standardError.write(Data("FAIL capture access: \(error)\n".utf8)); exit(1)
        }
    }
    static func isPermission(_ error: Error) -> Bool { if case CaptureFailure.permission = error { return true }; return false }
}
