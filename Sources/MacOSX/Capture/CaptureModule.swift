import AppKit

@MainActor
final class CaptureModule {
    var onPermissionNeeded: (() -> Void)?
    var onStatusChange: ((String) -> Void)?
    private let images = CaptureImageService()
    private let selection = CaptureSelection()
    private let pins = CapturePins()
    private let recorder = CaptureRecorder()
    private let recordingPresentation = RecordingPresentation()
    private let work = DispatchQueue(label: "cc.anjing.macos-x.capture.actions", qos: .userInitiated)
    private let status = NSTextField(wrappingLabelWithString: "未启用")
    private var editor: CaptureEditor?
    private var running = false
    private var generation: UInt64 = 0
    private var captureRevision: UInt64 = 0
    private var captureTicket: CaptureImageService.Ticket?
    // Includes capture acquisition and export, when no selection/editor accepts
    // input yet. Repeated pin shortcuts must not fall back to old clipboard data.
    private var snapshotReady: (() -> Void)?
    private var captureInProgress = false
    private var editorPending = false, pinAfterEditor = false
    private var clipboardInFlight = false
    private var lastRegion: CGRect?
    private var copiedRegion: (changeCount: Int, frame: CGRect)?
    private enum RecordingState { case idle, choosing, starting, recording, finishing }
    private var recordingState: RecordingState = .idle
    private var recordingRevision: UInt64 = 0
    private var terminating = false
    private lazy var view: NSView = buildSettings()
    var settingsView: NSView { view }
    var isRecording: Bool { recordingState != .idle }
    /// Observed success in this process; a later actual refusal clears it.
    /// Never persisted or inferred from the permission UI/preflight alone.
    private(set) var hasConfirmedScreenCaptureAccess = false

    init() {
        pins.onStatus = { [weak self] in self?.setStatus($0) }
        recordingPresentation.onStop = { [weak self] in self?.toggleRecording() }
    }
    func start() {
        guard !running, !terminating else { return }
        running = true
        recordingPresentation.resume()
        setStatus(recordingState == .idle ? "已就绪" : "正在保存录屏…")
    }
    func stop() {
        running = false; generation &+= 1
        images.cancel(); captureTicket?.cancel(); captureTicket = nil
        finishSnapshot()
        selection.dismiss(); editor?.close(); editor = nil; pins.closeAll(); lastRegion = nil
        copiedRegion = nil
        captureInProgress = false
        editorPending = false; pinAfterEditor = false
        if recordingState == .choosing { recordingState = .idle }
        if recordingState != .idle { recordingState = .finishing }
        recordingPresentation.dismiss()
        recorder.stop()
        setStatus(recordingState == .idle ? "已停用" : "正在保存录屏…")
    }

    /// AppDelegate should return terminateLater and reply only after this callback.
    /// This also cancels region selection before it can start a new stream.
    func prepareToTerminate(completion: @escaping () -> Void) {
        terminating = true
        stop()
        recorder.stop(completion: completion)
    }

    @discardableResult
    func capture(snapshotReady: (() -> Void)? = nil) -> Bool {
        guard running, !terminating, recordingState != .choosing else { return false }
        finishSnapshot()
        self.snapshotReady = snapshotReady
        captureRevision &+= 1; let expected = generation, captureRevision = captureRevision
        selection.dismiss(); editor?.close(); editor = nil
        captureInProgress = true
        editorPending = false; pinAfterEditor = false
        let screens = screenDescriptors()
        setStatus("正在截图…")
        captureTicket = images.capture(screens) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.running, self.generation == expected, self.captureRevision == captureRevision else { return }
                switch result {
                case .failure(let error): self.finishSnapshot(); self.captureInProgress = false; self.handle(error)
                case .success(let frames):
                    self.hasConfirmedScreenCaptureAccess = true
                    self.setStatus("⌘C 复制 · ⌥C 取色 · Esc 取消")
                    self.selection.present(frames, previousRegion: self.lastRegion,
                                           windows: frames.first?.windows ?? []) { [weak self] result in
                        guard let self, self.running, self.generation == expected, self.captureRevision == captureRevision else { return }
                        if let target = self.selection.completedWindow {
                            switch result {
                            case .copy, .pin, .edit:
                                if case .edit = result { self.editorPending = true }
                                self.captureTicket = self.images.capture(frames.map(\.screen), window: target) { [weak self] isolated in
                                    MainActor.assumeIsolated {
                                        guard let self, self.running, self.generation == expected, self.captureRevision == captureRevision else { return }
                                        switch isolated {
                                        case .success(let windowFrames):
                                            self.finishSelection(result, frames: windowFrames, generation: expected, revision: captureRevision)
                                        case .failure(let error):
                                            self.selection.dismiss(); self.captureInProgress = false
                                            self.editorPending = false; self.pinAfterEditor = false; self.handle(error)
                                        }
                                    }
                                }
                            case .color, .cancel:
                                self.finishSelection(result, frames: frames, generation: expected, revision: captureRevision)
                            }
                        } else {
                            self.finishSelection(result, frames: frames, generation: expected, revision: captureRevision)
                        }
                    }
                    self.finishSnapshot()
                }
            }
        }
        return true
    }

    private func finishSnapshot() {
        let completion = snapshotReady; snapshotReady = nil
        completion?()
    }

    private func finishSelection(_ result: CaptureSelection.Result, frames: [CaptureFrame],
                                 generation expected: UInt64, revision: UInt64) {
        let region: CGRect
        switch result {
        case .cancel: captureInProgress = false; setStatus("已取消截图。"); return
        case .color(let value):
            captureInProgress = false
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            setStatus("已复制 \(value)"); return
        case .copy(let rect), .pin(let rect), .edit(let rect): region = rect
        }
        let ticket = captureTicket
        if case .edit = result { editorPending = true }
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
                guard let image else {
                    self.captureInProgress = false; self.editorPending = false; self.pinAfterEditor = false
                    self.selection.dismiss(); self.handle(CaptureFailure.oversized); return
                }
                switch result {
                case .copy:
                    self.captureInProgress = false
                    guard let data else { self.setStatus("截图编码失败，未修改剪贴板。"); return }
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setData(data, forType: .png) else { self.setStatus("复制失败。"); return }
                    self.copiedRegion = (NSPasteboard.general.changeCount, region)
                    self.lastRegion = region; self.setStatus("已复制截图。")
                case .pin:
                    self.lastRegion = region
                    self.pins.add(image, at: region) { [weak self] shown in
                        guard let self, self.running, self.generation == expected, self.captureRevision == revision else { return }
                        self.captureInProgress = false; self.selection.dismiss()
                        if !shown { self.setStatus("贴图创建失败。") }
                    }
                case .edit:
                    self.openEditor(image, at: region)
                    self.editorPending = false
                    if self.pinAfterEditor { self.pinAfterEditor = false; self.editor?.pinCurrentImage() }
                case .color, .cancel: break
                }
            }
        }
    }

    /// The configured global pin action follows the current screenshot session.
    /// Clipboard pinning remains available once that session has ended.
    func pin() {
        guard running, !terminating, recordingState != .choosing else { return }
        guard pins.canAdd else { setStatus("最多 8 张贴图，请先关闭一张。"); return }
        if let editor { editor.pinCurrentImage() }
        else if pins.applyActiveEdit() { return }
        else if editorPending { pinAfterEditor = true }
        else if captureInProgress { selection.pinCurrentSelection() }
        else { pinClipboard() }
    }

    func pinClipboard() {
        guard running, !terminating, !clipboardInFlight else { return }
        if pins.restoreLastClosed() { return }
        let expected = generation, revision = captureRevision
        let board = NSPasteboard.general
        let placement = copiedRegion.flatMap { $0.changeCount == board.changeCount ? $0.frame : nil }
        let data = board.data(forType: .png) ?? board.data(forType: .tiff)
        let text = data == nil ? board.string(forType: .string) : nil
        guard data != nil || text != nil else { handle(CaptureFailure.emptyClipboard); return }
        clipboardInFlight = true
        work.async { [weak self] in
            let image = autoreleasepool { data.flatMap(CaptureClipboard.image(from:)) ?? text.flatMap(CaptureClipboard.text) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.clipboardInFlight = false
                guard self.running, self.generation == expected, self.captureRevision == revision else { return }
                if let image {
                    var frame = placement
                    // Text cards need readable point sizes, rather than the 480-point image thumbnail cap.
                    if text != nil {
                        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
                        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
                        let scale = min(1, min((available.width - 64) / CGFloat(image.width),
                                               (available.height - 64) / CGFloat(image.height)))
                        let size = CGSize(width: CGFloat(image.width) * max(0.1, scale),
                                          height: CGFloat(image.height) * max(0.1, scale))
                        frame = CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                                       width: size.width, height: size.height)
                    }
                    self.pins.add(image, at: frame)
                }
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
            recordingState = .finishing; recordingPresentation.saving(); setStatus("正在保存录屏…")
            recorder.stop(); return
        }
        if recordingState == .choosing {
            recordingRevision &+= 1
            images.cancel(); captureTicket?.cancel(); captureTicket = nil
            selection.dismiss(); recordingState = .idle; setStatus("已取消录屏。")
            return
        }
        guard recordingState == .idle else { return }
        guard let screen = screenDescriptors().first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? screenDescriptors().first else {
            handle(CaptureFailure.unavailable); return
        }
        captureRevision &+= 1
        selection.dismiss(); editor?.close(); editor = nil
        captureInProgress = false; editorPending = false; pinAfterEditor = false
        recordingState = .choosing; recordingRevision &+= 1
        let expected = generation, revision = recordingRevision
        setStatus("选择录屏区域 · Esc 取消")
        captureTicket = images.capture([screen]) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.terminating, self.generation == expected,
                      self.recordingRevision == revision, self.recordingState == .choosing else { return }
                switch result {
                case .failure(let error): self.recordingState = .idle; self.handle(error)
                case .success(let frames):
                    self.hasConfirmedScreenCaptureAccess = true
                    self.selection.present(frames, mode: .recording, windows: frames.first?.windows ?? []) { [weak self] result in
                        guard let self, self.running, !self.terminating, self.generation == expected,
                              self.recordingRevision == revision, self.recordingState == .choosing else { return }
                        self.selection.dismiss(); self.captureTicket = nil
                        guard case .edit(let region) = result else {
                            self.recordingState = .idle; self.setStatus("已取消录屏。"); return
                        }
                        self.startRecording(screen: screen, region: region, generation: expected, revision: revision)
                    }
                }
            }
        }
    }

    private func startRecording(screen: CaptureScreen, region: CGRect, generation expected: UInt64, revision: UInt64) {
        // File-system work is deferred until explicit Start; never hold the UI
        // or create files while the user is only selecting a region.
        setStatus("正在启动录屏…")
        let folder = recordingPresentation.recordingDirectory
        work.async { [weak self] in
            let result: Swift.Result<URL, Error> = Swift.Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                return folder.appendingPathComponent("录屏 \(formatter.string(from: Date())) \(UUID().uuidString.prefix(6)).mp4")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running, !self.terminating, self.generation == expected,
                      self.recordingRevision == revision, self.recordingState == .choosing else { return }
                guard case .success(let url) = result else {
                    self.recordingState = .idle
                    if case .failure(let error) = result { self.handle(error) }; return
                }
                self.recordingState = .starting; self.setStatus("正在启动录屏…")
                self.recorder.start(screen: screen, region: region, destination: url, started: { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, self.recordingRevision == revision else { return }
                        switch result {
                        case .failure(let error):
                            self.recordingState = .idle
                            self.recordingPresentation.completed(nil, announce: false)
                            if self.running, !self.terminating, self.generation == expected { self.handle(error) }
                        case .success:
                            if !self.running || self.terminating || self.generation != expected || self.recordingState == .finishing {
                                self.recordingState = .finishing; self.recorder.stop()
                            } else {
                                self.hasConfirmedScreenCaptureAccess = true
                                self.recordingState = .recording
                                self.recordingPresentation.began()
                                self.setStatus("录屏中")
                            }
                        }
                    }
                }, finished: { [weak self] url, error in
                    MainActor.assumeIsolated {
                        guard let self, self.recordingRevision == revision else { return }
                        self.recordingState = .idle
                        self.recordingPresentation.completed(url, announce: self.running && !self.terminating && self.generation == expected)
                        guard self.running, !self.terminating, self.generation == expected else { return }
                        if let error, case CaptureFailure.permission = CaptureFailure.screenCaptureError(error) {
                            self.hasConfirmedScreenCaptureAccess = false
                        }
                        if url != nil {
                            if let error { self.setStatus("录屏已保留：\(error.localizedDescription)") }
                            else { self.setStatus("已保存录屏") }
                        } else { self.handle(error ?? CaptureFailure.message("录屏未生成可保存的画面。")) }
                    }
                })
            }
        }
    }

    private func openEditor(_ image: CGImage, at region: CGRect) {
        let editor = CaptureEditor(image: image, selectionFrame: region)
        let expected = generation, revision = captureRevision
        editor.onCopied = { [weak self, weak editor] in
            guard let self, self.running, self.generation == expected,
                  self.captureRevision == revision, self.editor === editor else { return }
            self.copiedRegion = (NSPasteboard.general.changeCount, region)
        }
        editor.onExport = { [weak self, weak editor] in
            guard let self, self.running, self.generation == expected,
                  self.captureRevision == revision, self.editor === editor else { return }
            self.lastRegion = region
        }
        editor.onPin = { [weak self, weak editor] image in
            guard let self, self.running, self.generation == expected,
                  self.captureRevision == revision, self.editor === editor else { return }
            self.lastRegion = region
            self.pins.add(image, at: region) { [weak self, weak editor] shown in
                guard let self, self.running, self.generation == expected, self.captureRevision == revision,
                      let editor, self.editor === editor else { return }
                editor.close()
                if !shown { self.setStatus("贴图创建失败。") }
            }
        }
        editor.colorAtPointer = { [weak self] rgb in self?.selection.color(at: NSEvent.mouseLocation, rgb: rgb) }
        editor.onReselect = { [weak self, weak editor] in
            guard let self, let editor, self.editor === editor else { return }
            editor.onClose = nil; editor.close(); self.editor = nil
            self.selection.resume()
        }
        editor.onClose = { [weak self, weak editor] in
            guard let self, self.editor === editor else { return }
            self.editor = nil; self.captureInProgress = false; self.selection.dismiss()
        }
        self.editor = editor; editor.present()
        setStatus("Enter / ⌘C 复制")
    }
    private func handle(_ error: Error) {
        let error = CaptureFailure.screenCaptureError(error)
        if case CaptureFailure.permission = error { hasConfirmedScreenCaptureAccess = false }
        setStatus(error.localizedDescription)
        if case CaptureFailure.permission = error { onPermissionNeeded?() }
    }
    private func setStatus(_ value: String) {
        status.stringValue = value
        status.isHidden = ["未启用", "已就绪", "已停用", "录屏中", "已保存录屏"].contains(value)
        onStatusChange?(value)
    }
    private func screenDescriptors() -> [CaptureScreen] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return CaptureScreen(id: id, frame: screen.frame, scale: screen.backingScaleFactor)
        }
    }
    private func buildSettings() -> NSView {
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 600
        status.isHidden = ["未启用", "已就绪", "已停用", "录屏中", "已保存录屏"].contains(status.stringValue)
        let stack = NSStackView(views: [recordingPresentation.settingsView, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        return stack
    }
}
