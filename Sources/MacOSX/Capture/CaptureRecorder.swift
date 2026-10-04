import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// macOS 14 recording without microphone/system audio. Sample processing and
/// writer state live on one queue; queueDepth=3, one retained final frame, and
/// dropping frames under encoder pressure bound the working set.
final class CaptureRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private enum State { case idle, starting, recording, finishing }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.recording", qos: .userInitiated)
    private var state: State = .idle
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var temporaryURL: URL?
    private var destination: URL?
    private var firstTime: CMTime?
    private var lastSample: CMSampleBuffer?
    private var startedAt: CFTimeInterval = 0
    private var wantsStop = false
    private var interrupted: Error?
    private var onStarted: ((Result<Void, Error>) -> Void)?
    private var onFinished: ((URL?, Error?) -> Void)?
    private var stopCompletions: [() -> Void] = []
    private var lifetime: CaptureRecorder?
    private var session: UInt64 = 0
    private var finishStarted = false
    private var failureInProgress = false

    func start(screen: CaptureScreen, destination: URL,
               started: @escaping (Result<Void, Error>) -> Void,
               finished: @escaping (URL?, Error?) -> Void) {
        queue.async { [self] in
            guard state == .idle else {
                DispatchQueue.main.async { started(.failure(CaptureFailure.message("录屏正在开始或结束，请稍后。"))) }; return
            }
            session &+= 1; let expected = session
            state = .starting; lifetime = self; wantsStop = false; interrupted = nil
            finishStarted = false; failureInProgress = false
            onStarted = started; onFinished = finished; self.destination = destination
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
                self?.queue.async { [weak self] in
                    guard let self, self.session == expected, self.state == .starting else { return }
                    guard !self.wantsStop else { self.fail(CaptureFailure.cancelled); return }
                    guard let display = content?.displays.first(where: { $0.displayID == screen.id }) else {
                        self.fail(error ?? CaptureFailure.unavailable); return
                    }
                    do {
                        let ratio = min(1, 1920 / max(1, max(screen.frame.width, screen.frame.height) * screen.scale))
                        let width = max(2, Int(screen.frame.width * screen.scale * ratio) / 2 * 2)
                        let height = max(2, Int(screen.frame.height * screen.scale * ratio) / 2 * 2)
                        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("macos-x-\(UUID().uuidString).mp4")
                        self.temporaryURL = temporary
                        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
                        self.writer = writer
                        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                            AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: width, AVVideoHeightKey: height,
                            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000,
                                                               AVVideoExpectedSourceFrameRateKey: 30,
                                                               AVVideoMaxKeyFrameIntervalKey: 30]
                        ])
                        input.expectsMediaDataInRealTime = true
                        guard writer.canAdd(input) else { throw CaptureFailure.message("当前编码器无法写入 MP4。") }
                        writer.add(input)
                        guard writer.startWriting() else { throw writer.error ?? CaptureFailure.message("无法创建录屏文件。") }
                        self.temporaryURL = temporary; self.writer = writer; self.input = input
                        let configuration = SCStreamConfiguration()
                        configuration.width = width; configuration.height = height
                        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                        configuration.queueDepth = 3
                        configuration.pixelFormat = kCVPixelFormatType_32BGRA
                        configuration.showsCursor = true
                        configuration.capturesAudio = false
                        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                              configuration: configuration, delegate: self)
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                        self.stream = stream
                        stream.startCapture { [weak self] error in
                            self?.queue.async { [weak self] in
                                guard let self, self.session == expected, self.stream === stream,
                                      self.state == .starting else { return }
                                if let error { self.fail(error); return }
                                self.state = .recording
                                let callback = self.onStarted; self.onStarted = nil
                                DispatchQueue.main.async { callback?(.success(())) }
                                if self.wantsStop { self.end() }
                            }
                        }
                    } catch { self.fail(error) }
                }
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            if let completion {
                if state == .idle { DispatchQueue.main.async { completion() }; return }
                stopCompletions.append(completion)
            }
            wantsStop = true
            if state == .recording { end() }
            // A pending shareable-content/start callback performs the same end.
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, (state == .starting || state == .recording), type == .screen,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer), sampleBuffer.imageBuffer != nil,
              let writer, let input, writer.status == .writing else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue { return }
        if firstTime == nil {
            firstTime = sampleBuffer.presentationTimeStamp
            startedAt = CACurrentMediaTime()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
        }
        if input.isReadyForMoreMediaData {
            if input.append(sampleBuffer) { lastSample = sampleBuffer }
            else { interrupted = writer.error; end() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard self.stream === stream, state == .recording || state == .starting else { return }
            interrupted = CaptureFailure.screenCaptureError(error)
            end(alreadyStopped: true)
        }
    }

    private func end(alreadyStopped: Bool = false) {
        guard state == .recording || state == .starting else { return }
        let expected = session
        state = .finishing
        if alreadyStopped { finishFile() }
        else if let stream {
            stream.stopCapture { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, self.session == expected, self.stream === stream,
                          self.state == .finishing, !self.failureInProgress else { return }
                    if let error, self.interrupted == nil { self.interrupted = CaptureFailure.screenCaptureError(error) }
                    self.finishFile()
                }
            }
        } else { finishFile() }
    }

    private func finishFile() {
        guard state == .finishing, !finishStarted, !failureInProgress else { return }
        finishStarted = true
        guard let writer, let input, let firstTime, let temporaryURL, let destination else {
            fail(interrupted ?? CaptureFailure.message("未收到画面，未保存空文件。"), streamAlreadyStopped: true); return
        }
        let expected = session
        let elapsed = max(1.0 / 30, CACurrentMediaTime() - startedAt)
        let endTime = CMTimeAdd(firstTime, CMTime(seconds: elapsed, preferredTimescale: 600))
        // A static desktop may deliver only the initial frame. Append that frame
        // near the end so the MP4 keeps the user's actual recording duration.
        if let lastSample, input.isReadyForMoreMediaData {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                           presentationTimeStamp: CMTimeSubtract(endTime, CMTime(value: 1, timescale: 30)),
                                           decodeTimeStamp: .invalid)
            if CMTimeCompare(timing.presentationTimeStamp, lastSample.presentationTimeStamp) > 0 {
                var finalSample: CMSampleBuffer?
                if CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastSample,
                                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                        sampleBufferOut: &finalSample) == noErr, let finalSample {
                    _ = input.append(finalSample)
                }
            }
        }
        writer.endSession(atSourceTime: endTime)
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.session == expected, self.state == .finishing,
                      self.writer === writer, !self.failureInProgress else { return }
                var error = self.interrupted
                var output: URL?
                if writer.status == .completed {
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
                        } else { try FileManager.default.moveItem(at: temporaryURL, to: destination) }
                        output = destination
                    } catch let failure { error = failure }
                } else { error = writer.error ?? CaptureFailure.message("MP4 封装失败。") }
                let callback = self.onFinished
                if output == nil { try? FileManager.default.removeItem(at: temporaryURL) }
                self.reset()
                DispatchQueue.main.async { callback?(output, error) }
            }
        }
    }

    private func fail(_ error: Error, streamAlreadyStopped: Bool = false) {
        guard state != .idle, !failureInProgress else { return }
        let error = CaptureFailure.screenCaptureError(error)
        failureInProgress = true; state = .finishing
        let expected = session
        let started = onStarted, finished = onFinished
        writer?.cancelWriting()
        let cleanup = { [weak self] in
            guard let self, self.session == expected, self.failureInProgress else { return }
            if let temporaryURL = self.temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            self.reset()
            DispatchQueue.main.async { started?(.failure(error)); if started == nil { finished?(nil, error) } }
        }
        // A failed start must finish its acquired stream teardown before stop
        // completion can let application termination proceed.
        if let stream, !streamAlreadyStopped {
            stream.stopCapture { [weak self] _ in self?.queue.async { cleanup() } }
        } else { cleanup() }
    }
    private func reset() {
        session &+= 1
        state = .idle; stream = nil; writer = nil; input = nil; temporaryURL = nil; destination = nil
        firstTime = nil; lastSample = nil; wantsStop = false; interrupted = nil; onStarted = nil; onFinished = nil
        finishStarted = false; failureInProgress = false
        let completions = stopCompletions; stopCompletions.removeAll()
        lifetime = nil
        if !completions.isEmpty { DispatchQueue.main.async { completions.forEach { $0() } } }
    }
}
