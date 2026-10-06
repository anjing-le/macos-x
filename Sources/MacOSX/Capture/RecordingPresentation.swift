import AppKit
@preconcurrency import AVFoundation
import MacOSXCore

/// One active-recording clock, no idle polling, one retained result URL.
@MainActor final class RecordingPresentation: NSObject {
    var onStop: (() -> Void)?
    private let defaults: UserDefaults
    private var item: NSStatusItem?
    private var timer: Timer?
    private var dismissWork: DispatchWorkItem?
    private var metadataTask: Task<Void, Never>?
    private var clock = RecordingClock()
    private var busy = false
    private var active = true
    private var recoveryEpoch: UInt64 = 0
    private var recoveryPending = false
    private var latest: URL?
    private let recordingLabel = NSTextField(labelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")
    private lazy var folderButton = MinimalButton(title: "", target: self, action: #selector(chooseFolder), style: .quiet)
    private lazy var copy = MinimalButton(title: "复制路径", target: self, action: #selector(copyResult), style: .quiet)
    private lazy var play = MinimalButton(title: "播放", target: self, action: #selector(openResult), style: .standard)
    private lazy var reveal = MinimalButton(title: "在 Finder 中显示", target: self, action: #selector(revealResult), style: .quiet)
    private lazy var results = NSStackView(views: [resultLabel, NSStackView(views: [play, reveal, copy])])
    private lazy var settings: NSStackView = {
        recordingLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        resultLabel.font = .systemFont(ofSize: 14); resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingMiddle; resultLabel.maximumNumberOfLines = 1
        results.orientation = .vertical; results.alignment = .leading; results.spacing = 10
        let folderLabel = NSTextField(labelWithString: "保存到")
        folderLabel.font = SketchPalette.heading(16); folderLabel.textColor = .secondaryLabelColor
        updateFolderButton()
        let folderRow = NSStackView(views: [folderLabel, folderButton]); folderRow.spacing = 8
        let stack = NSStackView(views: [folderRow, recordingLabel, results])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        return stack
    }()
    var settingsView: NSView { _ = settings; refreshVisibility(); return settings }
    var recordingDirectory: URL {
        if let path = defaults.string(forKey: "recording.directory-path") { return URL(fileURLWithPath: path, isDirectory: true) }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies", isDirectory: true)
        return movies.appendingPathComponent("macos-x", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        recoverLastResult()
    }

    private func recoverLastResult() {
        guard !recoveryPending else { return }
        recoveryPending = true
        let expected = recoveryEpoch
        let savedPath = defaults.string(forKey: "recording.latest-path")
        // Read only our recording folder, once, with a bounded legacy fallback.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?
                .appendingPathComponent("macos-x", isDirectory: true)
            var candidate = savedPath.map { URL(fileURLWithPath: $0) }
            if candidate.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                candidate = nil
                if let folder, let files = FileManager.default.enumerator(at: folder,
                    includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                    var newest = Date.distantPast
                    for case let url as URL in files.prefix(128) where url.pathExtension == "mp4" {
                        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                        if date > newest { candidate = url; newest = date }
                    }
                }
            }
            let recovered = candidate
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recoveryEpoch == expected else { return }
                self.recoveryPending = false
                guard self.active, self.latest == nil, let recovered else { return }
                self.setResult(recovered)
            }
        }
    }

    deinit { timer?.invalidate(); dismissWork?.cancel(); metadataTask?.cancel() }

    func resume() {
        active = true
        if let latest { if metadataTask == nil { setResult(latest) } }
        else { recoverLastResult() }
    }

    func began() {
        clearIndicator(); busy = true
        clock.begin(at: ProcessInfo.processInfo.systemUptime)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        let stop = NSMenuItem(title: "结束录制", action: #selector(stopPressed), keyEquivalent: "")
        stop.target = self; menu.addItem(stop); item?.menu = menu
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2; RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refreshVisibility()
    }

    func saving() {
        clock.stop(at: ProcessInfo.processInfo.systemUptime)
        timer?.invalidate(); timer = nil
        if busy { item?.button?.title = "保存中…"; item?.menu = nil }
    }

    func completed(_ url: URL?, announce: Bool) {
        clock.stop(at: ProcessInfo.processInfo.systemUptime)
        clearIndicator(); busy = false
        if let url { setResult(url, readDuration: announce); copyResult() }
        refreshVisibility()
        guard announce, url != nil else { return }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item?.button?.title = "✓ 已复制路径"
        let menu = NSMenu()
        for (title, action) in [("播放", #selector(openResult)), ("在 Finder 中显示", #selector(revealResult)), ("复制路径", #selector(copyResult))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; menu.addItem(entry)
        }
        item?.menu = menu
        let work = DispatchWorkItem { [weak self] in self?.clearIndicator() }
        dismissWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    func dismiss() {
        active = false; recoveryEpoch &+= 1; recoveryPending = false
        metadataTask?.cancel(); metadataTask = nil
        clearIndicator(); busy = false; refreshVisibility()
    }

    private func tick() {
        let elapsed = RecordingClock.display(clock.elapsed(at: ProcessInfo.processInfo.systemUptime))
        recordingLabel.stringValue = "●  \(elapsed)"
        let title = NSMutableAttributedString(string: "●  \(elapsed)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        title.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 1))
        item?.button?.attributedTitle = title; item?.button?.toolTip = "正在录屏 · 点击结束录制"
    }

    private func setResult(_ url: URL, readDuration: Bool = true) {
        latest = url; defaults.set(url.path, forKey: "recording.latest-path")
        resultLabel.stringValue = url.lastPathComponent; resultLabel.toolTip = url.path
        metadataTask?.cancel(); metadataTask = nil
        refreshVisibility()
        guard readDuration, active else { return }
        metadataTask = Task { [weak self] in
            let duration = try? await AVURLAsset(url: url).load(.duration)
            guard !Task.isCancelled, let self, self.latest == url, let duration,
                  CMTimeGetSeconds(duration).isFinite else { return }
            self.resultLabel.stringValue = "\(RecordingClock.display(CMTimeGetSeconds(duration))) · \(url.lastPathComponent)"
        }
        refreshVisibility()
    }
    private func refreshVisibility() {
        recordingLabel.isHidden = !busy; results.isHidden = busy || latest == nil
        folderButton.isEnabled = !busy
    }
    private func clearIndicator() {
        timer?.invalidate(); timer = nil; dismissWork?.cancel(); dismissWork = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }; item = nil
    }
    @objc private func stopPressed() { onStop?() }
    @objc private func openResult() { if let latest { _ = NSWorkspace.shared.open(latest) } }
    @objc private func revealResult() { if let latest { NSWorkspace.shared.activateFileViewerSelecting([latest]) } }
    @objc private func copyResult() {
        guard let latest else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest.path, forType: .string)
    }
    private func updateFolderButton() {
        let folder = recordingDirectory
        folderButton.title = "\(folder.deletingLastPathComponent().lastPathComponent)/\(folder.lastPathComponent) ›"
        folderButton.toolTip = folder.path; folderButton.setAccessibilityLabel("更改录屏保存目录，\(folder.path)")
        folderButton.invalidateIntrinsicContentSize()
    }
    @objc private func chooseFolder() {
        guard let window = settings.window, !busy, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.directoryURL = recordingDirectory; panel.prompt = "选择"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.defaults.set(url.path, forKey: "recording.directory-path"); self.updateFolderButton()
        }
    }
}
