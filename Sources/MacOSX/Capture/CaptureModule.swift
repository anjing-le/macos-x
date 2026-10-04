import AppKit
import UniformTypeIdentifiers

@MainActor
final class CaptureModule {
    var onPermissionNeeded: (() -> Void)?
    var onStatusChange: ((String) -> Void)?
    private let images = CaptureImageService()
    private let selection = CaptureSelection()
    private let pins = CapturePins()
    private let recorder = CaptureRecorder()
    private let work = DispatchQueue(label: "cc.anjing.macos-x.capture.actions", qos: .userInitiated)
    private let status = NSTextField(wrappingLabelWithString: "未启用")
    private let recordButton = NSButton(title: "开始录屏…", target: nil, action: nil)
    private var editor: CaptureEditor?
    private var running = false
    private var generation: UInt64 = 0
    private var captureRevision: UInt64 = 0
    private var captureTicket: CaptureImageService.Ticket?
    private var clipboardInFlight = false
    private var lastRegion: CGRect?
    private enum RecordingState { case idle, checking, choosing, starting, recording, finishing }
    private var recordingState: RecordingState = .idle
    private var recordingPanel: NSSavePanel?
    private var terminating = false
    private lazy var view: NSView = buildSettings()
    var settingsView: NSView { view }
    var isRecording: Bool { recordingState != .idle }

    init() {
        pins.onStatus = { [weak self] in self?.setStatus($0) }
    }
    func start() {
        guard !running, !terminating else { return }
        running = true
        setStatus(recordingState == .idle ? "已就绪" : "正在保存录屏…")
    }
    func stop() {
        running = false; generation &+= 1
        images.cancel(); captureTicket?.cancel(); captureTicket = nil
        selection.dismiss(); editor?.close(); editor = nil; pins.closeAll(); lastRegion = nil
        recordingPanel?.cancel(nil); recordingPanel = nil
        if recordingState == .checking || recordingState == .choosing { recordingState = .idle }
        if recordingState != .idle { recordingState = .finishing; updateRecordButton() }
        recorder.stop()
        setStatus(recordingState == .idle ? "已停用" : "正在保存录屏…")
    }

    /// AppDelegate should return terminateLater and reply only after this callback.
    /// This also cancels a pending save dialog before it can start a new stream.
    func prepareToTerminate(completion: @escaping () -> Void) {
        terminating = true
        stop()
        recorder.stop(completion: completion)
    }

    func capture() {
        guard running, !terminating else { return }
        captureRevision &+= 1; let expected = generation, captureRevision = captureRevision
        selection.dismiss(); editor?.close(); editor = nil
        let screens = screenDescriptors()
        setStatus("正在截图…")
        captureTicket = images.capture(screens) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected, self.captureRevision == captureRevision else { return }
                switch result {
                case .failure(let error): self.handle(error)
                case .success(let frames):
                    self.setStatus("⌘C 复制 · ⌥ 取色 · Esc 取消")
                    self.selection.present(frames, previousRegion: self.lastRegion,
                                           windows: frames.first?.windows ?? []) { [weak self] result in
                        guard let self, self.running, self.generation == expected, self.captureRevision == captureRevision else { return }
                        self.finishSelection(result, frames: frames, generation: expected, revision: captureRevision)
                    }
                }
            }
        }
    }

    private func finishSelection(_ result: CaptureSelection.Result, frames: [CaptureFrame],
                                 generation expected: UInt64, revision: UInt64) {
        let region: CGRect
        switch result {
        case .cancel: setStatus("已取消截图。"); return
        case .color(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            setStatus("已复制 \(value)"); return
        case .copy(let rect), .pin(let rect), .edit(let rect): region = rect
        }
        let ticket = captureTicket, tool = selection.selectedTool
        setStatus("正在处理…")
        work.async { [weak self] in
            guard ticket?.valid == true else { return }
            let image = autoreleasepool { CaptureImageService.composite(frames, selection: region) }
            let data: Data?
            if case .copy = result, let image { data = autoreleasepool { CaptureEditor.pngData(image) } }
            else { data = nil }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == expected,
                      self.captureRevision == revision, ticket?.valid == true else { return }
                guard let image else { self.selection.dismiss(); self.handle(CaptureFailure.oversized); return }
                switch result {
                case .copy:
                    guard let data else { self.setStatus("截图编码失败，未修改剪贴板。"); return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: .png)
                    self.lastRegion = region; self.setStatus("已复制截图。")
                case .pin:
                    self.lastRegion = region; self.pins.add(image, at: region)
                case .edit:
                    self.openEditor(image, at: region, tool: tool)
                case .color, .cancel: break
                }
            }
        }
    }

    func pinClipboard() {
        guard running, !terminating, !clipboardInFlight else { return }
        if pins.restoreLastClosed() { return }
        let expected = generation
        let board = NSPasteboard.general
        let data = board.data(forType: .png) ?? board.data(forType: .tiff)
        let text = data == nil ? board.string(forType: .string) : nil
        guard data != nil || text != nil else { handle(CaptureFailure.emptyClipboard); return }
        clipboardInFlight = true
        work.async { [weak self] in
            let image = autoreleasepool { data.flatMap(CaptureClipboard.image(from:)) ?? text.flatMap(CaptureClipboard.text) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clipboardInFlight = false
                guard self.running, self.generation == expected else { return }
                if let image { self.pins.add(image) }
                else { self.setStatus("剪贴板过大或无法读取。") }
            }
        }
    }

    func togglePins() {
        guard running, !terminating else { return }
        pins.toggleAll()
    }

    func toggleRecording() {
        guard running, !terminating else { return }
        if recordingState == .recording || recordingState == .starting {
            recordingState = .finishing; updateRecordButton(); setStatus("正在保存录屏…")
            recorder.stop(); return
        }
        guard recordingState == .idle else { return }
        guard let screen = screenDescriptors().first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screenDescriptors().first else {
            handle(CaptureFailure.unavailable); return
        }
        let expected = generation
        recordingState = .checking; updateRecordButton()
        work.async { [weak self] in
            let granted = CGPreflightScreenCaptureAccess()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, self.generation == expected, self.recordingState == .checking else { return }
                guard granted else { self.recordingState = .idle; self.updateRecordButton(); self.handle(CaptureFailure.permission); return }
                self.chooseRecordingDestination(screen)
            }
        }
    }

    private func chooseRecordingDestination(_ screen: CaptureScreen) {
        recordingState = .choosing; updateRecordButton()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "录屏.mp4"
        panel.message = "当前显示器 · 1920 像素 / 30 fps · 无音频"
        recordingPanel = panel
        panel.begin { [weak self] response in
            guard let self, self.recordingPanel === panel else { return }
            self.recordingPanel = nil
            guard self.running, !self.terminating, self.recordingState == .choosing else { return }
            guard response == .OK, let url = panel.url else {
                self.recordingState = .idle; self.updateRecordButton(); self.setStatus("已取消录屏。" ); return
            }
            self.recordingState = .starting; self.updateRecordButton(); self.setStatus("正在启动录屏…")
            self.recorder.start(screen: screen, destination: url, started: { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .failure(let error):
                        self.recordingState = .idle; self.updateRecordButton()
                        if self.running { self.handle(error) }
                    case .success:
                        if !self.running || self.recordingState == .finishing {
                            self.recordingState = .finishing; self.recorder.stop()
                        } else {
                            self.recordingState = .recording; self.setStatus("录屏中 · 再次操作结束")
                        }
                        self.updateRecordButton()
                    }
                }
            }, finished: { [weak self] url, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.recordingState = .idle; self.updateRecordButton()
                    guard self.running, !self.terminating else { return }
                    if let url {
                        self.setStatus(error == nil ? "已保存录屏：\(url.lastPathComponent)" : "录屏中断，已保存可用片段：\(url.lastPathComponent)")
                    } else { self.handle(error ?? CaptureFailure.message("录屏未生成可保存的画面。")) }
                }
            })
        }
    }

    private func openEditor(_ image: CGImage, at region: CGRect, tool: CaptureTool) {
        let editor = CaptureEditor(image: image, selectionFrame: region, initialTool: tool)
        editor.onExport = { [weak self] in self?.lastRegion = region }
        editor.onPin = { [weak self] in self?.lastRegion = region; self?.pins.add($0, at: region) }
        editor.onClose = { [weak self, weak editor] in
            guard let self, self.editor === editor else { return }
            self.editor = nil; self.selection.dismiss()
        }
        self.editor = editor; editor.present()
        setStatus("Enter / ⌘C 复制")
    }
    private func handle(_ error: Error) {
        setStatus(error.localizedDescription)
        if case CaptureFailure.permission = error { onPermissionNeeded?() }
    }
    private func setStatus(_ value: String) { status.stringValue = value; onStatusChange?(value) }
    private func updateRecordButton() {
        recordButton.title = recordingState == .idle ? "开始录屏…" : (recordingState == .finishing ? "正在保存…" : "结束录屏")
        recordButton.isEnabled = recordingState != .checking && recordingState != .choosing && recordingState != .finishing
    }
    private func screenDescriptors() -> [CaptureScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return CaptureScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }
    private func buildSettings() -> NSView {
        let capture = NSButton(title: "截图…", target: self, action: #selector(captureAction))
        let pin = NSButton(title: "贴出剪贴板", target: self, action: #selector(pinAction))
        recordButton.target = self; recordButton.action = #selector(recordAction)
        let primary = NSStackView(views: [capture, pin, recordButton]); primary.spacing = 12
        let show = NSButton(title: "显示贴图", target: self, action: #selector(showPins))
        let hide = NSButton(title: "隐藏贴图", target: self, action: #selector(hidePins))
        let restore = NSButton(title: "恢复交互", target: self, action: #selector(restorePins))
        let close = NSButton(title: "关闭全部贴图", target: self, action: #selector(closePins))
        let secondary = NSStackView(views: [show, hide, restore, close]); secondary.spacing = 10
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 600
        let stack = NSStackView(views: [primary, secondary, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        return stack
    }
    @objc private func captureAction() { capture() }
    @objc private func pinAction() { pinClipboard() }
    @objc private func recordAction() { toggleRecording() }
    @objc private func showPins() { pins.showAll() }
    @objc private func hidePins() { pins.hideAll() }
    @objc private func restorePins() { pins.restoreInteraction() }
    @objc private func closePins() { pins.closeAll(); setStatus("已关闭全部贴图。") }
}
