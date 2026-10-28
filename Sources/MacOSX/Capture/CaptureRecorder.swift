import AppKit
@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit

/// macOS 14 recording with optional system/microphone audio. Sample processing and
/// writer state live on one queue; queueDepth=3, one retained final frame, and
/// dropping frames under encoder pressure bound the working set.
final class CaptureRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private enum State { case idle, starting, recording, finishing }
    private let queue = DispatchQueue(label: "cc.anjing.macos-x.capture.recording", qos: .userInitiated)
    private var state: State = .idle
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var audio: RecordingAudioWriter?
    private var audioOptions = RecordingAudioOptions()
    private var microphone: RecordingMicrophone?
    private var audioTimer: DispatchSourceTimer?
    private let authorizeMicrophone: (@escaping (Bool) -> Void) -> Void
    private var temporaryURL: URL?
    private var destination: URL?
    private var firstTime: CMTime?
    private var lastSample: CMSampleBuffer?
    private var startedAt: CFTimeInterval = 0
    private var endedAt: CFTimeInterval?
    private var wantsStop = false
    private var interrupted: Error?
    private var onStarted: ((Result<Void, Error>) -> Void)?
    private var onFinished: ((URL?, Error?) -> Void)?
    private var stopCompletions: [() -> Void] = []
    private var lifetime: CaptureRecorder?
    private var session: UInt64 = 0
    private var finishStarted = false
    private var failureInProgress = false

    init(authorizeMicrophone: @escaping (@escaping (Bool) -> Void) -> Void = RecordingMicrophone.authorize) {
        self.authorizeMicrophone = authorizeMicrophone
        super.init()
    }

    func start(screen: CaptureScreen, region: CGRect? = nil, destination: URL,
               audioOptions: RecordingAudioOptions = .init(),
               started: @escaping (Result<Void, Error>) -> Void,
               finished: @escaping (URL?, Error?) -> Void) {
        queue.async { [self] in
            guard state == .idle else {
                DispatchQueue.main.async { started(.failure(CaptureFailure.message("录屏正在开始或结束，请稍后。"))) }; return
            }
            session &+= 1; let expected = session
            state = .starting; lifetime = self; wantsStop = false; interrupted = nil
            endedAt = nil
            finishStarted = false; failureInProgress = false
            onStarted = started; onFinished = finished; self.destination = destination
            self.audioOptions = audioOptions
            if audioOptions.microphone {
                authorizeMicrophone { [weak self] allowed in
                    self?.queue.async { [weak self] in
                        guard let self, self.session == expected, self.state == .starting else { return }
                        guard !self.wantsStop else { self.fail(CaptureFailure.cancelled); return }
                        guard allowed else {
                            self.fail(CaptureFailure.message("麦克风未获授权。请在系统设置中允许麦克风，或关闭录屏的麦克风选项。")); return
                        }
                        self.acquire(screen: screen, region: region, destination: destination, expected: expected)
                    }
                }
            } else { acquire(screen: screen, region: region, destination: destination, expected: expected) }
        }
    }

    private func acquire(screen: CaptureScreen, region: CGRect?, destination: URL, expected: UInt64) {
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
                self?.queue.async { [weak self] in
                    guard let self, self.session == expected, self.state == .starting else { return }
                    guard !self.wantsStop else { self.fail(CaptureFailure.cancelled); return }
                    guard let display = content?.displays.first(where: { $0.displayID == screen.id }) else {
                        self.fail(error ?? CaptureFailure.unavailable); return
                    }
                    do {
                        guard let region = CaptureRecordingRegion(screen: screen, region: region ?? screen.frame) else {
                            throw CaptureFailure.message("录屏区域无效，请在同一块屏幕内重新选择。")
                        }
                        let width = region.width, height = region.height
                        let temporary = CaptureRecordingFile.workingURL(for: destination)
                        self.temporaryURL = temporary
                        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
                        self.writer = writer
                        let input = AVAssetWriterInput(mediaType: .video,
                            outputSettings: CaptureRecordingPreset.videoSettings(width: width, height: height))
                        input.expectsMediaDataInRealTime = true
                        guard writer.canAdd(input) else { throw CaptureFailure.message("当前编码器无法写入 MP4。") }
                        writer.add(input)
                        if self.audioOptions.enabled { self.audio = try RecordingAudioWriter(writer: writer, options: self.audioOptions) }
                        guard writer.startWriting() else { throw writer.error ?? CaptureFailure.message("无法创建录屏文件。") }
                        self.temporaryURL = temporary; self.writer = writer; self.input = input
                        let configuration = SCStreamConfiguration()
                        configuration.sourceRect = region.source
                        configuration.width = width; configuration.height = height
                        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CaptureRecordingPreset.frameRate)
                        configuration.queueDepth = 3
                        configuration.pixelFormat = kCVPixelFormatType_32BGRA
                        configuration.showsCursor = true
                        configuration.capturesAudio = self.audioOptions.system
                        configuration.sampleRate = 48_000; configuration.channelCount = 2
                        configuration.excludesCurrentProcessAudio = true
                        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                                              configuration: configuration, delegate: self)
                        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                        if self.audioOptions.system { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue) }
                        self.stream = stream
                        stream.startCapture { [weak self] error in
                            self?.queue.async { [weak self] in
                                guard let self, self.session == expected, self.stream === stream,
                                      self.state == .starting else { return }
                                if let error { self.fail(error); return }
                                self.startMicrophone(expected: expected)
                            }
                        }
                    } catch { self.fail(error) }
                }
            }
    }

    private func startMicrophone(expected: UInt64) {
        guard audioOptions.microphone, !wantsStop else { startedRecording(); return }
        let microphone = RecordingMicrophone(); self.microphone = microphone
        microphone.start(on: queue, receive: { [weak self] sample, hostTime in
            guard let self, self.session == expected, self.state == .starting || self.state == .recording,
                  let streamClock = self.stream?.synchronizationClock else { return }
            self.receiveAudio(sample, source: .microphone,
                time: CMSyncConvertTime(hostTime, from: CMClockGetHostTimeClock(), to: streamClock))
        }, failure: { [weak self] error in
            guard let self, self.session == expected, self.state == .starting || self.state == .recording else { return }
            self.interrupted = error; self.end()
        }, completion: { [weak self] error in
            guard let self, self.session == expected, self.state == .starting else { return }
            if let error { self.fail(error); return }
            self.startedRecording()
        })
    }

    private func startedRecording() {
        state = .recording
        if audio != nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, self.state == .recording, self.firstTime != nil else { return }
                do { try self.audio?.flush(through: max(0, CACurrentMediaTime() - self.startedAt - 0.15)) }
                catch { self.interrupted = self.writer?.error ?? error; self.end() }
            }
            audioTimer = timer; timer.resume()
        }
        let callback = onStarted; onStarted = nil
        DispatchQueue.main.async { callback?(.success(())) }
        if wantsStop { end() }
    }

    private func receiveAudio(_ sample: CMSampleBuffer, source: RecordingAudioMixer.Source, time: CMTime) {
        do { try audio?.receive(sample, source: source, hostTime: time) }
        catch { interrupted = writer?.error ?? error; end() }
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            if let completion {
                if state == .idle { DispatchQueue.main.async { completion() }; return }
                stopCompletions.append(completion)
            }
            wantsStop = true
            if state == .recording { end() }
            else if state == .starting, stream == nil { fail(CaptureFailure.cancelled) }
            // A pending shareable-content/start callback performs the same end.
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard self.stream === stream, (state == .starting || state == .recording),
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let writer, let input, writer.status == .writing else { return }
        if type == .audio {
            receiveAudio(sampleBuffer, source: .system, time: sampleBuffer.presentationTimeStamp); return
        }
        guard type == .screen, sampleBuffer.imageBuffer != nil else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let status = attachments.first?[.status] as? Int,
           status != SCFrameStatus.complete.rawValue { return }
        if firstTime == nil {
            firstTime = sampleBuffer.presentationTimeStamp
            startedAt = CACurrentMediaTime()
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            audio?.begin(at: sampleBuffer.presentationTimeStamp)
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
        endedAt = CACurrentMediaTime()
        audioTimer?.cancel(); audioTimer = nil
        if alreadyStopped { stopMicrophone { [weak self] in self?.finishFile() } }
        else if let stream {
            stream.stopCapture { [weak self] error in
                self?.queue.async { [weak self] in
                    guard let self, self.session == expected, self.stream === stream,
                          self.state == .finishing, !self.failureInProgress else { return }
                    if let error, self.interrupted == nil { self.interrupted = CaptureFailure.screenCaptureError(error) }
                    self.stopMicrophone { [weak self] in self?.finishFile() }
                }
            }
        } else { stopMicrophone { [weak self] in self?.finishFile() } }
    }

    private func stopMicrophone(_ completion: @escaping () -> Void) {
        guard let microphone else { completion(); return }
        self.microphone = nil
        microphone.stop(on: queue, completion: completion)
    }

    private func finishFile() {
        guard state == .finishing, !finishStarted, !failureInProgress else { return }
        finishStarted = true
        guard writer != nil, input != nil, let firstTime, temporaryURL != nil, destination != nil else {
            fail(interrupted ?? CaptureFailure.message("未收到画面，未保存空文件。"), streamAlreadyStopped: true); return
        }
        // Native stream/device teardown can take hundreds of milliseconds. That
        // wait is not recorded time and must not extend the final frame/audio.
        let elapsed = max(1.0 / Double(CaptureRecordingPreset.frameRate), (endedAt ?? CACurrentMediaTime()) - startedAt)
        let endTime = CMTimeAdd(firstTime, CMTime(seconds: elapsed, preferredTimescale: 600))
        drainFinalAudio(through: elapsed, endTime: endTime, deadline: CACurrentMediaTime() + 3)
    }

    private func drainFinalAudio(through elapsed: TimeInterval, endTime: CMTime, deadline: CFTimeInterval) {
        guard state == .finishing, !failureInProgress else { return }
        do {
            if try audio?.flush(through: elapsed, final: true) == false {
                if writer?.status == .writing, CACurrentMediaTime() < deadline {
                    let expected = session
                    queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
                        guard let self, self.session == expected else { return }
                        self.drainFinalAudio(through: elapsed, endTime: endTime, deadline: deadline)
                    }
                    return
                }
                interrupted = writer?.error ?? CaptureFailure.message("音频编码未及时完成，已保留可用录屏。")
            }
        } catch { interrupted = writer?.error ?? error }
        if let audio, audio.droppedBlocks > 0 {
            interrupted = interrupted ?? CaptureFailure.message("音频编码繁忙，部分声音未保留；录屏文件已保存。")
        }
        if audioOptions.system, audio?.receivedSources.contains(.system) != true {
            interrupted = interrupted ?? CaptureFailure.message("未收到系统声音数据，已保留画面。")
        }
        if audioOptions.microphone, audio?.receivedSources.contains(.microphone) != true {
            interrupted = interrupted ?? CaptureFailure.message("未收到麦克风数据，已保留画面。")
        }
        completeFile(endTime: endTime)
    }

    private func completeFile(endTime: CMTime) {
        guard let writer, let input, let temporaryURL, let destination else { return }
        let expected = session
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
        audio?.input.markAsFinished()
        writer.finishWriting { [weak self] in
            self?.queue.async { [weak self] in
                guard let self, self.session == expected, self.state == .finishing,
                      self.writer === writer, !self.failureInProgress else { return }
                var error = self.interrupted
                var output: URL?
                if writer.status == .completed {
                    let result = CaptureRecordingFile.publish(temporaryURL, to: destination)
                    output = result.url
                    if let failure = result.error { error = failure }
                } else { error = writer.error ?? CaptureFailure.message("MP4 封装失败。") }
                let callback = self.onFinished
                // Only incomplete encoder output may be discarded. A completed
                // video survives destination errors and is surfaced to the user.
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
        audioTimer?.cancel(); audioTimer = nil
        let expected = session
        let started = onStarted, finished = onFinished
        writer?.cancelWriting()
        let cleanup = { [weak self] in
            guard let self, self.session == expected, self.failureInProgress else { return }
            if let temporaryURL = self.temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            self.stopMicrophone {
                self.reset()
                DispatchQueue.main.async { started?(.failure(error)); if started == nil { finished?(nil, error) } }
            }
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
        endedAt = nil
        audioTimer?.cancel(); audioTimer = nil; audio = nil; microphone = nil; audioOptions = .init()
        firstTime = nil; lastSample = nil; wantsStop = false; interrupted = nil; onStarted = nil; onFinished = nil
        finishStarted = false; failureInProgress = false
        let completions = stopCompletions; stopCompletions.removeAll()
        lifetime = nil
        if !completions.isEmpty { DispatchQueue.main.async { completions.forEach { $0() } } }
    }
}
