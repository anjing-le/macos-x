@preconcurrency import AVFoundation

/// AVCapture's public audio-only path also supports macOS 14. Device startup
/// and teardown never block the UI or the recorder's sample queue.
final class RecordingMicrophone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let control = DispatchQueue(label: "cc.anjing.macos-x.recording.microphone", qos: .userInitiated)
    private let session = AVCaptureSession()
    private var output: AVCaptureAudioDataOutput?
    private var observer: NSObjectProtocol?
    private var receive: ((CMSampleBuffer, CMTime) -> Void)?

    static func authorize(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
        default: completion(false)
        }
    }

    func start(on queue: DispatchQueue, receive: @escaping (CMSampleBuffer, CMTime) -> Void,
               failure: @escaping (Error) -> Void, completion: @escaping (Error?) -> Void) {
        self.receive = receive
        control.async { [self] in
            do {
                guard let device = AVCaptureDevice.default(for: .audio) else {
                    throw CaptureFailure.message("未找到可用麦克风，请关闭麦克风选项或连接设备。")
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureAudioDataOutput()
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw CaptureFailure.message("当前麦克风无法录制。")
                }
                session.addInput(input); session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: queue)
                session.commitConfiguration(); self.output = output
                observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError,
                    object: session, queue: nil) { notification in
                    let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                        ?? CaptureFailure.message("麦克风录制中断。")
                    queue.async { failure(error) }
                }
                session.startRunning()
                let error: Error? = session.isRunning ? nil : CaptureFailure.message("麦克风未能启动。")
                queue.async { completion(error) }
            } catch { queue.async { completion(error) } }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let clock = session.synchronizationClock else { return }
        let hostTime = CMSyncConvertTime(sample.presentationTimeStamp, from: clock, to: CMClockGetHostTimeClock())
        receive?(sample, hostTime)
    }

    func stop(on queue: DispatchQueue, completion: @escaping () -> Void) {
        receive = nil
        control.async { [self] in
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            output?.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
            queue.async { completion() }
        }
    }
}
