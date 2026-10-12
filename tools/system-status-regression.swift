import AppKit
import Darwin
import MacOSXCore

/// A deterministic reader whose counts are guarded across the sampling queue.
private final class StatusFixtureReader: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var active = 0
    private var peak = 0
    private var blocked = false
    let release = DispatchSemaphore(value: 0)
    let blocksFirst: Bool
    init(blocksFirst: Bool = false) { self.blocksFirst = blocksFirst }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var maximumConcurrentReads: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var enteredBlock: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    func read() -> SystemStatusRawReading {
        lock.lock()
        calls += 1; active += 1; peak = max(peak, active)
        let index = calls
        if blocksFirst && index == 1 { blocked = true }
        lock.unlock()
        if blocksFirst && index == 1 { _ = release.wait(timeout: .now() + 5) }
        defer { lock.lock(); active -= 1; lock.unlock() }
        return .init(timestamp: ProcessInfo.processInfo.systemUptime - 60 + Double(index),
                     cpu: .init(user: UInt32(index * 20), system: UInt32(index * 10), idle: UInt32(index * 70), nice: 0),
                     memory: .init(usedBytes: blocksFirst && index == 1 ? 111 : 222,
                                   totalBytes: 1_024, compressedBytes: 64, swapBytes: 0),
                     network: .init(interfaceName: "en-fixture", interfaceIndex: 7,
                                    receivedBytes: UInt64(index) * 10_000, sentBytes: UInt64(index) * 1_000),
                     issues: [])
    }
}

@MainActor private final class StatusFixturePaintMarker: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.red.setFill(); bounds.fill() }
}

// Same-file extensions inspect actual retained production state. Lifecycle
// assertions below also observe reader invocations, delivered values and UI.
extension SystemStatusModule {
    fileprivate var fixtureHistory: [SystemStatusSnapshot] { history }
    fileprivate var fixtureLatest: SystemStatusSnapshot? { latest }
    fileprivate func fixtureOpenDashboard() { openDashboard() }
}

@main struct SystemStatusRegression {
    @MainActor private static var checks = 0
    @MainActor private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw NSError(domain: message, code: 1) }
    }
    @MainActor private static func wait(_ message: String, timeout: TimeInterval = 3,
                                       until condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= end { throw NSError(domain: "timeout: " + message, code: 2) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    @MainActor private static func settle(_ seconds: Double = 0.16) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    @MainActor private static func stallFixtureMainQueue(_ reader: StatusFixtureReader) {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while reader.count < 12 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
    @MainActor private static func labels(_ view: NSView) -> [String] {
        descendants(view).compactMap { ($0 as? NSTextField)?.stringValue }
    }
    @MainActor private static func layout(_ view: NSView, width: CGFloat) {
        view.frame = CGRect(x: 0, y: 0, width: width, height: max(1, view.intrinsicContentSize.height))
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
        view.frame.size.height = view.intrinsicContentSize.height
        view.needsLayout = true; view.layoutSubtreeIfNeeded()
    }
    @MainActor private static func assertBounds(_ view: NSView, name: String) throws {
        for child in view.subviews where !child.isHidden {
            let frame = child.frame
            try require([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), "\(name) has finite child coordinates")
            try require(frame.width > 0 && frame.height > 0, "\(name) has nonempty visible children")
            try require(frame.minX >= -0.5 && frame.minY >= -0.5 && frame.maxX <= view.bounds.maxX + 0.5 && frame.maxY <= view.bounds.maxY + 0.5,
                        "\(name) keeps \(type(of: child)) \(frame) inside \(view.bounds)")
            try assertBounds(child, name: name + "/" + String(describing: type(of: child)))
        }
    }

    @MainActor static func main() async {
        do {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: .aqua)
            try await samplerLifecycle()
            try await moduleLifecycle()
            try dashboard()
            print("PASS system status: \(checks) assertions; actual serial timer/read/delivery, stop/restart/sleep generations, bounded retained history, offscreen wide/narrow/missing/disabled graphs; no real menu item, installed app, standard preferences, clipboard, capture, AX or TCC")
            if CommandLine.arguments.contains("--live-sample") { try await liveSample() }
        } catch {
            FileHandle.standardError.write(Data("FAIL system status: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func samplerLifecycle() async throws {
        let reader = StatusFixtureReader()
        let notifications = NotificationCenter()
        let sampler = SystemStatusSampler(interval: 0.05, read: { reader.read() }, notificationCenter: notifications)
        var updates: [SystemStatusSnapshot] = []
        sampler.onUpdate = { updates.append($0) }
        sampler.start(); sampler.start()
        try await wait("first timer readings") { updates.count >= 3 }
        try require(updates.first?.cpuPercent == nil && updates.first?.network?.downloadBytesPerSecond == nil,
                    "first CPU/network sample establishes a baseline without fake zero or spike")
        try require(updates.dropFirst().allSatisfy { $0.cpuPercent == 30 && ($0.network?.downloadBytesPerSecond ?? 0) > 0 },
                    "subsequent actual reader deliveries derive CPU and throughput")
        try require(reader.maximumConcurrentReads == 1, "sampling is serial even with repeated start")
        let before = reader.count, beforeTime = ProcessInfo.processInfo.systemUptime
        try await settle(0.21)
        let elapsed = ProcessInfo.processInfo.systemUptime - beforeTime
        try require(reader.count - before <= Int(ceil(elapsed / 0.05)) + 2,
                    "start is idempotent: one 50 ms timer, not duplicate sampling")

        notifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await settle(0.02)
        let sleepReads = reader.count, sleepUpdates = updates.count
        try await settle()
        try require(reader.count == sleepReads && updates.count == sleepUpdates, "sleep cancels timer readings and pending callback deliveries")
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await wait("wake establishes fresh baseline") { updates.count > sleepUpdates }
        let resumed = updates[sleepUpdates]
        try require(resumed.cpuPercent == nil && resumed.network?.downloadBytesPerSecond == nil,
                    "wake creates a new accumulator rather than averaging across sleep")
        sampler.stop(); sampler.stop()
        try await settle(0.02)
        let stoppedReads = reader.count, stoppedUpdates = updates.count
        notifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle()
        try require(reader.count == stoppedReads && updates.count == stoppedUpdates, "stopped module ignores wake and performs no reader or delivery work")
        sampler.start()
        try await wait("restart baseline") { updates.count > stoppedUpdates }
        try require(updates[stoppedUpdates].cpuPercent == nil, "restart does not retain CPU baseline")
        sampler.stop()

        let blocked = StatusFixtureReader(blocksFirst: true)
        let late = SystemStatusSampler(interval: 0.05, read: { blocked.read() }, notificationCenter: NotificationCenter())
        var lateUpdates: [SystemStatusSnapshot] = []
        late.onUpdate = { lateUpdates.append($0) }
        late.start()
        try await wait("blocked old read") { blocked.enteredBlock }
        late.stop(); late.start()
        blocked.release.signal()
        try await wait("replacement read delivered") { !lateUpdates.isEmpty }
        try require(lateUpdates.allSatisfy { $0.memory?.usedBytes == 222 }, "released old blocked reader cannot deliver its stale 111 byte snapshot after restart")
        try require(lateUpdates.first?.cpuPercent == nil && lateUpdates.first?.network?.downloadBytesPerSecond == nil,
                    "old blocked generation does not contaminate replacement baseline")
        try require(blocked.maximumConcurrentReads == 1, "stop/restart retains one serial queue, never overlapping blocked reads")
        late.stop()

        let busyReader = StatusFixtureReader()
        let busy = SystemStatusSampler(interval: 0.005, read: { busyReader.read() }, notificationCenter: NotificationCenter())
        var coalesced: [SystemStatusSnapshot] = []
        busy.onUpdate = { snapshot in
            coalesced.append(snapshot)
            if coalesced.count == 2 { busy.stop() }
        }
        busy.start()
        try await wait("coalescing first delivery") { coalesced.count == 1 }
        // Deliberately stall only the isolated fixture's main queue. Production
        // continues serial sampling and should enqueue one latest-value delivery.
        stallFixtureMainQueue(busyReader)
        try await wait("latest delivery after main queue stall") { coalesced.count == 2 }
        try require(busyReader.count >= 10 && coalesced[1].timestamp - coalesced[0].timestamp > 8,
                    "busy main queue receives latest reading rather than replaying every old timer sample")
        try await settle(0.03)
        try require(coalesced.count == 2, "stop from callback discards queued deliveries")

        let releasedReader = StatusFixtureReader()
        let releasedCenter = NotificationCenter()
        var released: SystemStatusSampler? = SystemStatusSampler(interval: 0.01, read: { releasedReader.read() }, notificationCenter: releasedCenter)
        weak var weakSampler = released
        released?.start()
        try await wait("deinit sampler first read") { releasedReader.count > 0 }
        released = nil
        try await settle(0.02)
        let releasedReads = releasedReader.count
        releasedCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        releasedCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await settle(0.05)
        try require(weakSampler == nil && releasedReader.count == releasedReads,
                    "dropping module sampler releases timer and observers without retaining self or resuming reads")
    }

    @MainActor private static func moduleLifecycle() async throws {
        let reader = StatusFixtureReader()
        let sampler = SystemStatusSampler(interval: 0.01, read: { reader.read() }, notificationCenter: NotificationCenter())
        var itemCreations = 0, opened = 0
        let module = SystemStatusModule(sampler: sampler, makeStatusItem: { itemCreations += 1; return nil })
        module.onOpenDashboard = { opened += 1 }
        let stoppedPage = module.makeDashboard()
        try require(labels(stoppedPage).contains("已关闭 · 开启后开始监控"), "module detail is an explicit disabled monitoring dashboard")
        module.fixtureOpenDashboard()
        try require(opened == 0, "disabled monitoring entry does not open an inactive page")
        module.start(); module.start()
        try require(itemCreations == 1, "module restart is idempotent without creating real status items")
        module.fixtureOpenDashboard()
        try require(opened == 1, "monitoring entry invokes dashboard navigation directly")
        try await wait("more than 31 real timer readings") { reader.count >= 38 && module.fixtureHistory.count == 31 }
        try require(module.fixtureHistory.count == 31 && module.fixtureHistory.allSatisfy { ($0.timestamp - (module.fixtureLatest?.timestamp ?? 0)) >= -60 },
                    "module retains at most 31 samples within one minute")
        let activePage = module.makeDashboard()
        try require(labels(activePage).contains("正在监控") && labels(activePage).contains("30%"), "new monitoring page receives the latest sampled values immediately")
        module.stop()
        try require(module.fixtureHistory.isEmpty && module.fixtureLatest == nil && module.issue == nil, "stop releases latest/history/issues")
        try require(labels(activePage).contains("已关闭 · 开启后开始监控") && !labels(activePage).contains("30%"),
                    "stop updates an existing detached page and clears live values")
        let afterStopReads = reader.count
        try await settle(0.05)
        try require(reader.count == afterStopReads, "stopped module owns no continuing background reads")
        module.start()
        let reopenedPage = module.makeDashboard()
        try require(labels(reopenedPage).contains("等待首次采样"), "re-enabling does not redisplay the previous session's cached values")
        try await wait("module restarts sampling") { module.fixtureLatest != nil }
        try require(module.fixtureHistory.count <= 2 && module.fixtureHistory.first?.cpuPercent == nil, "re-enable starts a short new history with a fresh baseline")
        module.stop()
    }

    @MainActor private static func dashboard() throws {
        let end = ProcessInfo.processInfo.systemUptime
        let history: [SystemStatusSnapshot] = (0..<100).map { index in
            let step = Double(index)
            let cpu = 22.0 + 18.0 * sin(step / 5.0)
            let used: UInt64 = 8_200_000_000 + UInt64(index) * 10_000_000
            let memory = SystemMemoryStatus(usedBytes: used, totalBytes: 17_179_869_184, compressedBytes: 540_000_000, swapBytes: 0)
            let download = 850_000.0 + 240_000.0 * sin(step / 4.0)
            let upload = 35_000.0 + 15_000.0 * cos(step / 7.0)
            let network = SystemNetworkStatus(interfaceName: "en0", downloadBytesPerSecond: download, uploadBytesPerSecond: upload)
            return SystemStatusSnapshot(timestamp: end - Double(99 - index) * 2.0, cpuPercent: cpu, memory: memory, network: network)
        }
        let view = SystemStatusDashboardView(frame: .zero)
        view.update(snapshot: history.last, history: history, isEnabled: true)
        let output = ProcessInfo.processInfo.environment["MACOSX_SYSTEM_STATUS_PREVIEW"]
        if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
        for width: CGFloat in [912, 312] {
            layout(view, width: width)
            try assertBounds(view, name: "dashboard \(Int(width))")
            let charts = descendants(view).compactMap { $0 as? SystemStatusHistoryChart }
            try require(charts.count == 3, "dashboard exposes three native metric charts")
            try require(charts.allSatisfy { ($0.accessibilityLabel() ?? "").contains("最多 31 个采样点") },
                        "UI histories also cap at 31 samples for oversized input")
            let fields = descendants(view).compactMap { $0 as? NSTextField }
            try require(fields.allSatisfy { !$0.isEditable }, "monitoring page shows live values rather than configuration inputs")
            if let output { try render(view, to: URL(fileURLWithPath: output).appendingPathComponent("system-status-fixture-\(Int(width)).png")) }
        }
        view.update(snapshot: nil, history: history, isEnabled: true)
        try require(labels(view).contains("等待首次采样") && labels(view).contains("建立采样基线") == false,
                    "initial waiting state is clear and does not invent stale measurements")
        var missing = SystemStatusSnapshot(timestamp: end, cpuPercent: nil, memory: nil, network: nil,
                                           issues: ["测试：CPU 读取失败", "测试：内存读取失败", "测试：接口读取失败"])
        view.update(snapshot: missing, history: history, isEnabled: true)
        try require(labels(view).contains("部分数据暂不可用") && labels(view).contains("CPU 暂不可用") && labels(view).contains("内存数据暂不可用") && labels(view).contains("网络数据暂不可用"),
                    "partial failures expose missing metrics explicitly")
        layout(view, width: 312); try assertBounds(view, name: "missing-data narrow")
        try memoryHistoryRendering(end: end, output: output)
        view.update(snapshot: missing, history: history, isEnabled: false)
        try require(labels(view).contains("已关闭 · 开启后开始监控") && labels(view).filter { $0 == "—" }.count == 3,
                    "disabled dashboard clears all three values")
        missing.cpuPercent = .nan
        missing.timestamp = .nan
        missing.network = .init(interfaceName: String(repeating: "very-long-physical-interface-", count: 8),
                                downloadBytesPerSecond: .infinity, uploadBytesPerSecond: -.infinity)
        view.update(snapshot: missing, history: history + [missing], isEnabled: true)
        layout(view, width: 312); try assertBounds(view, name: "nonfinite-data narrow")
        try require(labels(view).contains("更新时间不可用"), "nonfinite timestamps are not passed into DateFormatter")
        let details = descendants(view).compactMap { $0 as? NSTextField }.filter { $0.stringValue.hasPrefix("接口 ") }
        try require(details.count == 1 && details[0].lineBreakMode == .byTruncatingTail && details[0].toolTip == details[0].stringValue,
                    "long interface names truncate within the card and keep complete tooltip")
        missing.timestamp = end
        missing.cpuPercent = .infinity
        missing.network?.downloadBytesPerSecond = .greatestFiniteMagnitude
        missing.network?.uploadBytesPerSecond = .nan
        view.update(snapshot: missing, history: [missing], isEnabled: true)
        layout(view, width: 912)
        try require(!labels(view).contains { $0.range(of: #"(?:^|\s)(?:nan|[+-]?inf)(?:\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil },
                    "overflow and NaN are not printed as native metric labels")
        let charts = descendants(view).compactMap { $0 as? SystemStatusHistoryChart }
        try require(charts.allSatisfy { ($0.accessibilityLabel() ?? "").range(of: #"(?:^|\s)(?:nan|[+-]?inf)(?:\s|，|$)"#, options: [.regularExpression, .caseInsensitive]) == nil },
                    "network scale multiplication overflow does not print an infinite graph axis")
        // Render adversarial inputs too: AppKit must survive finite extreme
        // rates, NaN timestamps and sparse/missing points without path crashes.
        try render(view, to: output.map { URL(fileURLWithPath: $0).appendingPathComponent("system-status-fixture-extreme.png") })
    }

    @MainActor private static func memoryHistoryRendering(end: TimeInterval, output: String?) throws {
        let capacity: UInt64 = 17_179_869_184
        let memory = SystemMemoryStatus(usedBytes: capacity / 2, totalBytes: capacity, compressedBytes: 0, swapBytes: 0)
        // A stable half-full trace with a missing interval and a missing latest
        // reading. The prior capacity remains authoritative for the chart axis.
        let history: [SystemStatusSnapshot] = (0...30).map { index in
            let unavailable = (15...17).contains(index) || index == 30
            return .init(timestamp: end - Double(30 - index) * 2, cpuPercent: nil,
                         memory: unavailable ? nil : memory, network: nil)
        }
        let card = SystemStatusMetricCard(kind: .memory)
        card.frame = CGRect(x: 0, y: 0, width: 288, height: 344)
        card.update(snapshot: history.last, history: history, isEnabled: true)
        card.needsLayout = true; card.layoutSubtreeIfNeeded()
        guard let chart = card.subviews.compactMap({ $0 as? SystemStatusHistoryChart }).first,
              let bitmap = chart.bitmapImageRepForCachingDisplay(in: chart.bounds) else {
            throw NSError(domain: "memory history bitmap", code: 4)
        }
        chart.cacheDisplay(in: chart.bounds, to: bitmap)
        try require((chart.accessibilityLabel() ?? "").contains("最大刻度 16.0 GB"),
                    "missing latest memory retains the prior physical capacity axis, never 100%")
        try require(labels(card).contains("内存数据暂不可用") && labels(card).contains("—"),
                    "historical chart never invents a current memory reading")
        let sx = Double(bitmap.pixelsWide) / chart.bounds.width
        let sy = Double(bitmap.pixelsHigh) / chart.bounds.height
        func purplePixels(_ rect: CGRect) -> Int {
            let minX = max(0, Int(rect.minX * sx)), maxX = min(bitmap.pixelsWide, Int(rect.maxX * sx))
            let minY = max(0, Int(rect.minY * sy)), maxY = min(bitmap.pixelsHigh, Int(rect.maxY * sy))
            var count = 0
            for y in minY..<maxY { for x in minX..<maxX {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.1 && color.blueComponent - color.redComponent > 0.05 && color.blueComponent - color.greenComponent > 0.12 {
                    count += 1
                }
            } }
            return count
        }
        let middle = CGRect(x: 28, y: chart.bounds.midY - 5, width: chart.bounds.width - 40, height: 10)
        try require(purplePixels(middle) > 80,
                    "actual memory history pixels remain near half of 16 GB instead of pinning to the top of an invalid 100-byte axis")
        let gapX = 16 + (chart.bounds.width - 17) * 0.54
        let gap = CGRect(x: gapX - 2, y: 18, width: 4, height: chart.bounds.height - 36)
        try require(purplePixels(gap) == 0, "actual history pixels leave missing memory samples disconnected")
        if let output, let data = bitmap.representation(using: .png, properties: [:]) {
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("system-status-fixture-memory-gap.png"))
        }
    }

    @MainActor private static func render(_ view: NSView, to url: URL?) throws {
        let canvas = SketchSurface(frame: CGRect(x: 0, y: 0, width: view.bounds.width + 32, height: view.bounds.height + 62))
        let title = NSTextField(labelWithString: "系统状态 · 回归示例数据")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.frame = CGRect(x: 18, y: canvas.bounds.height - 31, width: canvas.bounds.width - 36, height: 21)
        canvas.addSubview(title)
        let marker = StatusFixturePaintMarker(frame: CGRect(x: canvas.bounds.width - 57, y: canvas.bounds.height - 38, width: 38, height: 22))
        canvas.addSubview(marker)
        guard let before = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw NSError(domain: "fixture parent bitmap", code: 3) }
        canvas.cacheDisplay(in: canvas.bounds, to: before)
        view.frame.origin = CGPoint(x: 16, y: 16)
        canvas.addSubview(view)
        defer { view.removeFromSuperview(); view.frame.origin = .zero }
        guard let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { throw NSError(domain: "fixture bitmap", code: 3) }
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        try require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "offscreen native rendering creates actual pixels")
        try assertParentPaint(before: before, after: bitmap, canvas: canvas)
        // The saturated marker is only an adversarial paint check. Keep the
        // actual native title in saved previews and remove the test marker.
        marker.removeFromSuperview()
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        if let url, let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: url) }
    }

    @MainActor private static func assertParentPaint(before: NSBitmapImageRep, after: NSBitmapImageRep, canvas: NSView) throws {
        try require(before.pixelsWide == after.pixelsWide && before.pixelsHigh == after.pixelsHigh && before.bytesPerRow == after.bytesPerRow && before.bitsPerPixel == after.bitsPerPixel && !before.isPlanar,
                    "parent paint comparison uses matching actual pixel buffers")
        let sx = Double(before.pixelsWide) / canvas.bounds.width
        let sy = Double(before.pixelsHigh) / canvas.bounds.height
        let minX = max(0, Int((canvas.bounds.width - 57) * sx))
        let maxX = min(before.pixelsWide, Int((canvas.bounds.width - 19) * sx))
        var redRows: [Int] = []
        var redPixels = 0
        // Locate the opaque marker in either bitmap row orientation instead of
        // assuming AppKit's flipped view and bitmap coordinates are identical.
        let scan = Int(45 * sy)
        let rows = Array(0..<min(scan, before.pixelsHigh)) + Array(max(0, before.pixelsHigh - scan)..<before.pixelsHigh)
        for y in rows {
            var found = false
            for x in minX..<maxX {
                guard let color = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > 0.8 && color.greenComponent < 0.2 && color.blueComponent < 0.2 && color.alphaComponent > 0.9 {
                    redPixels += 1; found = true
                }
            }
            if found { redRows.append(y) }
        }
        try require(redPixels > 100 && !redRows.isEmpty, "parent-only header marker produces opaque colored pixels before child rendering")
        guard let a = before.bitmapData, let b = after.bitmapData, let first = redRows.min(), let last = redRows.max() else {
            throw NSError(domain: "fixture parent pixels", code: 5)
        }
        let padding = Int(6 * sy)
        let y0 = max(0, first - padding), y1 = min(before.pixelsHigh, last + padding + 1)
        let visibleBytes = before.pixelsWide * before.bitsPerPixel / 8
        let preserved = (y0..<y1).allSatisfy { y in
            memcmp(a.advanced(by: y * before.bytesPerRow), b.advanced(by: y * after.bytesPerRow), visibleBytes) == 0
        }
        try require(preserved,
                    "actual parent header/title/background pixels outside dashboard bounds remain byte-identical after child draw")
    }

    @MainActor private static func liveSample() async throws {
        func cpuTime() -> Double {
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let queue = DispatchQueue(label: "cc.anjing.macos-x.system-status.live-fixture", qos: .utility)
        let worker = SystemStatusWorker(read: nil)
        let start = ProcessInfo.processInfo.systemUptime, initialCPU = cpuTime()
        var samples: [SystemStatusSnapshot] = [], readTimes: [Double] = []
        for index in 0..<10 {
            if index > 0 { try await settle(2) }
            let value: (SystemStatusSnapshot?, Double) = await withCheckedContinuation { continuation in
                queue.async {
                    let before = ProcessInfo.processInfo.systemUptime
                    _ = worker.collectForDelivery()
                    continuation.resume(returning: (worker.consumeLatest(), ProcessInfo.processInfo.systemUptime - before))
                }
            }
            if let snapshot = value.0 { samples.append(snapshot) }
            readTimes.append(value.1)
        }
        worker.cancel()
        let elapsed = ProcessInfo.processInfo.systemUptime - start, consumedCPU = cpuTime() - initialCPU
        try require(samples.count == 10 && samples.allSatisfy { $0.memory?.totalBytes ?? 0 > 0 }, "opt-in native reader returns actual physical memory across ten samples")
        try require(samples.dropFirst().allSatisfy { $0.cpuPercent.map { $0.isFinite && (0...100).contains($0) } ?? false }, "opt-in native CPU samples produce valid percentages after baseline")
        let evidence: [String: Any] = ["mode": "opt-in read-only ten native samples; isolated fixture process",
                                       "samples": samples.count, "elapsedSeconds": elapsed,
                                       "processCPUSeconds": consumedCPU, "processCPUPercentOfOneCore": consumedCPU / elapsed * 100,
                                       "meanReadMilliseconds": readTimes.reduce(0, +) / Double(readTimes.count) * 1_000,
                                       "maxReadMilliseconds": (readTimes.max() ?? 0) * 1_000,
                                       "networkRateSamples": samples.filter { $0.network?.downloadBytesPerSecond != nil }.count,
                                       "lastMemoryUsedBytes": samples.last?.memory?.usedBytes ?? 0,
                                       "lastMemoryTotalBytes": samples.last?.memory?.totalBytes ?? 0,
                                       "lastIssues": samples.last?.issues ?? []]
        let json = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        print("LIVE system status: " + String(decoding: json, as: UTF8.self))
    }
}
