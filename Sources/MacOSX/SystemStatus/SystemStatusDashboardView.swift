import AppKit
import MacOSXCore

/// Live values are supplied by the module. The view owns no sampler, observer or timer.
@MainActor
final class SystemStatusDashboardView: NSView {
    private let activity = NSTextField(labelWithString: "等待首次采样")
    private let updated = NSTextField(labelWithString: "")
    private let footnote = NSTextField(labelWithString: "每 2 秒刷新 · 最近 1 分钟 · 本机读取")
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let cpu = SystemStatusMetricCard(kind: .cpu)
    private let memory = SystemStatusMetricCard(kind: .memory)
    private let network = SystemStatusMetricCard(kind: .network)
    private let timeFormatter = DateFormatter()
    private var isEnabled = false
    private var measuredHeight: CGFloat = 436
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { CGSize(width: 840, height: measuredHeight) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        activity.font = .systemFont(ofSize: 13, weight: .medium)
        activity.textColor = SketchPalette.muted
        updated.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        updated.textColor = SketchPalette.muted
        updated.alignment = .right
        timeFormatter.dateFormat = "HH:mm:ss"
        footnote.font = .systemFont(ofSize: 12)
        footnote.textColor = SketchPalette.muted
        issue.font = .systemFont(ofSize: 12)
        issue.textColor = SketchPalette.ink
        issue.maximumNumberOfLines = 2
        issue.lineBreakMode = .byTruncatingTail
        for view in [activity, updated, footnote, issue, cpu, memory, network] { addSubview(view) }
        update(snapshot: nil, history: [], isEnabled: false)
    }
    required init?(coder: NSCoder) { nil }

    func update(snapshot: SystemStatusSnapshot?, history: [SystemStatusSnapshot], isEnabled: Bool) {
        self.isEnabled = isEnabled
        footnote.stringValue = isEnabled ? "每 2 秒刷新 · 最近 1 分钟 · 本机读取" : "开启后每 2 秒刷新 · 曲线保留 1 分钟"
        let latest = isEnabled ? snapshot : nil
        let points: [SystemStatusSnapshot]
        if let time = latest?.timestamp, time.isFinite {
            points = Array(history.suffix(31)).filter {
                $0.timestamp.isFinite && $0.timestamp >= time - 60 && $0.timestamp <= time
            }.sorted { $0.timestamp < $1.timestamp }
        } else { points = [] }
        cpu.update(snapshot: latest, history: points, isEnabled: isEnabled)
        memory.update(snapshot: latest, history: points, isEnabled: isEnabled)
        network.update(snapshot: latest, history: points, isEnabled: isEnabled)
        if !isEnabled {
            activity.stringValue = "已关闭 · 开启后开始监控"
            updated.stringValue = ""
            issue.stringValue = ""
        } else if let latest {
            let problems = latest.issues.prefix(3).map { String($0.prefix(180)) }
            activity.stringValue = problems.isEmpty ? "正在监控" : "部分数据暂不可用"
            issue.stringValue = problems.joined(separator: " · ")
            if latest.timestamp.isFinite, latest.timestamp >= 0 {
                let age = max(0, ProcessInfo.processInfo.systemUptime - latest.timestamp)
                updated.stringValue = age.isFinite && age < 31_536_000
                    ? "更新于 " + timeFormatter.string(from: Date(timeIntervalSinceNow: -age)) : "更新时间不可用"
            } else { updated.stringValue = "更新时间不可用" }
        } else {
            activity.stringValue = "等待首次采样"
            updated.stringValue = ""
            issue.stringValue = "正在读取 CPU、内存和网络数据"
        }
        activity.setAccessibilityLabel(activity.stringValue)
        issue.toolTip = issue.stringValue.isEmpty ? nil : issue.stringValue
        issue.isHidden = issue.stringValue.isEmpty
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = max(1, bounds.width)
        let compact = width < 690
        let inset: CGFloat = width < 420 ? 0 : 6
        let contentWidth = max(1, width - inset * 2)
        activity.frame = CGRect(x: inset + 14, y: 3, width: max(1, contentWidth - 174), height: 22)
        updated.frame = CGRect(x: max(inset, width - inset - 155), y: 3, width: min(155, contentWidth), height: 22)
        let cards = [cpu, memory, network]
        let top: CGFloat = 30, gap: CGFloat = 12
        let cardHeight: CGFloat = compact ? 280 : 310
        var footerY: CGFloat
        if compact {
            for (index, card) in cards.enumerated() {
                card.frame = CGRect(x: inset, y: top + CGFloat(index) * (cardHeight + gap), width: contentWidth, height: cardHeight)
            }
            footerY = top + 3 * cardHeight + 2 * gap + 7
        } else {
            let cardWidth = max(1, (contentWidth - gap * 2) / 3)
            for (index, card) in cards.enumerated() {
                card.frame = CGRect(x: inset + CGFloat(index) * (cardWidth + gap), y: top, width: cardWidth, height: cardHeight)
            }
            footerY = top + cardHeight + 7
        }
        footnote.frame = CGRect(x: inset + 2, y: footerY, width: max(1, contentWidth - 4), height: 18)
        footerY += 20
        issue.frame = CGRect(x: inset + 2, y: footerY, width: max(1, contentWidth - 4), height: 30)
        let height = footerY + (issue.isHidden ? 8 : 32)
        if measuredHeight != height {
            measuredHeight = height
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let area = dirtyRect.intersection(bounds)
        if !area.isEmpty { SketchPalette.paper.setFill(); area.fill() }
        if !area.isEmpty, let texture = SketchPaper.image {
            NSBezierPath(rect: area).addClip()
            // Continue the surrounding paper's tile origin instead of adding a flat inset panel.
            var ancestor = superview
            while let candidate = ancestor, !(candidate is SketchSurface) { ancestor = candidate.superview }
            let origin: CGPoint = ancestor.map { convert(CGPoint.zero, from: $0) } ?? .zero
            let startX = origin.x + floor((area.minX - origin.x) / 128) * 128
            let startY = origin.y + floor((area.minY - origin.y) / 128) * 128
            for y in stride(from: startY, to: area.maxY, by: 128) {
                for x in stride(from: startX, to: area.maxX, by: 128) {
                    texture.draw(in: CGRect(x: x, y: y, width: 128, height: 128), from: .zero, operation: .multiply, fraction: 0.5)
                }
            }
        }
        let dot = NSBezierPath(ovalIn: CGRect(x: bounds.width < 420 ? 2 : 8, y: 10, width: 6, height: 6))
        (isEnabled ? SketchPalette.green : SketchPalette.muted).setFill()
        dot.fill()
    }
}

@MainActor
private final class SystemStatusMetricCard: NSView {
    enum Kind { case cpu, memory, network }
    private let kind: Kind
    private let heading = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "—")
    private let secondary = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "最近 1 分钟")
    private let chart = SystemStatusHistoryChart()
    private let downloadLegend = NSTextField(labelWithString: "↓ 下载")
    private let uploadLegend = NSTextField(labelWithString: "↑ 上传")
    private var outline: NSBezierPath?
    private var outlineBounds = CGRect.zero
    private var ratio: Double?
    override var isFlipped: Bool { true }

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        heading.stringValue = kind == .cpu ? "CPU" : (kind == .memory ? "内存" : "网络")
        heading.font = SketchPalette.heading(20)
        heading.textColor = SketchPalette.ink
        value.font = .monospacedDigitSystemFont(ofSize: kind == .cpu ? 42 : 34, weight: .semibold)
        value.textColor = kind == .network ? SketchPalette.blue : SketchPalette.ink
        secondary.font = .systemFont(ofSize: 13)
        secondary.textColor = kind == .network ? SketchPalette.green : SketchPalette.muted
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.textColor = SketchPalette.ink
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = SketchPalette.muted
        downloadLegend.font = .systemFont(ofSize: 12, weight: .medium)
        uploadLegend.font = .systemFont(ofSize: 12, weight: .medium)
        downloadLegend.textColor = SketchPalette.blue
        uploadLegend.textColor = SketchPalette.green
        for field in [heading, value, secondary, detail, caption, downloadLegend, uploadLegend] {
            field.lineBreakMode = .byTruncatingTail
            addSubview(field)
        }
        addSubview(chart)
        downloadLegend.isHidden = kind != .network
        uploadLegend.isHidden = kind != .network
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    private var accent: NSColor { kind == .cpu ? SketchPalette.blue : (kind == .memory ? SketchPalette.purple : SketchPalette.green) }

    func update(snapshot: SystemStatusSnapshot?, history: [SystemStatusSnapshot], isEnabled: Bool) {
        value.stringValue = "—"
        secondary.stringValue = isEnabled ? "等待数据" : "监控已关闭"
        detail.stringValue = ""
        secondary.font = .systemFont(ofSize: 13)
        ratio = nil
        var points: [SystemStatusHistoryChart.Point] = []
        var maximum = kind == .cpu ? 100.0 : 1.0
        var top = kind == .cpu ? "100%" : "—"
        if isEnabled, let snapshot {
            switch kind {
            case .cpu:
                if let cpu = Self.finite(snapshot.cpuPercent) {
                    value.stringValue = String(format: "%.0f%%", min(100, cpu))
                    secondary.stringValue = "CPU 总负载"
                    ratio = min(100, cpu) / 100
                } else { secondary.stringValue = snapshot.issues.isEmpty ? "建立采样基线" : "CPU 暂不可用" }
                detail.stringValue = "所有核心的平均负载"
                points = history.map { .init(time: $0.timestamp, values: [Self.finite($0.cpuPercent).map { min(100, $0) }]) }
            case .memory:
                let capacity = snapshot.memory.flatMap { $0.totalBytes > 0 ? $0 : nil }
                    ?? history.reversed().compactMap(\.memory).first { $0.totalBytes > 0 }
                if let total = capacity?.totalBytes {
                    maximum = Double(total)
                    top = Self.bytes(total)
                }
                if let memory = snapshot.memory, memory.totalBytes > 0 {
                    value.stringValue = Self.bytes(memory.usedBytes)
                    secondary.stringValue = "已用 / 共 " + Self.bytes(memory.totalBytes)
                    detail.stringValue = "压缩 " + Self.bytes(memory.compressedBytes) + " · 交换 " + Self.bytes(memory.swapBytes)
                    ratio = min(1, Double(memory.usedBytes) / Double(memory.totalBytes))
                } else { secondary.stringValue = "内存数据暂不可用" }
                points = history.map { point in
                    let bytes = point.memory.flatMap { memory -> Double? in
                        guard memory.totalBytes > 0 else { return nil }
                        return Double(memory.usedBytes)
                    }
                    return .init(time: point.timestamp, values: [bytes])
                }
            case .network:
                if let network = snapshot.network {
                    let down = Self.finite(network.downloadBytesPerSecond)
                    let up = Self.finite(network.uploadBytesPerSecond)
                    value.stringValue = down.map(Self.rate) ?? "—"
                    secondary.stringValue = "↑ " + (up.map(Self.rate) ?? "—")
                    secondary.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
                    detail.stringValue = network.interfaceName.isEmpty ? "网络接口不可用" : "接口 " + network.interfaceName
                    if down == nil && up == nil { detail.stringValue += " · 建立网速基线" }
                    points = history.map { point in
                        guard let old = point.network, old.interfaceName == network.interfaceName else {
                            return .init(time: point.timestamp, values: [nil, nil])
                        }
                        return .init(time: point.timestamp, values: [Self.finite(old.downloadBytesPerSecond), Self.finite(old.uploadBytesPerSecond)])
                    }
                } else { secondary.stringValue = "网络数据暂不可用" }
                let values = points.flatMap(\.values).compactMap { $0 }
                let peak = values.max() ?? 0
                maximum = Self.networkScale(peak)
                top = values.isEmpty ? "—" : Self.rate(maximum)
            }
        }
        chart.update(points: points, end: snapshot?.timestamp, maximum: maximum,
                     colors: kind == .network ? [SketchPalette.blue, SketchPalette.green] : [accent], top: top,
                     emptyText: !isEnabled ? "开启后显示实时曲线" : snapshot?.issues.isEmpty == false ? "暂无有效曲线" : "等待采样形成曲线")
        let summary = [heading.stringValue, value.stringValue, secondary.stringValue, detail.stringValue].filter { !$0.isEmpty }.joined(separator: "，")
        setAccessibilityLabel(summary)
        value.setAccessibilityLabel(kind == .network ? "下载 " + value.stringValue : value.stringValue)
        secondary.setAccessibilityLabel(kind == .network ? "上传 " + secondary.stringValue : secondary.stringValue)
        detail.toolTip = detail.stringValue.isEmpty ? nil : detail.stringValue
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 18
        let width = max(1, bounds.width - inset * 2)
        heading.frame = CGRect(x: inset + 43, y: 14, width: max(1, width - 43), height: 26)
        value.font = .monospacedDigitSystemFont(ofSize: kind == .cpu ? 36 : (kind == .network ? 27 : 30), weight: .semibold)
        value.frame = CGRect(x: inset, y: 50, width: width, height: 44)
        secondary.frame = CGRect(x: inset, y: kind == .network ? 96 : 99, width: width, height: kind == .network ? 30 : 22)
        detail.frame = CGRect(x: inset, y: bounds.height - 37, width: width, height: 20)
        let chartTop: CGFloat = 159
        chart.frame = CGRect(x: inset, y: chartTop, width: width, height: max(40, bounds.height - chartTop - 51))
        caption.frame = CGRect(x: inset, y: 141, width: max(1, width - (kind == .network ? 119 : 0)), height: 17)
        downloadLegend.frame = CGRect(x: max(inset, bounds.width - inset - 115), y: 141, width: 57, height: 17)
        uploadLegend.frame = CGRect(x: max(inset, bounds.width - inset - 54), y: 141, width: 54, height: 17)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        if outline == nil || outlineBounds != bounds {
            outlineBounds = bounds
            outline = SketchPencil.outline(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: 14)
        }
        guard let outline else { return }
        SketchPalette.paper.setFill(); outline.fill()
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let wash = NSBezierPath(roundedRect: CGRect(x: 7, y: 7, width: max(1, bounds.width - 14), height: 114), xRadius: 10, yRadius: 10)
        SketchPalette.fill(wash, color: accent.withAlphaComponent(0.1))
        NSGraphicsContext.restoreGraphicsState()
        SketchPencil.stroke(outline, color: SketchPalette.line.withAlphaComponent(0.56), width: 1.2)
        drawIcon(in: CGRect(x: 18, y: 14, width: 32, height: 28))
        if let ratio {
            let area = CGRect(x: 18, y: 124, width: max(1, bounds.width - 36), height: 8)
            let bar = SketchPencil.outline(in: area, radius: 4)
            SketchPalette.line.withAlphaComponent(0.08).setFill(); bar.fill()
            NSGraphicsContext.saveGraphicsState(); bar.addClip()
            let filled = NSBezierPath(rect: CGRect(x: area.minX, y: area.minY, width: area.width * CGFloat(ratio), height: area.height))
            SketchPalette.fill(filled, color: accent.withAlphaComponent(0.6))
            NSGraphicsContext.restoreGraphicsState()
            SketchPencil.stroke(bar, color: SketchPalette.line.withAlphaComponent(0.3), width: 0.7)
        }
    }

    private func drawIcon(in rect: CGRect) {
        let path = NSBezierPath()
        switch kind {
        case .cpu:
            let chip = rect.insetBy(dx: 6, dy: 5)
            path.append(SketchPencil.outline(in: chip, radius: 3))
            path.append(NSBezierPath(rect: chip.insetBy(dx: 4, dy: 4)))
            for step in 0...2 {
                let offset = CGFloat(step) * 6
                let x = chip.minX + 4 + offset, y = chip.minY + 4 + offset
                path.move(to: CGPoint(x: x, y: chip.minY)); path.line(to: CGPoint(x: x, y: rect.minY))
                path.move(to: CGPoint(x: x, y: chip.maxY)); path.line(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: chip.minX, y: y)); path.line(to: CGPoint(x: rect.minX, y: y))
                path.move(to: CGPoint(x: chip.maxX, y: y)); path.line(to: CGPoint(x: rect.maxX, y: y))
            }
        case .memory:
            let board = CGRect(x: rect.minX, y: rect.minY + 4, width: rect.width, height: 20)
            path.append(SketchPencil.outline(in: board, radius: 3))
            for step in 0..<4 {
                let x = rect.minX + 5 + CGFloat(step) * 6
                path.append(NSBezierPath(roundedRect: CGRect(x: x, y: board.minY + 5, width: 3, height: 10), xRadius: 1, yRadius: 1))
                path.move(to: CGPoint(x: x + 1.5, y: board.maxY)); path.line(to: CGPoint(x: x + 1.5, y: board.maxY + 4))
            }
        case .network:
            for step in 0..<3 {
                let inset = CGFloat(step) * 5
                let y = rect.minY + 9 + CGFloat(step) * 5
                path.move(to: CGPoint(x: rect.minX + inset, y: y))
                path.curve(to: CGPoint(x: rect.maxX - inset, y: y),
                           controlPoint1: CGPoint(x: rect.minX + inset + 5, y: y - 9 + CGFloat(step)),
                           controlPoint2: CGPoint(x: rect.maxX - inset - 5, y: y - 9 + CGFloat(step)))
            }
            accent.setFill(); NSBezierPath(ovalIn: CGRect(x: rect.midX - 2, y: rect.maxY - 5, width: 4, height: 4)).fill()
        }
        SketchPencil.stroke(path, color: accent, width: 1.9)
    }

    private static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
    private static func bytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes == 0 { return "0 B" }
        for (divisor, unit) in [(1_099_511_627_776.0, "TB"), (1_073_741_824.0, "GB"), (1_048_576.0, "MB"), (1_024.0, "KB")] {
            if value >= divisor { return String(format: "%.1f %@", value / divisor, unit) }
        }
        return "\(bytes) B"
    }
    private static func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_000_000_000_000 { return String(format: "%.1e B/s", value) }
        for (divisor, unit) in [(1_000_000_000.0, "GB/s"), (1_000_000.0, "MB/s"), (1_000.0, "KB/s")] {
            if value >= divisor { return String(format: "%.1f %@", value / divisor, unit) }
        }
        return String(format: "%.0f B/s", value)
    }
    private static func networkScale(_ peak: Double) -> Double {
        guard peak.isFinite, peak > 1 else { return 1 }
        let base = pow(10, floor(log10(peak)))
        let amount = peak / base
        let rounded = (amount <= 1 ? 1 : amount <= 2 ? 2 : amount <= 5 ? 5 : 10) * base
        return rounded.isFinite && rounded >= peak ? rounded : peak
    }
}

@MainActor
private final class SystemStatusHistoryChart: NSView {
    struct Point { let time: TimeInterval; let values: [Double?] }
    private var points: [Point] = []
    private var end: TimeInterval = 0
    private var maximum = 100.0
    private var colors: [NSColor] = []
    private var top = "100%"
    private var emptyText = "等待采样形成曲线"
    override var isFlipped: Bool { true }
    func update(points: [Point], end: TimeInterval?, maximum: Double, colors: [NSColor], top: String, emptyText: String) {
        self.points = Array(points.suffix(31))
        self.end = end.flatMap { $0.isFinite ? $0 : nil } ?? 0
        self.maximum = maximum.isFinite && maximum > 0 ? maximum : 1
        self.colors = Array(colors.prefix(2))
        self.top = top; self.emptyText = emptyText
        setAccessibilityRole(.image)
        setAccessibilityLabel("最近一分钟趋势，最大刻度 \(top)，最多 \(self.points.count) 个采样点")
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 20, bounds.height > 20 else { return }
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        let plot = CGRect(x: 16, y: 19, width: bounds.width - 17, height: max(1, bounds.height - 38))
        let grid = NSBezierPath()
        for index in 0...2 {
            let y = plot.minY + CGFloat(index) / 2 * plot.height
            grid.move(to: CGPoint(x: plot.minX, y: y)); grid.line(to: CGPoint(x: plot.maxX, y: y))
        }
        grid.lineWidth = 0.6
        let dash: [CGFloat] = [2, 4]; grid.setLineDash(dash, count: dash.count, phase: 0)
        SketchPalette.line.withAlphaComponent(0.18).setStroke(); grid.stroke()
        let text: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: SketchPalette.muted]
        (top as NSString).draw(at: CGPoint(x: 1, y: 0), withAttributes: text)
        ("0" as NSString).draw(at: CGPoint(x: 1, y: plot.maxY - 12), withAttributes: text)
        ("−60 秒" as NSString).draw(at: CGPoint(x: plot.minX, y: plot.maxY + 5), withAttributes: text)
        let now = "现在" as NSString
        now.draw(at: CGPoint(x: plot.maxX - now.size(withAttributes: text).width, y: plot.maxY + 5), withAttributes: text)
        var hasValue = false
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: plot.insetBy(dx: -1, dy: -1)).addClip()
        for (index, color) in colors.enumerated() {
            var previous: TimeInterval?
            var last: CGPoint?
            var segments: [[CGPoint]] = []
            for point in points {
                guard point.values.indices.contains(index), let value = point.values[index], value.isFinite, value >= 0,
                      point.time >= end - 60, point.time <= end else { previous = nil; continue }
                let location = CGPoint(x: plot.minX + CGFloat((point.time - (end - 60)) / 60) * plot.width,
                                       y: plot.maxY - CGFloat(min(maximum, value) / maximum) * plot.height)
                if let previous, point.time > previous, point.time - previous <= 6, !segments.isEmpty {
                    segments[segments.count - 1].append(location)
                } else { segments.append([location]) }
                previous = point.time; last = location; hasValue = true
            }
            for segment in segments {
                guard let first = segment.first else { continue }
                let path = NSBezierPath(); path.move(to: first)
                for location in segment.dropFirst() { path.line(to: location) }
                if let final = segment.last, segment.count > 1 {
                    let fill = path.copy() as! NSBezierPath
                    fill.line(to: CGPoint(x: final.x, y: plot.maxY))
                    fill.line(to: CGPoint(x: first.x, y: plot.maxY)); fill.close()
                    color.withAlphaComponent(0.09).setFill(); fill.fill()
                }
                SketchPencil.stroke(path, color: color, width: 2)
            }
            if let last { color.setFill(); NSBezierPath(ovalIn: CGRect(x: last.x - 2.1, y: last.y - 2.1, width: 4.2, height: 4.2)).fill() }
        }
        if !hasValue {
            let label = emptyText as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: SketchPalette.muted]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
        }
    }
}
