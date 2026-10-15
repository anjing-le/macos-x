import AppKit
import Darwin
import MacOSXCore

private final class RadarFixtureReader: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var main = false
    let release = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
    func read(_ seed: RadarSnapshot) -> RadarSnapshot {
        lock.lock(); reads += 1; let count = reads; main = main || Thread.isMainThread; lock.unlock()
        if count == 1 { _ = release.wait(timeout: .now() + 3) }
        var value = seed
        value.uses = [.init(chord: .init(key: "F3", modifiers: 0), appID: "fixture", appName: "Fixture",
                            action: "result-\(count)", path: "Fixture", scope: .global, evidence: .registration)]
        return value
    }
}

extension ShortcutRadarDashboard {
    fileprivate var fixtureGroupCount: Int { groups.count }
    fileprivate var fixtureSelected: RadarGroup? { selected }
    fileprivate var fixtureCapturing: Bool { capturing }
    fileprivate var fixtureHasObservers: Bool { !observers.isEmpty }
    fileprivate func fixtureSearch(_ query: String) { search.stringValue = query; reload() }
    fileprivate func fixtureFilter(_ index: Int) { filters[index].performClick(nil) }
    fileprivate func fixtureScan() { scan.performClick(nil) }
    fileprivate func fixtureCapture() { capture.performClick(nil) }
    fileprivate func fixtureMove(_ delta: Int) { moveSelection(delta) }
}
extension ShortcutRadarModule {
    fileprivate var fixtureSnapshot: RadarSnapshot? { snapshot }
    fileprivate var fixtureBusy: Bool { busy }
}
private final class RadarFixtureSurface: SketchSurface { override var isFlipped: Bool { true } }

@main struct ShortcutRadarRegression {
    @MainActor private static var checks = 0
    @MainActor private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    @MainActor private static func wait(_ message: String, until condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 4
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > end { throw NSError(domain: message, code: 2) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor private static func layout(_ view: NSView, width: CGFloat) {
        view.frame = CGRect(x: 0, y: 0, width: width, height: 950)
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.frame.size.height = view.intrinsicContentSize.height
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func bounds(_ view: NSView) throws {
        for child in view.subviews where !child.isHidden {
            try require(child.frame.width > 0 && child.frame.height > 0, "visible control has nonempty bounds")
            try require(view.bounds.insetBy(dx: -1, dy: -1).contains(child.frame), "\(type(of: child)) \(child.frame) fits \(view.bounds)")
        }
    }
    @MainActor private static func fixtureUses() -> [RadarUse] {
        [RadarUse(chord: .init(key: "R", modifiers: 5), appID: "fixture-a", appName: "飞书（示例）", action: "录屏",
                  path: "示例菜单 › 录屏", scope: .application, evidence: .menu),
         RadarUse(chord: .init(key: "R", modifiers: 5), appID: "fixture-b", appName: "钉钉（示例）", action: "录屏",
                  path: "示例菜单 › 录屏", scope: .application, evidence: .menu),
         RadarUse(chord: .init(key: "←", modifiers: 10), appID: "fixture", appName: "macos-x", action: "左半屏",
                  path: "窗口布局 › 左半屏", scope: .global, evidence: .registration),
         RadarUse(chord: .init(key: "F3", modifiers: 0), appID: "fixture", appName: "macos-x", action: "贴图",
                  path: "截图录屏 › 贴图", scope: .global, evidence: .configuration)]
    }
    @MainActor static func main() async {
        do {
            _ = NSApplication.shared; NSApp.appearance = NSAppearance(named: .aqua)
            if let index = CommandLine.arguments.firstIndex(of: "--hold-probe"), CommandLine.arguments.count > index + 1 {
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(90, UInt32(controlKey | optionKey | shiftKey | cmdKey),
                    EventHotKeyID(signature: 0x72616472, id: 9), GetApplicationEventTarget(),
                    CommandLine.arguments.contains("--exclusive-holder") ? OptionBits(kEventHotKeyExclusive) : 0, &ref)
                guard status == noErr, let ref else { throw NSError(domain: "holder failed", code: Int(status)) }
                defer { UnregisterEventHotKey(ref) }
                try Data("ready".utf8).write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                try await Task.sleep(nanoseconds: 4_000_000_000)
                return
            }
            try dashboard()
            try await lifecycle()
            if CommandLine.arguments.contains("--probe-registration") { try await registration() }
            if CommandLine.arguments.contains("--live-seed") {
                let labels = RadarNativeSeed.keyLabels()
                let (entries, available) = RadarNativeSeed.systemUses(labels: labels)
                try require(labels[99] == "F3" && labels[123] == "←", "live key mapping preserves non-printing keys")
                print("Live seed: \(labels.count) keys, system available=\(available), \(entries.count) distinct system chords; no AX or input synthesis")
            }
            print("PASS shortcut radar: \(checks) checks; native search/filter/key capture/full-row selection, wide/narrow layout, bounded serial worker, cancel/stop/restart and stale-result rejection; no installed app, standard preferences, TCC changes or synthesized input")
        } catch { FileHandle.standardError.write(Data("FAIL shortcut radar: \(error)\n".utf8)); exit(1) }
    }
    @MainActor private static func dashboard() throws {
        let large = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            NSColor.blue.setFill(); CGRect(x: 0, y: 0, width: 1024, height: 1024).fill(); return true
        }
        let icon = RadarNativeSeed.thumbnail(large)
        let iconBitmap = icon?.representations.first as? NSBitmapImageRep
        try require(icon?.size == CGSize(width: 32, height: 32) && iconBitmap?.pixelsWide == 64 && iconBitmap?.pixelsHigh == 64,
                    "app icon cache retains only a small bounded bitmap")
        let view = ShortcutRadarDashboard(frame: .zero)
        let snapshot = RadarSnapshot(uses: fixtureUses(), totalApps: 2, accessibility: false)
        view.update(snapshot: snapshot, icons: [:], enabled: true, busy: false)
        try require(view.fixtureGroupCount == 3, "all real fixture sources form three groups")
        try require(view.fixtureSelected?.uses.count == 2 && view.fixtureSelected?.isPotentialConflict == false,
                    "two app-local commands remain contextual reuse")
        view.fixtureSearch("Control + Shift + R")
        try require(view.fixtureGroupCount == 1 && view.fixtureSelected?.uses.count == 2, "typed combo matches exact group")
        view.fixtureSearch("飞书")
        try require(view.fixtureSelected?.uses.count == 2, "app name search retains other uses of same chord")
        view.fixtureFilter(1)
        try require(view.fixtureGroupCount == 0, "global filter does not manufacture a global claim for local commands")
        view.fixtureFilter(0); view.fixtureSearch("no results")
        try require(view.fixtureSelected == nil, "no-results search clears stale selection")
        var probed = snapshot
        probed.probe = .init(chord: .init(key: "Z", modifiers: 15), result: .occupied)
        view.update(snapshot: probed, icons: [:], enabled: true, busy: false)
        view.fixtureSearch("⌃⌥⇧⌘Z")
        try require(view.fixtureGroupCount == 1 && view.fixtureSelected?.uses.isEmpty == true,
                    "unknown owner does not add a fabricated counted source")
        let unknown = RadarTableCell(frame: CGRect(x: 0, y: 0, width: 340, height: 80))
        unknown.group = view.fixtureSelected
        if let bitmap = unknown.bitmapImageRepForCachingDisplay(in: unknown.bounds) {
            unknown.cacheDisplay(in: unknown.bounds, to: bitmap)
            try require(bitmap.pixelsWide > 0, "zero known sources render without asking empty pencil paths for bounds")
        }
        SketchPencil.fibers(in: NSBezierPath())
        view.fixtureFilter(2)
        try require(view.fixtureGroupCount == 0, "unknown registration does not appear as an application-local command")
        view.fixtureFilter(0)
        view.update(snapshot: snapshot, icons: [:], enabled: true, busy: false)
        view.fixtureSearch("")
        let moduleSwitch = ModuleEnableButton(title: "功能", target: nil, action: nil)
        moduleSwitch.state = .on
        for width: CGFloat in [912, 650, 620, 359, 312, 220] { layout(view, width: width); try bounds(view) }
        layout(view, width: 912)
        try require(view.intrinsicContentSize.height + 56 + 48 <= 640, "default page fits shell and margins without an extra enable row")
        let tables = view.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }
        let scrolls = view.subviews.compactMap { $0 as? NSScrollView }
        try require(scrolls[0].contentSize.height >= (tables[0].rowHeight + 3) * 7,
                    "default page has room for seven complete combination rows")
        try require(scrolls[1].contentSize.height >= (tables[1].rowHeight + 3) * 6,
                    "default page has room for six complete application and action rows")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(kind)?.isHidden = true }
        let root = RadarFixtureSurface(frame: CGRect(x: 0, y: 0, width: 960, height: 640)); root.edge = nil
        window.contentView = root
        let header = SketchWindowHeader(frame: CGRect(x: 0, y: 0, width: 960, height: 56)); header.title = "快捷键雷达"; header.back.isHidden = false; header.accessory = moduleSwitch
        root.addSubview(header); root.addSubview(view); view.frame.origin = CGPoint(x: 24, y: 80)
        let note = NSTextField(labelWithString: "交互预览 · 示例数据"); note.font = .systemFont(ofSize: 11); note.textColor = SketchPalette.muted
        note.frame = CGRect(x: 540, y: 606, width: 280, height: 22); root.addSubview(note)
        root.layoutSubtreeIfNeeded()
        view.fixtureMove(1)
        try require(view.fixtureSelected?.chord != .init(key: "R", modifiers: 5), "arrow navigation changes selected group")
        view.fixtureSearch("")
        let table = view.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTableView }.first!
        table.layoutSubtreeIfNeeded()
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: table.convert(CGPoint(x: table.bounds.width - 10, y: 40), to: nil),
            modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        table.mouseDown(with: event)
        try require(table.selectedRow == 0 && view.fixtureSelected?.chord == .init(key: "R", modifiers: 5), "clicking row-edge whitespace selects that exact group")
        var recordingChanges: [Bool] = []
        view.onCaptureChanged = { recordingChanges.append($0) }
        view.fixtureCapture()
        try require(view.fixtureCapturing, "keyboard button enters focused capture")
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 2,
            windowNumber: window.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
        view.keyDown(with: key)
        try require(!view.fixtureCapturing && recordingChanges == [true, false], "capturing one combo restores shared input")
        view.fixtureCapture()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try require(!view.fixtureCapturing, "window blur restores input and ends recording")
        view.fixtureCapture(); view.removeFromSuperview()
        try require(!view.fixtureCapturing && !view.fixtureHasObservers && recordingChanges.suffix(2) == [true, false], "navigation ends capture and releases window observers")
        root.addSubview(view); view.frame.origin = CGPoint(x: 24, y: 80)
        view.fixtureSearch("")
        if let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.count > index + 1 {
            let out = URL(fileURLWithPath: CommandLine.arguments[index + 1]); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var dense = snapshot
            dense.accessibility = true
            let names = ["ChatGPT（示例）", "浏览器（示例）", "编辑器（示例）", "邮件（示例）", "终端（示例）", "笔记（示例）", "表格（示例）", "日历（示例）"]
            dense.uses = names.enumerated().map { index, name in
                RadarUse(chord: .init(key: "Z", modifiers: 12), appID: "sample-\(index)", appName: name,
                         action: "重做", path: "编辑 › 重做", scope: .application, evidence: .menu)
            }
            dense.uses += (1...14).map { index in
                RadarUse(chord: .init(key: "F\(index)", modifiers: 10), appID: "sample-key-\(index)", appName: "示例应用",
                         action: "示例命令 \(index)", path: "示例菜单", scope: .application, evidence: .menu)
            }
            view.update(snapshot: dense, icons: [:], enabled: true, busy: false)
            layout(view, width: 912); view.frame.origin = CGPoint(x: 24, y: 80)
            if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("shortcut-radar-wide.png"))
            }
            layout(view, width: 312)
            let narrow = RadarFixtureSurface(frame: view.bounds); narrow.edge = nil
            view.removeFromSuperview(); narrow.addSubview(view); view.frame.origin = .zero
            if let bitmap = narrow.bitmapImageRepForCachingDisplay(in: narrow.bounds) {
                narrow.cacheDisplay(in: narrow.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("shortcut-radar-narrow.png"))
            }
        }
        window.close()
    }
    @MainActor private static func lifecycle() async throws {
        let reader = RadarFixtureReader()
        let scanner = ShortcutRadarScanner(reader: { _, _, seed, _ in reader.read(seed) })
        let module = ShortcutRadarModule(scanner: scanner, configuration: { _ in [] }, captureChanged: { _ in }, requestPermission: {})
        let view = module.makeDashboard()
        module.start()
        try require(reader.count == 0, "enable/add has no idle scan")
        view.fixtureScan(); try await wait("worker starts") { reader.count == 1 }
        try require(module.fixtureBusy, "one explicit refresh is in flight")
        view.fixtureScan()
        try require(!module.fixtureBusy && module.fixtureSnapshot == nil, "cancel leaves no manufactured result")
        view.fixtureScan()
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(reader.count == 1, "a replacement scan stays serial while cancelled reader is still finishing")
        reader.release.signal()
        try await wait("new result arrives") { module.fixtureSnapshot?.uses.first?.action == "result-2" }
        try require(!reader.usedMainThread, "reader never runs on main thread")
        module.stop()
        try require(module.fixtureSnapshot == nil && !module.fixtureBusy, "disable releases cache and cancels scan")
        view.fixtureScan(); try require(reader.count == 2, "disabled view cannot scan")
        module.start(); try require(reader.count == 2, "restart still waits for explicit detection")
        view.fixtureScan(); module.stop()
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(module.fixtureSnapshot == nil, "late delivery cannot restore data after stop")
    }
    @MainActor private static func registration() async throws {
        let chord = RadarChord(key: "F20", modifiers: 15)
        let exclusive = try await probeWithHolder(exclusive: true)
        try require(exclusive.result == .occupied, "probe detects an independent exclusive registration")
        try require(exclusive.message.contains("未提供应用归属"), "probe does not invent an owner")
        let shared = try await probeWithHolder(exclusive: false)
        try require(shared.result == .notFound || shared.result == .occupied, "shared registration produces bounded, platform-specific probe evidence")
        let known = RadarNativeSeed.probe(chord, labels: [90: "F20"], known: [
            .init(chord: chord, appID: "known", appName: "Known", action: "Known", path: "Known", scope: .global, evidence: .registration)])
        try require(known.result == .known, "known own source is not falsely reported as unknown")
        print("Registration fixture: exclusive=\(exclusive.result), shared=\(shared.result); separate processes; no key events emitted; successful probe never claims unoccupied")
    }
    @MainActor private static func probeWithHolder(exclusive: Bool) async throws -> RadarProbe {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("radar-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--hold-probe", ready.path] + (exclusive ? ["--exclusive-holder"] : [])
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        try await wait("second-process hotkey holder") { FileManager.default.fileExists(atPath: ready.path) }
        return RadarNativeSeed.probe(.init(key: "F20", modifiers: 15), labels: [90: "F20"], known: [])
    }
}
