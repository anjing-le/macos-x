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
    private lazy var folderButton = MinimalButton(title: "", target: self, action: #selector(chooseFolder), style: .standard)
    private lazy var choose = MinimalButton(title: "选择文件夹", target: self, action: #selector(chooseFolder), style: .standard)
    private lazy var copy = MinimalButton(title: "复制路径", target: self, action: #selector(copyResult), style: .quiet)
    private lazy var play = MinimalButton(title: "播放", target: self, action: #selector(openResult), style: .standard)
    private lazy var reveal = MinimalButton(title: "Finder", target: self, action: #selector(revealResult), style: .quiet)
    private lazy var results = NSStackView(views: [resultLabel, NSStackView(views: [play, reveal, copy])])
    private lazy var settings: RecordingSettingsFooter = {
        recordingLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        resultLabel.font = .systemFont(ofSize: 12); resultLabel.textColor = .secondaryLabelColor
        resultLabel.lineBreakMode = .byTruncatingMiddle; resultLabel.maximumNumberOfLines = 1
        resultLabel.widthAnchor.constraint(lessThanOrEqualToConstant:220).isActive=true
        for button in [play,reveal,copy] { button.font = .systemFont(ofSize:12) }
        reveal.toolTip = "在 Finder 中显示"
        results.orientation = .vertical; results.alignment = .leading; results.spacing = 10
        let folderLabel = NSTextField(labelWithString: "保存位置")
        folderLabel.font = SketchPalette.heading(16); folderLabel.textColor = .secondaryLabelColor
        updateFolderButton()
        folderButton.cell?.lineBreakMode = .byTruncatingMiddle
        let folderRow = NSStackView(views: [folderLabel, folderButton, choose]); folderRow.spacing = 8
        return RecordingSettingsFooter(folder: folderRow, path: folderButton, choose: choose,
                                       clock: recordingLabel, results: results)
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
        folderButton.isEnabled = !busy; choose.isEnabled = !busy
        settings.invalidateIntrinsicContentSize(); settings.needsLayout = true
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

/// Native controls positioned over the illustration; no duplicate bitmap values.
@MainActor final class RecordingSettingsFooter: NSView {
    private let folderLabel: NSView, path: NSView, choose: NSView, clock: NSView, results: NSView
    private let recent = NSTextField(labelWithString: "最近录屏")
    private let empty = NSTextField(labelWithString: "录屏完成后在这里查看")
    private var wasCompact=false
    var usesArtwork=false { didSet { if oldValue != usesArtwork { needsLayout=true; invalidateIntrinsicContentSize() } } }
    override var isFlipped: Bool { true }
    private var compact: Bool { bounds.width < 700 }
    override var intrinsicContentSize: NSSize { NSSize(width:840,height:compact ? 142 : (usesArtwork ? 72 : 96)) }
    init(folder:NSView,path:NSView,choose:NSView,clock:NSView,results:NSView) {
        self.path=path; self.choose=choose; self.clock=clock; self.results=results
        folderLabel=(folder as? NSStackView)?.arrangedSubviews.first ?? NSTextField(labelWithString:"保存位置")
        super.init(frame:CGRect(x:0,y:0,width:840,height:96))
        recent.font=SketchPalette.heading(14); recent.textColor=SketchPalette.ink
        empty.font = .systemFont(ofSize:12); empty.textColor=SketchPalette.muted
        for view in [folderLabel,path,choose,clock,results,recent,empty] {
            if let parent=view.superview as? NSStackView { parent.removeArrangedSubview(view) }
            view.removeFromSuperview(); view.translatesAutoresizingMaskIntoConstraints=true; addSubview(view)
        }
    }
    required init?(coder:NSCoder) { nil }
    override func layout() {
        super.layout()
        if compact != wasCompact { wasCompact=compact; invalidateIntrinsicContentSize() }
        let illustrated=usesArtwork && !compact
        recent.isHidden=illustrated; folderLabel.isHidden=illustrated; choose.isHidden=compact
        for button in [path,choose].compactMap({ $0 as? MinimalButton }) {
            button.style=illustrated ? .quiet : .standard
            button.font=illustrated ? .systemFont(ofSize:14) : SketchPalette.heading(15)
        }
        if illustrated {
            path.frame=CGRect(x:bounds.width*0.12,y:8,width:bounds.width*0.286,height:36)
            choose.frame=CGRect(x:bounds.width*0.414,y:8,width:bounds.width*0.104,height:36)
            let x=bounds.width*0.67, width=bounds.width*0.31
            results.frame=CGRect(x:x,y:16,width:width,height:56)
            clock.frame=CGRect(x:x,y:16,width:width,height:26)
            empty.frame=CGRect(x:x,y:16,width:width,height:24)
        } else {
            let width=compact ? bounds.width : bounds.width/2-18
            folderLabel.frame=CGRect(x:0,y:6,width:72,height:28)
            path.frame=CGRect(x:80,y:4,width:max(110,width-(compact ? 80 : 170)),height:32)
            choose.frame=CGRect(x:width-84,y:4,width:84,height:32)
            let x:CGFloat=compact ? 0 : bounds.width/2+18, y:CGFloat=compact ? 48 : 0
            recent.frame=CGRect(x:x,y:y,width:width,height:22)
            results.frame=CGRect(x:x,y:y+26,width:width,height:64)
            clock.frame=CGRect(x:x,y:y+28,width:width,height:26)
            empty.frame=CGRect(x:x,y:y+28,width:width,height:24)
        }
        empty.isHidden = !results.isHidden || !clock.isHidden
        results.layoutSubtreeIfNeeded()
    }
    override func draw(_ dirtyRect:NSRect) {
        guard !compact && !usesArtwork else { return }
        let line=NSBezierPath(); line.move(to:CGPoint(x:bounds.midX,y:4)); line.line(to:CGPoint(x:bounds.midX,y:bounds.height-8))
        SketchPencil.stroke(line,color:SketchPalette.line.withAlphaComponent(0.4),width:0.8)
    }
}
