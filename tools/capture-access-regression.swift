import AppKit
import AVFoundation
import UniformTypeIdentifiers
import ImageIO

// Exercises the actual service, module and recorder state machines. Only OS
// capture calls and presenting UI are replaced; no real capture, TCC request,
// window presentation or general clipboard access occurs. These mocks are not SCK E2E.
let SCStreamErrorDomain = "com.apple.ScreenCaptureKit.SCStreamErrorDomain"
enum SCStreamError { enum Code: Int { case userDeclined = -3801 } }
final class SCDisplay {
    let displayID: UInt32
    let frame: CGRect
    init(_ id: UInt32, frame: CGRect = CGRect(x: 0, y: 0, width: 4, height: 4)) { displayID = id; self.frame = frame }
}
final class SCWindow {
    let windowID: UInt32 = 42
    let frame: CGRect
    init(frame: CGRect = CGRect(x: 0, y: 0, width: 4, height: 4)) { self.frame = frame }
}
final class SCShareableContent {
    let windows: [SCWindow]
    let displays: [SCDisplay]
    init(windows: [SCWindow] = [SCWindow()], displays: [SCDisplay] = [SCDisplay(7), SCDisplay(8)]) { self.windows = windows; self.displays = displays }
    static func getExcludingDesktopWindows(_ exclude: Bool, onScreenWindowsOnly: Bool,
        completionHandler: @escaping (SCShareableContent?, Error?) -> Void) { MockCapture.holdContent(completionHandler,onScreenOnly: onScreenWindowsOnly) }
}
final class SCContentFilter {
    static var lastWindowID: UInt32?
    static var lastDisplayID: UInt32?
    static var includedWindowIDs = [UInt32]()
    init(display: SCDisplay, excludingWindows: [Any]) { Self.lastWindowID = nil; Self.lastDisplayID = display.displayID; Self.includedWindowIDs = [] }
    init(display: SCDisplay, including windows: [SCWindow]) {
        Self.lastWindowID = windows.first?.windowID; Self.lastDisplayID = display.displayID; Self.includedWindowIDs = windows.map(\.windowID)
    }
    init(desktopIndependentWindow window: SCWindow) { Self.lastWindowID = window.windowID; Self.lastDisplayID = nil; Self.includedWindowIDs = [] }
}
final class SCStreamConfiguration {
    var sourceRect = CGRect.zero
    var width = 0, height = 0, queueDepth = 0
    var showsCursor = false, capturesAudio = false
    var scalesToFit = false, preservesAspectRatio = false
    var sampleRate = 48_000, channelCount = 2
    var excludesCurrentProcessAudio = false
    var ignoreShadowsSingleWindow = false, ignoreGlobalClipSingleWindow = false, shouldBeOpaque = false
    var ignoreShadowsDisplay = false
    var backgroundColor: CGColor?
    var minimumFrameInterval = CMTime.zero
    var pixelFormat: OSType = 0
}
enum SCScreenshotManager {
    static func captureImage(contentFilter: SCContentFilter, configuration: SCStreamConfiguration,
        completionHandler: @escaping (CGImage?, Error?) -> Void) { MockCapture.configuration(configuration); MockCapture.holdImage(completionHandler) }
}
enum SCStreamOutputType: Hashable { case screen, audio }
enum SCStreamFrameInfo: Hashable { case status }
enum SCFrameStatus: Int { case complete = 0 }
protocol SCStreamOutput: AnyObject {}
protocol SCStreamDelegate: AnyObject {}
final class SCStream {
    var synchronizationClock: CMClock? { CMClockGetHostTimeClock() }
    private var outputs: [SCStreamOutputType: (CMSampleBuffer) -> Void] = [:]
    init(filter: SCContentFilter, configuration: SCStreamConfiguration, delegate: SCStreamDelegate) {
        MockCapture.configuration(configuration); MockCapture.lastStream = self
    }
    func addStreamOutput(_ output: SCStreamOutput, type: SCStreamOutputType, sampleHandlerQueue: DispatchQueue) throws {
        outputs[type] = { [weak output, weak self] sample in
            sampleHandlerQueue.async { [weak output, weak self] in
                guard let self, let recorder = output as? CaptureRecorder else { return }
                recorder.stream(self, didOutputSampleBuffer: sample, of: type)
            }
        }
    }
    func emit(_ sample: CMSampleBuffer, type: SCStreamOutputType) { outputs[type]?(sample) }
    func startCapture(completionHandler: @escaping (Error?) -> Void) { MockCapture.holdStart(completionHandler) }
    func stopCapture(completionHandler: @escaping (Error?) -> Void) {
        if MockCapture.delayStops { MockCapture.holdStop(completionHandler) } else { completionHandler(nil) }
    }
}

private enum MockCapture {
    static var lastStream: SCStream?
    private static let lock = NSLock()
    private static var contents: [(SCShareableContent?, Error?) -> Void] = []
    private static var images: [(CGImage?, Error?) -> Void] = []
    private(set) static var peakPendingImages = 0
    private static var starts: [(Error?) -> Void] = []
    private static var stops: [(Error?) -> Void] = []
    static var delayStops = false
    private static var preflights = 0
    private static var recordedConfiguration: SCStreamConfiguration?
    private static var recordedOnScreenOnly = true
    static var lastOnScreenOnly: Bool { lock.lock(); defer { lock.unlock() }; return recordedOnScreenOnly }
    static var lastConfiguration: SCStreamConfiguration? { lock.lock(); defer { lock.unlock() }; return recordedConfiguration }
    static func configuration(_ value: SCStreamConfiguration) { lock.lock(); recordedConfiguration = value; lock.unlock() }
    static var pendingContent: Int { lock.lock(); defer { lock.unlock() }; return contents.count }
    static var pendingImage: Int { lock.lock(); defer { lock.unlock() }; return images.count }
    static var pendingStart: Int { lock.lock(); defer { lock.unlock() }; return starts.count }
    static var pendingStop: Int { lock.lock(); defer { lock.unlock() }; return stops.count }
    static var preflightCalls: Int { lock.lock(); defer { lock.unlock() }; return preflights }
    static func falsePreflight() -> Bool { lock.lock(); preflights += 1; lock.unlock(); return false }
    static func holdContent(_ callback: @escaping (SCShareableContent?, Error?) -> Void,onScreenOnly: Bool) {
        lock.lock(); recordedOnScreenOnly = onScreenOnly; contents.append(callback); lock.unlock()
    }
    static func holdImage(_ callback: @escaping (CGImage?, Error?) -> Void) { lock.lock(); images.append(callback); peakPendingImages = max(peakPendingImages, images.count); lock.unlock() }
    static func holdStart(_ callback: @escaping (Error?) -> Void) { lock.lock(); starts.append(callback); lock.unlock() }
    static func holdStop(_ callback: @escaping (Error?) -> Void) { lock.lock(); stops.append(callback); lock.unlock() }
    static func stopped() { lock.lock(); let callback = stops.removeFirst(); lock.unlock(); callback(nil) }
    static func content(error: Error? = nil,windows: [SCWindow] = [SCWindow()],displays: [SCDisplay] = [SCDisplay(7), SCDisplay(8)]) {
        lock.lock(); let callback = contents.removeFirst(); lock.unlock()
        callback(error == nil ? SCShareableContent(windows: windows,displays: displays) : nil, error)
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
    static var main: NSScreen? { screens.first }
    var visibleFrame: CGRect { frame }
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
@MainActor final class RecordingPresentation {
    var recordingDirectory: URL { FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("macos-x", isDirectory: true) }
    var onStop: (() -> Void)?
    let settingsView = NSView()
    static var starts = 0, saves = 0, completedURLs = [URL]()
    func resume() {}
    func began() { Self.starts += 1 }
    func saving() { Self.saves += 1 }
    func completed(_ url: URL?, announce: Bool) { if let url { Self.completedURLs.append(url) } }
    func dismiss() {}
}
@MainActor final class CaptureSelection {
    enum Mode { case screenshot, recording }
    var onEditorKey: ((AppKit.NSEvent) -> Bool)?, onEditorCopy: (() -> Void)?, onEditorCancel: (() -> Void)?, onAdjustmentStarted: (() -> Void)?
    func clearEditorCallbacks() {}
    func setEditing(_ editing: Bool) {}
    func editorDidBecomeReady() -> Bool { false }
    var completedWindow: CaptureWindow? { Self.fixtureWindow }
    static var fixtureWindow: CaptureWindow?
    static var copySucceeded = 0, copyFailed = 0
    func completeRangeCopy(error: String? = nil) {
        if error == nil { Self.copySucceeded += 1 } else { Self.copyFailed += 1 }
    }
    enum Result { case copy(CGRect), pin(CGRect), shelf(CGRect), edit(CGRect), color(String), cancel }
    static weak var current: CaptureSelection?
    static var presentations = 0
    static var dismissals = 0
    static var lastCompletion: ((Result) -> Void)?
    func present(_ frames: [CaptureFrame], mode: Mode = .screenshot, previousRegion: CGRect? = nil, windows: [CGRect] = [], completion: @escaping (Result) -> Void) {
        Self.current = self; Self.presentations += 1; Self.lastCompletion = completion
    }
    func dismiss() { Self.dismissals += 1; Self.lastCompletion = nil }
    func pinCurrentSelection() {}
    static var shelfRequests = 0
    func shelveCurrentSelection() { Self.shelfRequests += 1 }
    func color(at point: CGPoint, rgb: Bool) -> String? { nil }
    func resume() {}
}
@MainActor final class CapturePins {
    var showsOutline = false
    func applyActiveEdit() -> Bool { false }
    func shelveActive(_ save: @escaping (CGImage, @escaping (Bool) -> Void) -> Void) -> Bool { false }
    var onStatus: ((String) -> Void)?
    var canAdd = true
    static var pending: [(Bool) -> Void] = []
    static var frames: [CGRect?] = []
    static var images: [CGImage] = []
    func add(_ image: CGImage, at frame: CGRect? = nil, onPresent: ((Bool) -> Void)? = nil) {
        Self.frames.append(frame)
        Self.images.append(image)
        if let onPresent { Self.pending.append(onPresent) }
    }
    func restoreLastClosed() -> Bool { false }
    func toggleAll() {}
    func closeAll() {}
}
@MainActor final class CaptureEditor {
    var onExport: (() -> Void)?, onCopied: (() -> Void)?, onClose: (() -> Void)?, onPin: ((CGImage) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?
    var selectionFrame: CGRect
    static var replacements = 0
    func replaceSelectionImage(_ image: CGImage, at region: CGRect) { selectionFrame = region; Self.replacements += 1 }
    func handleSelectionKey(_ event: AppKit.NSEvent) -> Bool { false }
    func copyCurrentImage() {}
    func beginRegionAdjustment() {}
    var onReselect: (() -> Void)?, colorAtPointer: ((Bool) -> String?)?
    static weak var current: CaptureEditor?
    let image: CGImage
    init(image: CGImage, selectionFrame: CGRect) { self.image = image; self.selectionFrame = selectionFrame }
    func present() { Self.current = self }
    func close() {
        if Self.current === self { Self.current = nil }
        let callback = onClose; onClose = nil; callback?()
    }
    func pinCurrentImage() { onPin?(image) }
    func renderForShelf(_ save: @escaping (CGImage, @escaping (Bool) -> Void) -> Void) { save(image) { [weak self] saved in if saved { self?.close() } } }
    nonisolated(unsafe) static var encodesFixturePNG = false
    nonisolated static func pngData(_ image: CGImage) -> Data? {
        guard encodesFixturePNG else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
enum CaptureClipboard {
    struct Decoded { let image:CGImage; let isText:Bool }
    static func decode(images:[Data],text:String?,rtf:Data?) -> Decoded? {
        guard let image = fixtureImage else { return nil }; return Decoded(image:image,isText:false)
    }
    static var fixtureImage: CGImage?
    static func image(from data: Data) -> CGImage? { fixtureImage }
    static func text(_ value: String) -> CGImage? { nil }
}
enum NSPasteboard {
    struct Kind:Equatable {
        let rawValue:String
        init(_ value:String) { rawValue = value }
        static let png=Kind("public.png"), tiff=Kind("public.tiff"), string=Kind("public.utf8-plain-text"), rtf=Kind("public.rtf")
    }
    typealias PasteboardType = Kind
    final class Board {
        var changeCount = 0
        var fixturePNG: Data?
        var acceptsFixtureWrites = false
        func data(forType: Kind) -> Data? { forType == .png ? fixturePNG : nil }
        func string(forType: Kind) -> String? { nil }
        func clearContents() {
            precondition(acceptsFixtureWrites,"Test must not write clipboard")
            fixturePNG = nil; changeCount += 1
        }
        @discardableResult func setString(_ value: String, forType: Kind) -> Bool { fatalError("Test must not write clipboard") }
        @discardableResult func setData(_ value: Data, forType: Kind) -> Bool {
            precondition(acceptsFixtureWrites && forType == .png,"Only the isolated PNG board accepts writes")
            fixturePNG = value; return true
        }
    }
    static let general = Board()
}

@MainActor final class MinimalToggle: NSButton {
    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero); self.title = title; self.target = target; self.action = action
    }
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
            let ownPID = ProcessInfo.processInfo.processIdentifier
            var metadata: [String: Any] = [kCGWindowLayer as String: NSNumber(value: 0),
                kCGWindowOwnerPID as String: NSNumber(value: ownPID), kCGWindowNumber as String: NSNumber(value: 42),
                kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 300, height: 200).dictionaryRepresentation]
            try require(CaptureImageService.windowTarget(metadata, primaryTop: 900, ownPID: ownPID, ownWindowIDs: [42])?.frame == CGRect(x: 10, y: 680, width: 300, height: 200), "own main window must snap with stable ID and AppKit coordinates")
            try require(CaptureImageService.windowTarget(metadata, primaryTop: 900, ownPID: ownPID, ownWindowIDs: []) == nil, "own panels remain excluded")
            metadata[kCGWindowOwnerPID as String] = NSNumber(value: ownPID + 1)
            try require(CaptureImageService.windowTarget(metadata, primaryTop: 900, ownPID: ownPID, ownWindowIDs: [])?.id == 42, "other app window remains eligible")
            metadata[kCGWindowLayer as String] = NSNumber(value: 3)
            try require(CaptureImageService.windowTarget(metadata, primaryTop: 900, ownPID: ownPID, ownWindowIDs: [42]) == nil, "floating layer must not snap")
            let image = fixture()
            // Permission failures and late grants are isolated from actual TCC.
            var authorization: ((Bool) -> Void)?
            var denied: Result<Void, Error>?
            var authorizationCalls = 0
            let audioRecorder = CaptureRecorder(authorizeMicrophone: { callback in
                authorizationCalls += 1; authorization = callback
            })
            let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("audio-permission-fixture-\(UUID().uuidString).mp4")
            audioRecorder.start(screen: screen, destination: audioURL, audioOptions: .init(microphone: true),
                                started: { denied = $0 }, finished: { _, _ in })
            try await wait({ authorization != nil }, "microphone asks only on explicit recording start")
            try require(authorizationCalls == 1 && MockCapture.pendingContent == 0, "microphone grant precedes capture and writer creation")
            authorization?(false)
            try await wait({ denied != nil }, "microphone denial has a visible start failure")
            if case .failure(let error) = denied {
                try require(error.localizedDescription.contains("麦克风") && !FileManager.default.fileExists(atPath: audioURL.path),
                            "denial is not silently downgraded or confused with screen permission")
            } else { throw CheckFailure(message: "microphone denial allowed recording") }
            authorization = nil; denied = nil
            audioRecorder.start(screen: screen, destination: audioURL, audioOptions: .init(system: true, microphone: true),
                                started: { denied = $0 }, finished: { _, _ in })
            try await wait({ authorization != nil }, "second microphone authorization pending")
            var microphoneStopped = false
            audioRecorder.stop { microphoneStopped = true }
            try await wait({ microphoneStopped && denied != nil }, "cancel pending microphone permission releases recording")
            authorization?(true); try await settle()
            try require(MockCapture.pendingContent == 0 && !FileManager.default.fileExists(atPath: audioURL.path),
                        "late microphone grant cannot resurrect a cancelled recording")
            var systemStarted: Result<Void, Error>?
            var systemFinished = false
            audioRecorder.start(screen: screen, destination: audioURL, audioOptions: .init(system: true),
                                started: { systemStarted = $0 }, finished: { _, _ in systemFinished = true })
            try await wait({ MockCapture.pendingContent == 1 }, "system-only recording begins without microphone grant")
            MockCapture.content()
            try await wait({ MockCapture.pendingStart == 1 }, "system audio stream configured")
            try require(MockCapture.lastConfiguration?.capturesAudio == true && authorizationCalls == 2,
                        "system audio selection reaches SCK and never requests microphone")
            MockCapture.started()
            try await wait({ systemStarted != nil }, "system-only start callback")
            audioRecorder.stop()
            try await wait({ systemFinished }, "system-only stop cancels the active audio timer and finalizes")
            for hasAudio in [false, true] {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording-track-fixture-\(UUID().uuidString).mp4")
                defer { try? FileManager.default.removeItem(at: url) }
                var recorder: CaptureRecorder? = CaptureRecorder(authorizeMicrophone: { _ in
                    fatalError("silent/system-only must never request a microphone")
                })
                weak var releasedRecorder = recorder
                var started = false, completed = false, saved: URL?, recordingError: Error?
                recorder?.start(screen: screen, destination: url, audioOptions: .init(system: hasAudio),
                    started: { result in if case .success = result { started = true } },
                    finished: { output, error in saved = output; recordingError = error; completed = true })
                try await wait({ MockCapture.pendingContent == 1 }, "native writer capture metadata")
                MockCapture.content()
                try await wait({ MockCapture.pendingStart == 1 }, "native writer stream prepared")
                let stream = MockCapture.lastStream!
                MockCapture.started(); try await wait({ started }, "native writer recording starts")
                let anchor = CMClockGetTime(CMClockGetHostTimeClock())
                var pixel: CVPixelBuffer?
                try require(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess,
                            "real video pixel buffer allocated")
                var description: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescriptionOut: &description)
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: anchor, decodeTimeStamp: .invalid)
                var video: CMSampleBuffer?
                CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel!, formatDescription: description!,
                    sampleTiming: &timing, sampleBufferOut: &video)
                let emittedAt = CACurrentMediaTime()
                stream.emit(video!, type: .screen)
                for i in 0..<12 {
                    if hasAudio {
                        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, frameCapacity: 960)!
                        pcm.frameLength = 960
                        for channel in 0..<2 { for frame in 0..<960 { pcm.floatChannelData![channel][frame] = 0.2 } }
                        let time = CMTimeAdd(anchor, CMTime(value: Int64(i * 960), timescale: 48_000))
                        stream.emit(try RecordingAudioWriter.sample(pcm, at: time), type: .audio)
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                MockCapture.delayStops = true
                recorder?.stop(); try await wait({ MockCapture.pendingStop == 1 }, "recording stop waits for native teardown")
                let stoppedAt = CACurrentMediaTime()
                try await Task.sleep(nanoseconds: 500_000_000)
                try require(!completed, "Recorder waits for teardown before sealing the file")
                MockCapture.delayStops = false; MockCapture.stopped()
                try await wait({ completed }, "real recorder finishes MP4")
                try require(saved == url && recordingError == nil, "native video/audio writer completes without losing selected sound")
                let asset = AVURLAsset(url: url)
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                let duration = try await asset.load(.duration)
                try require(audioTracks.count == (hasAudio ? 1 : 0) && videoTracks.count == 1,
                            "silent file has no audio track; system selection creates one playable track alongside video")
                try require(duration.seconds >= 0.2, "static final frame and audio share actual recording duration")
                try require(duration.seconds <= stoppedAt - emittedAt + 0.15, "Native teardown delay does not extend video or audio duration")
                recorder = nil; MockCapture.lastStream = nil
                try await wait({ releasedRecorder == nil }, "stopping audio releases recorder, timer, stream and buffers")
            }
            let refusal = NSError(domain: SCStreamErrorDomain, code: -3801)
            let unrelated = NSError(domain: SCStreamErrorDomain, code: -3811)
            let wrongDomain = NSError(domain: "fixture.other", code: -3801)
            let service = CaptureImageService(reuseDisplayMetadata: false)
            var result: Result<[CaptureFrame], Error>?
            service.capture([screen]) { result = $0 }
            try await succeedImage(image)
            try await wait({ result != nil }, "successful image completion")
            if case .success(let frames) = result { try require(frames.count == 1 && frames[0].image.width == 4, "actual image result must pass despite false advisory") }
            else { throw CheckFailure(message: "false advisory blocked actual successful image") }
            try require(MockCapture.preflightCalls == 0, "capture must not use advisory as a hard gate")

            let secondScreen = CaptureScreen(id: 8, frame: CGRect(x: -4, y: 0, width: 4, height: 4), scale: 1)
            let greenContext = CaptureRaster.context(width: 4, height: 4)!
            greenContext.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1)); greenContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let green = greenContext.makeImage()!
            let expectedRed = CapturePixelSampler(image: image)!.sample(x: 0, y: 0)
            let expectedGreen = CapturePixelSampler(image: green)!.sample(x: 0, y: 0)
            result = nil; service.capture([screen, secondScreen]) { result = $0 }
            try await succeedImage(image)
            try await wait({ MockCapture.pendingImage == 1 }, "second display begins after first native result")
            try require(result == nil && MockCapture.pendingContent == 0, "No partial multi-display delivery or extra metadata request")
            MockCapture.image(green)
            try await wait({ result != nil }, "multi-display samplers complete before delivery")
            if case .success(let frames) = result {
                try require(frames.map(\.screen.id) == [7,8], "Multi-display frame ordering remains stable")
                try require(expectedRed != expectedGreen && frames[0].sampler?.sample(x: 0, y: 0) == expectedRed && frames[1].sampler?.sample(x: 0, y: 0) == expectedGreen, "Each display keeps its own completed immutable sampler")
            } else { throw CheckFailure(message: "multi-display capture failed") }
            var cancelledPairCalls = 0, replacementCalls = 0
            service.capture([screen, secondScreen]) { _ in cancelledPairCalls += 1 }
            try await succeedImage(image)
            try await wait({ MockCapture.pendingImage == 1 }, "pending second display")
            service.capture([screen]) { _ in replacementCalls += 1 }
            try await settle()
            try require(MockCapture.pendingContent == 0, "Replacement waits for the already-issued display callback")
            MockCapture.image(green)
            try await succeedImage(image); try await wait({ replacementCalls == 1 }, "replacement after cancelled multi-display")
            try require(cancelledPairCalls == 0 && MockCapture.peakPendingImages == 1, "Multi-display cancellation keeps latest delivery and a single native screenshot in flight")

            let target = CaptureWindow(id: 42, frame: CGRect(x: 0, y: -4, width: 4, height: 4))
            result = nil; service.capture([screen], window: target) { result = $0 }
            try await wait({ MockCapture.pendingContent == 1 }, "isolated window metadata")
            try require(!MockCapture.lastOnScreenOnly,"An exact window lookup does not exclude a target behind selection panels")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 }, "isolated window request")
            try require(SCContentFilter.lastWindowID == 42, "window capture must isolate exact ID, not display crop")
            let configuration = MockCapture.lastConfiguration!
            try require(configuration.ignoreShadowsSingleWindow && configuration.ignoreGlobalClipSingleWindow && configuration.shouldBeOpaque,
                        "window capture removes shadows/clipping and requests opaque output")
            try require(configuration.width == 8 && configuration.height == 8, "window capture retains point-to-pixel scale")
            try require(configuration.scalesToFit && configuration.preservesAspectRatio,
                        "Smaller window surfaces fill the output without stretching during fullscreen/Retina transitions")
            try require(configuration.sourceRect == CGRect(x: 0,y: 0,width: 4,height: 4),
                        "Contained window capture uses its explicit display-local source extent")
            try require(SCContentFilter.lastDisplayID == 7 && SCContentFilter.includedWindowIDs == [42] && configuration.ignoreShadowsDisplay,
                        "Display filter includes only the selected window, excludes desktop/overlays and removes shadows")
            let cornerContext = CaptureRaster.context(width: 8, height: 8)!
            cornerContext.setFillColor(CGColor(colorSpace: cornerContext.colorSpace!, components: [1, 0, 0, 1])!)
            cornerContext.fill(CGRect(x: 2, y: 2, width: 4, height: 4))
            MockCapture.image(cornerContext.makeImage()!)
            try await wait({ result != nil }, "isolated window completion")
            if case .success(let windowFrames) = result {
                try require(windowFrames.count == 1 && windowFrames[0].screen.frame == target.frame, "isolated frame keeps original window location")
                let pixels = CapturePixelSampler(image: windowFrames[0].image)!
                try require(pixels.sample(x: 0, y: 0)!.hex == "#FFFFFF", "transparent window corner becomes white, no desktop pixels")
                try require(pixels.sample(x: 4, y: 4)!.hex == "#FF0000", "opaque window content remains unchanged: \(pixels.sample(x: 4, y: 4)!.hex)")
            } else { throw CheckFailure(message: "isolated window failed") }
            let frozenScreen = CaptureScreen(id: 7,frame: CGRect(x: 0,y: -4,width: 5,height: 4),scale: 2)
            let shiftedTarget = CaptureWindow(id: 42,frame: CGRect(x: 0.5,y: -4,width: 4,height: 4))
            let roundingContext = CaptureRaster.context(width: 10,height: 8)!
            roundingContext.setFillColor(CGColor(colorSpace: roundingContext.colorSpace!,components: [1,0,0,1])!)
            roundingContext.fill(CGRect(x: 0,y: 0,width: 10,height: 8))
            result = nil
            service.capture([frozenScreen],window: shiftedTarget,frozenFrames: [CaptureFrame(screen: frozenScreen,image: roundingContext.makeImage()!)]) { result = $0 }
            try await succeedImage(cornerContext.makeImage()!)
            try await wait({ result != nil },"frozen subpoint window geometry")
            if case .success(let frames) = result {
                try require(frames[0].screen.frame == shiftedTarget.frame,
                            "Accepted subpoint window metadata rounding cannot shift the original frozen selection")
            } else { throw CheckFailure(message: "frozen geometry failed") }
            // A second display can have both a positive x and negative Quartz y.
            let offsetScreen = CaptureScreen(id: 8,frame: CGRect(x: 10,y: 0,width: 8,height: 8),scale: 1)
            let offsetWindow = SCWindow(frame: CGRect(x: 11,y: -7,width: 4,height: 4))
            let offsetTarget = CaptureWindow(id: 42,frame: CGRect(x: 11,y: 3,width: 4,height: 4))
            for displayFrame in [CGRect(x: 10,y: -8,width: 8,height: 8), CGRect(x: 12,y: -8,width: 8,height: 8)] {
                result = nil; service.capture([screen,offsetScreen],window: offsetTarget) { result = $0 }
                try await wait({ MockCapture.pendingContent == 1 }, "offset window metadata")
                MockCapture.content(windows: [offsetWindow],displays: [SCDisplay(8,frame: displayFrame)])
                try await wait({ MockCapture.pendingImage == 1 }, "offset window image")
                let contained = displayFrame.contains(offsetWindow.frame)
                try require(MockCapture.lastConfiguration!.sourceRect == (contained ? CGRect(x: 1,y: 1,width: 4,height: 4) : .zero),
                            "Contained display uses local points; spanning window keeps independent source extent")
                try require(contained ? SCContentFilter.includedWindowIDs == [42] && SCContentFilter.lastDisplayID == 8 : SCContentFilter.lastDisplayID == nil && SCContentFilter.lastWindowID == 42,
                            "Spanning windows retain exact independent-window capture without display clipping")
                MockCapture.image(image)
                try await wait({ result != nil }, "offset window completion")
                if case .success(let frames) = result { try require(frames[0].screen.frame == offsetTarget.frame && frames[0].image.width == 4,"Offset window retains original placement and native scale") }
                else { throw CheckFailure(message: "offset window failed") }
            }
            for invalidTarget in [CaptureWindow(id: 99, frame: target.frame),
                                  CaptureWindow(id: 42, frame: target.frame.offsetBy(dx: 10, dy: 0))] {
                result = nil; service.capture([screen], window: invalidTarget) { result = $0 }
                try await wait({ MockCapture.pendingContent == 1 }, "stale window metadata")
                MockCapture.content()
                try await wait({ result != nil }, "stale window rejection")
                if case .failure = result { try require(MockCapture.pendingImage == 0, "closed/moved window must not fall back to display capture") }
                else { throw CheckFailure(message: "stale window unexpectedly captured") }
            }

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

            // Prioritisation changes acquisition order, never the coordinate
            // order delivered to selection/window capture. Metadata is the
            // only reusable data: each capture still requests fresh pixels.
            let fast = CaptureImageService()
            var fastResult: Result<[CaptureFrame], Error>?
            fast.capture([screen,secondScreen],prioritizing: 8) { fastResult = $0 }
            try await wait({ MockCapture.pendingContent == 1 },"cold display metadata")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 },"priority display native image")
            try require(SCContentFilter.lastDisplayID == 8,"Mouse display is frozen first even when it is not the primary display")
            MockCapture.image(green)
            try await wait({ MockCapture.pendingImage == 1 },"primary display follows priority display")
            try require(SCContentFilter.lastDisplayID == 7,"Secondary native capture remains single-flight")
            MockCapture.image(image)
            try await wait({ fastResult != nil },"priority capture delivered")
            if case .success(let frames) = fastResult {
                try require(frames.map(\.screen.id) == [7,8],"Output retains primary coordinate order")
                try require(frames[0].sampler?.sample(x: 0,y: 0) == expectedRed && frames[1].sampler?.sample(x: 0,y: 0) == expectedGreen,
                            "Post-freeze sampling never swaps screens")
            } else { throw CheckFailure(message: "priority capture failed") }
            fastResult = nil
            fast.capture([screen,secondScreen],prioritizing: 7) { fastResult = $0 }
            try await wait({ MockCapture.pendingImage == 1 },"warm capture issues pixels directly")
            try require(MockCapture.pendingContent == 0 && SCContentFilter.lastDisplayID == 7,"Warm F1 does not wait for a fresh shareable-content query")
            MockCapture.image(green)
            try await wait({ MockCapture.pendingImage == 1 },"warm second display")
            MockCapture.image(image)
            try await wait({ fastResult != nil },"fresh warm pixels delivered")
            if case .success(let frames) = fastResult {
                try require(frames[0].sampler?.sample(x: 0,y: 0) == expectedGreen,"Cached display metadata must never reuse old image pixels")
            } else { throw CheckFailure(message: "warm capture failed") }
            fastResult = nil
            fast.capture([screen]) { fastResult = $0 }
            try await wait({ MockCapture.pendingContent == 1 },"display removal invalidates metadata")
            MockCapture.content(); try await wait({ MockCapture.pendingImage == 1 },"new layout pixels")
            MockCapture.image(image); try await wait({ fastResult != nil },"new layout delivered")
            fastResult = nil
            fast.capture([screen]) { fastResult = $0 }
            try await wait({ MockCapture.pendingImage == 1 },"cached layout before native failure")
            MockCapture.image(error: unrelated); try await wait({ fastResult != nil },"native failure delivered")
            fastResult = nil
            fast.capture([screen]) { fastResult = $0 }
            try await wait({ MockCapture.pendingContent == 1 },"native error invalidates display metadata")
            MockCapture.content(); try await wait({ MockCapture.pendingImage == 1 },"refreshed display pixels")
            MockCapture.image(image); try await wait({ fastResult != nil },"refreshed layout delivered")
            fast.cancel(); fastResult = nil
            fast.capture([screen]) { fastResult = $0 }
            try await wait({ MockCapture.pendingContent == 1 },"stop releases cached display references")
            fast.cancel(); MockCapture.content(); try await settle()
            try require(fastResult == nil && MockCapture.pendingImage == 0 && MockCapture.peakPendingImages == 1,
                        "Cancellation drops cache and stale callbacks without extra native shots")
            let module = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); var permissionEvents = 0
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
            try require(RecordingPresentation.starts == 0, "clock must not start during region selection")
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
            try require(RecordingPresentation.starts == 0, "clock must not start before stream confirmation")
            MockCapture.started()
            try await wait({ RecordingPresentation.starts == 1 }, "record clock starts after stream confirmation")
            try await wait({ module.hasConfirmedScreenCaptureAccess }, "record successful start proof")
            try await settle()
            try require(MockCapture.preflightCalls == 0 && permissionEvents == 1, "record start must bypass false advisory without permission request")
            module.toggleRecording()
            try require(RecordingPresentation.saves == 1, "stop must freeze elapsed clock before encoding finishes")
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
            let pinModule = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); pinModule.start(); pinModule.capture()
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
            try await wait({ CaptureEditor.current != nil }, "first editable selection")
            let originalEditor = CaptureEditor.current
            let adjustedRegion = region.insetBy(dx: 20, dy: 20)
            let oldReplacements = CaptureEditor.replacements
            CaptureSelection.current?.onAdjustmentStarted?()
            CaptureSelection.lastCompletion?(.edit(adjustedRegion))
            try await wait({ CaptureEditor.replacements == oldReplacements + 1 }, "adjusted crop reaches existing editor")
            try require(CaptureEditor.current === originalEditor && CaptureEditor.current?.selectionFrame == adjustedRegion,
                        "adjusting the selection reuses editor and updates its region without recapturing desktop")
            try require(MockCapture.pendingContent == 0 && MockCapture.pendingImage == 0,
                        "freeform adjustment crops frozen pixels without a new screen capture")
            pinModule.pin()
            try await wait({ CapturePins.pending.count == 1 }, "queued F3 reaches editor")
            try require(CapturePins.frames.last! == adjustedRegion, "F3 uses latest adjusted region rather than initial selection")
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
            let placementModule = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); placementModule.start(); placementModule.capture()
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
            let clickModule = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); clickModule.start(); clickModule.capture()
            try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "selection before another-window click")
            CaptureSelection.lastCompletion?(.edit(region))
            try await wait({ CaptureEditor.current != nil }, "editable crop before another-window click")
            let beforeClickDismissals = CaptureSelection.dismissals
            var clickStatus = ""
            clickModule.onStatusChange = { clickStatus = $0 }
            CaptureSelection.lastCompletion?(.copy(region.insetBy(dx: 60,dy: 40)))
            try require(CaptureEditor.current == nil && CaptureSelection.dismissals == beforeClickDismissals,
                        "a direct copy of a new magnetized region closes the old editor without its stale close callback")
            // This fixture intentionally rejects PNG encoding before any board
            // write. The copy failure must still leave no old editable crop.
            try await wait({ clickStatus == "截图编码失败，未修改剪贴板。" }, "bounded copy failure without clipboard writes")
            try require(CaptureEditor.current == nil && MockCapture.pendingContent == 0 && MockCapture.pendingImage == 0,
                        "new-region copy cannot revive the old editor or start another desktop capture")
            clickModule.stop()
            // Real module/service/compositor/PNG encoding through a private
            // in-memory pasteboard double, plus a unique native pasteboard.
            // The user's general pasteboard and UI are never touched.
            let frozenContext = CaptureRaster.context(width: 400,height: 300)!
            frozenContext.setFillColor(CGColor(gray: 1,alpha: 1)); frozenContext.fill(CGRect(x: 0,y: 0,width: 400,height: 300))
            frozenContext.setFillColor(CGColor(red: 1,green: 0,blue: 0,alpha: 1)); frozenContext.fill(CGRect(x: 40,y: 80,width: 80,height: 100))
            frozenContext.setFillColor(CGColor(red: 0,green: 0,blue: 1,alpha: 1)); frozenContext.fill(CGRect(x: 120,y: 80,width: 80,height: 100))
            let frozen = frozenContext.makeImage()!, crop = CGRect(x: -60,y: 70,width: 160,height: 100)
            CaptureEditor.encodesFixturePNG = true; NSPasteboard.general.acceptsFixtureWrites = true
            // Free selection still copies the exact frozen desktop pixels.
            let direct = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); direct.start(); direct.capture()
            try await succeedImage(frozen)
            try await wait({ CaptureSelection.lastCompletion != nil },"free range selection ready")
            let succeeded = CaptureSelection.copySucceeded
            NSPasteboard.general.fixturePNG = nil
            CaptureSelection.lastCompletion?(.copy(crop))
            try await wait({ CaptureSelection.copySucceeded == succeeded + 1 },"free range copy acknowledgement")
            try require(MockCapture.pendingContent == 0 && MockCapture.pendingImage == 0,"Free selection does not recapture a window")
            let bytes = NSPasteboard.general.fixturePNG!
            let png = CGImageSourceCreateWithData(bytes as CFData,nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }!
            try require(png.width == 160 && png.height == 100,"Free PNG dimensions match the visible range")
            let nativeBoard = AppKit.NSPasteboard.withUniqueName()
            defer { nativeBoard.releaseGlobally() }
            try require(nativeBoard.setData(bytes,forType: .png) && NSImage(pasteboard: nativeBoard) != nil,
                        "A real private AppKit pasteboard receives the copied PNG as an image")
            let actual = CapturePixelSampler(image: png)!, expected = CapturePixelSampler(image: frozen.cropping(to: CGRect(x: 40,y: 80,width: 160,height: 100))!)!
            try require((0..<100).allSatisfy { y in (0..<160).allSatisfy { x in actual.sample(x: x,y: y) == expected.sample(x: x,y: y) } },
                        "Every free-selection PNG pixel matches the frozen crop")
            direct.stop()

            // The frozen window was red over a green desktop. After F1 its
            // live content turns blue; only its transparent shape may be used.
            let desktopContext = CaptureRaster.context(width: 800,height: 600)!
            desktopContext.setFillColor(CGColor(red: 0,green: 1,blue: 0,alpha: 1)); desktopContext.fill(CGRect(x: 0,y: 0,width: 800,height: 600))
            desktopContext.setFillColor(CGColor(colorSpace: desktopContext.colorSpace!,components: [1,0,0,1])!); desktopContext.fill(CGRect(x: 202,y: 594,width: 4,height: 4))
            let desktop = desktopContext.makeImage()!
            let laterContext = CaptureRaster.context(width: 8,height: 8)!
            laterContext.setFillColor(CGColor(colorSpace: laterContext.colorSpace!,components: [0,0,1,1])!); laterContext.fill(CGRect(x: 2,y: 2,width: 4,height: 4))
            let laterWindow = laterContext.makeImage()!
            let magnet = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); magnet.start(); magnet.capture()
            try await succeedImage(desktop)
            try await wait({ CaptureSelection.lastCompletion != nil },"magnet range ready")
            let windowRegion = CGRect(x: 0,y: 246,width: 4,height: 4)
            CaptureSelection.fixtureWindow = CaptureWindow(id: 42,frame: windowRegion)
            let previousPNG = Data([11,22,33])
            NSPasteboard.general.fixturePNG = previousPNG
            let failed = CaptureSelection.copyFailed, beforeCopy = CaptureSelection.copySucceeded
            CaptureSelection.lastCompletion?(.copy(windowRegion))
            try await wait({ MockCapture.pendingContent == 1 },"magnet lookup after copy")
            try require(!MockCapture.lastOnScreenOnly,"Selected window resolves independently of selection-panel visibility")
            MockCapture.content(windows: [])
            try await wait({ CaptureSelection.copyFailed == failed + 1 },"missing-window failure keeps copy range")
            try require(NSPasteboard.general.fixturePNG == previousPNG && CaptureSelection.copySucceeded == beforeCopy && MockCapture.pendingImage == 0,
                        "A missing magnet target preserves the clipboard and never copies desktop background")
            CaptureSelection.lastCompletion?(.copy(windowRegion))
            try await wait({ MockCapture.pendingContent == 1 },"retry the same magnet identity")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 },"isolated magnet image")
            try require(SCContentFilter.lastWindowID == 42,"Retry uses the exact isolated window")
            try require(MockCapture.lastConfiguration?.shouldBeOpaque == false && MockCapture.lastConfiguration?.backgroundColor?.alpha == 0,
                        "Frozen window request preserves transparent alpha for a shape-only mask")
            MockCapture.image(laterWindow)
            try await wait({ CaptureSelection.copySucceeded == beforeCopy + 1 },"magnet PNG reaches clipboard acknowledgement")
            let isolatedBytes = NSPasteboard.general.fixturePNG!
            let isolatedPNG = CGImageSourceCreateWithData(isolatedBytes as CFData,nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }!
            let isolatedPixels = CapturePixelSampler(image: isolatedPNG)!
            try require(isolatedPNG.width == 8 && isolatedPNG.height == 8,"Magnet PNG retains its window point-to-pixel scale")
            try require(isolatedPixels.sample(x: 0,y: 0)?.hex == "#FFFFFF" && isolatedPixels.sample(x: 7,y: 0)?.hex == "#FFFFFF" &&
                        isolatedPixels.sample(x: 0,y: 7)?.hex == "#FFFFFF" && isolatedPixels.sample(x: 7,y: 7)?.hex == "#FFFFFF",
                        "All four decoded clipboard corners are white, never the green desktop")
            try require(isolatedPixels.sample(x: 4,y: 4)?.hex == "#FF0000","Clipboard keeps frozen red: \(isolatedPixels.sample(x:4,y:4)!.hex)")
            try require((0..<8).allSatisfy { y in (0..<8).allSatisfy { x in
                isolatedPixels.sample(x: x,y: y)?.hex == ((2..<6).contains(x) && (2..<6).contains(y) ? "#FF0000" : "#FFFFFF")
            } },"Every decoded clipboard pixel is frozen content or white shape padding")
            magnet.stop()
            for editing in [true,false] {
                let frozenModule = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); frozenModule.start(); frozenModule.capture()
                try await succeedImage(desktop)
                try await wait({ CaptureSelection.lastCompletion != nil },"frozen edit/pin range ready")
                let beforePins = CapturePins.images.count
                CaptureSelection.lastCompletion?(editing ? .edit(windowRegion) : .pin(windowRegion))
                try await succeedImage(laterWindow)
                try await wait({ editing ? CaptureEditor.current != nil : CapturePins.images.count == beforePins + 1 },"frozen edit/pin delivered")
                let delivered = editing ? CaptureEditor.current!.image : CapturePins.images.last!
                let pixels = CapturePixelSampler(image: delivered)!
                try require(pixels.sample(x: 4,y: 4)?.hex == "#FF0000" && pixels.sample(x: 0,y: 0)?.hex == "#FFFFFF",
                            "Editor and F3 both use frozen red content and white corners, not later blue pixels")
                frozenModule.stop()
            }
            CaptureSelection.fixtureWindow = nil
            CaptureEditor.encodesFixturePNG = false; NSPasteboard.general.acceptsFixtureWrites = false
            NSPasteboard.general.fixturePNG = nil
            try require(MockCapture.preflightCalls == 0, "all active paths avoid advisory checks")
            try require(CGPreflightScreenCaptureAccess() == false, "mock advisory really returns false")
            let snapshotModule = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); snapshotModule.start()
            var released = 0
            snapshotModule.capture(snapshotReady: { released += 1 })
            try await wait({ MockCapture.pendingContent == 1 }, "frozen switcher capture metadata")
            try require(released == 0, "switcher remains visible before snapshot")
            MockCapture.content()
            try await wait({ MockCapture.pendingImage == 1 }, "frozen switcher image")
            try require(released == 0, "switcher remains visible until pixels arrive")
            MockCapture.image(image)
            try await wait({ released == 1 }, "snapshot releases switcher")
            snapshotModule.capture(snapshotReady: { released += 1 })
            try await wait({ MockCapture.pendingContent == 1 }, "cancelled snapshot metadata")
            snapshotModule.stop()
            try require(released == 2, "stop releases frozen switcher exactly once")
            MockCapture.content(error: unrelated); try await settle()
            try require(released == 2, "late snapshot completion cannot release a newer session")
            let shelving = CaptureModule(images: CaptureImageService(reuseDisplayMetadata: false)); shelving.start(); shelving.capture()
            try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "shelf selection")
            let requestCount = CaptureSelection.shelfRequests
            shelving.shelve()
            try require(CaptureSelection.shelfRequests == requestCount+1, "F4 follows current F1 selection, never stale clipboard")
            CaptureShelf.held = true
            let beforeShelf = CaptureSelection.dismissals
            CaptureSelection.lastCompletion?(.shelf(region))
            try await wait({ CaptureShelf.pending.count == 1 }, "shelf persists before dismissing frozen backdrop")
            try require(CaptureSelection.dismissals == beforeShelf, "Frozen selection survives until durable shelf save")
            CaptureShelf.pending.removeFirst()(true)
            try require(CaptureSelection.dismissals == beforeShelf+1, "Successful shelf save releases screenshot")
            shelving.capture(); try await succeedImage(image)
            try await wait({ CaptureSelection.lastCompletion != nil }, "shelf next capture ready")
            CaptureSelection.lastCompletion?(.edit(region))
            try await wait({ CaptureEditor.current != nil }, "shelf annotated screenshot")
            shelving.shelve()
            try await wait({ CaptureShelf.pending.count == 1 }, "annotated image goes to shelf")
            let retainedEditor = CaptureEditor.current
            CaptureShelf.pending.removeFirst()(false)
            try require(CaptureEditor.current === retainedEditor, "A failed shelf save retains the editor")
            shelving.shelve(); CaptureShelf.pending.removeFirst()(true)
            try require(CaptureEditor.current == nil, "Successful annotated shelf save closes editor")
            CaptureShelf.held = false; shelving.stop()
            print("PASS capture access: \(checks) assertions; false advisory + actual API success, exact refusal classification, other errors, cancellation, latest request, process proof, recording start/stop, and termination; no capture/TCC/UI/general clipboard")
        } catch {
            FileHandle.standardError.write(Data("FAIL capture access: \(error)\n".utf8)); exit(1)
        }
    }
    static func isPermission(_ error: Error) -> Bool { if case CaptureFailure.permission = error { return true }; return false }
}

@MainActor final class CaptureShelf {
    func focusIfAlreadyOpen() -> Bool { false }
    func showForKeyboard() -> Bool { false }
    static var images: [CGImage] = []
    static var held = false
    static var pending: [(Bool) -> Void] = []
    func showMessage(_ text: String) { onStatus?(text) }
    var canAdd = true
    var onStatus: ((String) -> Void)?
    var onPin: ((CGImage, CGRect?) -> Void)?
    func start() {}
    func stop() {}
    func setSuspended(_ value: Bool) {}
    func add(_ image: CGImage, completion: @escaping (Bool) -> Void) { Self.images.append(image); if Self.held { Self.pending.append(completion) } else { completion(true) } }
}
