import AppKit
import CryptoKit
import MacOSXCore

@MainActor private final class FixtureLink: NearbyLink {
    var onDevices: (([NearbyDevice]) -> Void)?
    var onInvitation: ((NearbyDevice) -> Void)?
    var onConnected: ((NearbyDevice) -> Void)?
    var onDisconnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onError: ((Error) -> Void)?
    weak var other: FixtureLink?
    let device: NearbyDevice
    var starts = 0, stops = 0, sentPackets = 0
    var connected = false
    var held = false
    var heldPackets: [Data] = []
    init(_ name: String) { device = NearbyDevice(id: UUID().uuidString, name: name) }
    func start() { starts += 1; onDevices?(other.map { [$0.device] } ?? []) }
    func stop() { stops += 1; connected = false }
    func invite(_ device: NearbyDevice) { other?.onInvitation?(self.device) }
    func answer(_ accept: Bool) {
        guard accept, let other else { return }
        connected = true; other.connected = true
        onConnected?(other.device); other.onConnected?(device)
    }
    func disconnect() {
        let wasConnected = connected; connected = false
        if wasConnected { other?.connected = false; other?.onDisconnected?() }
        onDisconnected?()
    }
    func send(_ data: Data) throws {
        guard connected, let other else { throw NearbyFailure.unpaired }
        sentPackets += 1
        if held { heldPackets.append(data); return }
        DispatchQueue.main.async { other.onData?(data) }
    }
}

@main struct NearbyRegression {
    @MainActor static func wait(_ description: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(15)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        precondition(condition(), description)
    }
    @MainActor private static func pair(_ a: NearbyTransferService, _ b: NearbyTransferService, _ link: FixtureLink) {
        a.connect(link.device); precondition(b.incomingInvitation)
        b.answer(true); wait("both peers show pairing code") { a.pairingCode != nil && b.pairingCode != nil }
        precondition(a.pairingCode == b.pairingCode && !a.ready && !b.ready)
        a.confirmPairing(); wait("first confirmation reaches peer") { b.pairingCode != nil }
        precondition(!a.ready && !b.ready)
        b.confirmPairing(); wait("both confirmations required") { a.ready && b.ready }
    }
    @MainActor private static func finalizedCancellation(_ root: URL, commit: Bool, replace: Bool) throws {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data([3, 5, 7]), final = folder.appendingPathComponent("received.bin")
        let pipe = NearbyFilePipe(id: UUID(), url: folder.appendingPathComponent(".pending.partial"), size: 3, receiving: true)
        var wrote = false, delivered = false, cleaned = false
        pipe.write(data, at: 0) { result in if case .success = result { wrote = true } }
        wait("provisional fixture write") { wrote }
        pipe.finish(digest: Data(SHA256.hash(data: data)), name: "received.bin") { result in
            if case .success = result { delivered = true }
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: final.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        precondition(FileManager.default.fileExists(atPath: final.path))
        if commit { wait("finish callback before owner commit") { delivered }; precondition(pipe.commit()) }
        else { precondition(!delivered, "rename happened while only this fixture's main thread was held") }
        if replace {
            try FileManager.default.moveItem(at: final, to: folder.appendingPathComponent("user-moved.bin"))
            try Data("replacement".utf8).write(to: final)
        }
        pipe.cancel { DispatchQueue.main.async { cleaned = true } }
        wait("provisional result and cancellation drain") { delivered && cleaned }
        if replace { precondition((try? Data(contentsOf: final)) == Data("replacement".utf8)) }
        else { precondition(FileManager.default.fileExists(atPath: final.path) == commit) }
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clipA = NSPasteboard(name: .init("nearby-a-\(UUID().uuidString)"))
        let clipB = NSPasteboard(name: .init("nearby-b-\(UUID().uuidString)"))
        defer { clipA.releaseGlobally(); clipB.releaseGlobally() }
        let la = FixtureLink("Fixture MacBook"), lb = FixtureLink("Fixture Mac mini")
        la.other = lb; lb.other = la
        let a = NearbyTransferService(link: la, clipboard: clipA, receiveFolder: root.appendingPathComponent("A"))
        let b = NearbyTransferService(link: lb, clipboard: clipB, receiveFolder: root.appendingPathComponent("B"))
        precondition(la.starts == 0 && lb.starts == 0, "unadded module does not discover")
        a.start(); a.start(); b.start(); precondition(la.starts == 1 && lb.starts == 1)
        pair(a, b, lb)
        clipB.setString("existing", forType: .string)
        clipA.setString("Clipboard fixture 123", forType: .string); a.paste()
        wait("text delivered and acknowledged") { b.records.first?.text == "Clipboard fixture 123" && a.records.first?.state == .sent }
        precondition(clipB.string(forType: .string) == "existing", "auto-copy off does not overwrite clipboard")
        b.copy(b.records[0].id); precondition(clipB.string(forType: .string) == "Clipboard fixture 123")
        b.autoCopy = true; clipA.clearContents(); clipA.setString("automatic text", forType: .string); a.paste()
        wait("explicit session auto-copy") { clipB.string(forType: .string) == "automatic text" && a.records.first?.state == .sent }
        b.autoCopy = false

        let payload = Data((0..<(NearbyMessage.chunkBytes * 9 + 713)).map { UInt8($0 % 251) })
        let file = root.appendingPathComponent("payload.bin"); try payload.write(to: file)
        a.sendFiles([file]); wait("file received with size and digest") { b.records.first?.name == "payload.bin" && b.records.first?.state == .received && a.records.first?.state == .sent }
        let received = b.records[0].url!; precondition((try? Data(contentsOf: received)) == payload)
        a.sendFiles([file]); wait("same-name transfer keeps earlier file") { b.records.first?.url?.lastPathComponent == "payload (2).bin" && a.records.first?.state == .sent }
        precondition((try? Data(contentsOf: received)) == payload)
        let empty = root.appendingPathComponent("empty.txt"); try Data().write(to: empty)
        a.sendFiles([empty]); wait("zero-byte file completes") { b.records.first?.name == "empty.txt" && b.records.first?.state == .received && a.records.first?.state == .sent }

        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 24, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:])!
        clipA.clearContents(); clipA.setData(png, forType: .png); a.paste()
        wait("clipboard image is a verified file transfer") { b.records.first?.kind == "image" && b.records.first?.state == .received && a.records.first?.state == .sent }
        let imageID = b.records[0].id
        var pinned: CGImage?
        b.onPin = { pinned = $0 }; b.copy(imageID, pin: true)
        wait("received image routes to pin action without clipboard") { pinned != nil }
        precondition(pinned?.width == 32 && pinned?.height == 24)
        b.copy(imageID); wait("image copies to isolated clipboard") { clipB.data(forType: .tiff) != nil }

        // Render the actual native view offscreen, never present a window or
        // start a real MCSession. This is a fixture, not dual-machine evidence.
        let view = NearbyTransferView(service: b)
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 548); view.layoutSubtreeIfNeeded()
        precondition(view.subviews.allSatisfy { $0.frame.maxX <= 422 && $0.frame.maxY <= 550 })
        if let destination = ProcessInfo.processInfo.environment["MACOSX_NEARBY_PREVIEW"] {
            let image = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: image)
            try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
        }

        let beforeA = a.records.filter { $0.incoming && $0.kind == "file" }.count
        let beforeB = b.records.filter { $0.incoming && $0.kind == "file" }.count
        a.sendFiles([file]); b.sendFiles([file])
        wait("simultaneous files in both directions") {
            a.records.filter { $0.incoming && $0.kind == "file" && $0.state == .received }.count == beforeA + 1 &&
            b.records.filter { $0.incoming && $0.kind == "file" && $0.state == .received }.count == beforeB + 1 &&
            !a.records.contains { $0.state == .sending } && !b.records.contains { $0.state == .sending }
        }

        let corrupt = NearbyFilePipe(id: UUID(), url: root.appendingPathComponent(".corrupt.partial"), size: 3, receiving: true)
        var wrote = false
        corrupt.write(Data([1, 2, 3]), at: 0) { result in if case .success = result { wrote = true } }
        wait("file fixture wrote one chunk") { wrote }
        var rejectedDigest = false
        corrupt.finish(digest: Data(count: 32), name: "corrupt.bin") { result in if case .failure = result { rejectedDigest = true } }
        wait("wrong digest is rejected before final filename") { rejectedDigest }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("corrupt.bin").path))
        corrupt.cancel()

        // Cancel after offer and then deliver old queued chunks: no completed
        // record and no partial file survive the cancelled operation.
        lb.held = true; a.sendFiles([file]); wait("receiver holds acceptance") { !lb.heldPackets.isEmpty }
        la.onData?(lb.heldPackets.removeFirst())
        wait("first chunk is written before cancellation") { b.records.first?.state == .sending && (b.records.first?.completed ?? 0) > 0 }
        let cancelledID = a.records[0].id; a.cancel(cancelledID)
        wait("receiver processes cancellation") { b.records.first(where: { $0.id == cancelledID })?.state == .cancelled }
        for packet in lb.heldPackets { la.onData?(packet) }; lb.heldPackets.removeAll(); lb.held = false
        wait("partial files removed after cancellation") {
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("B").path)) ?? []).allSatisfy { !$0.hasSuffix(".partial") }
        }
        precondition(a.records.first(where: { $0.id == cancelledID })?.state == .cancelled)
        b.autoCopy = true; a.disconnect(); precondition(!a.ready && !b.ready && !b.autoCopy)
        let count = b.records.count
        lb.onData?(Data([1, 2, 3])); precondition(b.records.count == count)
        a.stop(); b.stop(); a.stop()
        precondition(la.stops == 1 && lb.stops == 1 && !a.running && !b.running)
        var drainedA = false, drainedB = false
        a.prepareToTerminate { drainedA = true }; b.prepareToTerminate { drainedB = true }
        wait("termination drains owned IO cleanup") { drainedA && drainedB }
        try finalizedCancellation(root, commit: false, replace: false)
        try finalizedCancellation(root, commit: true, replace: false)
        try finalizedCancellation(root, commit: false, replace: true)
        let surfaceLink = FixtureLink("Surface Fixture")
        let surfaceService = NearbyTransferService(link: surfaceLink, clipboard: clipA, receiveFolder: root.appendingPathComponent("Surface"))
        var mainHidden = false, presentations: [ObjectIdentifier] = [], shown: NSPanel?
        let module = NearbyTransferModule(service: surfaceService, presentPanel: { panel, _ in
            precondition(mainHidden, "main client hides before presenting drawer")
            precondition(!panel.isVisible, "fixture never orders a real window onscreen")
            presentations.append(ObjectIdentifier(panel)); shown = panel
        })
        module.anchor = { CGRect(x: 600, y: 780, width: 30, height: 22) }
        module.onOpen = { mainHidden = true }
        module.start()
        let guide = module.makeDashboard()
        precondition(guide is NearbyTransferGuide && !(guide is NearbyTransferView), "settings is a guide, not a second transfer surface")
        guide.frame = CGRect(x: 0, y: 0, width: 312, height: 300); guide.layoutSubtreeIfNeeded()
        precondition(guide.subviews.allSatisfy { guide.bounds.contains($0.frame) }, "guide fits narrow settings")
        let open = guide.subviews.compactMap { $0 as? NSButton }.first!
        open.performClick(nil)
        precondition(presentations.count == 1 && mainHidden)
        mainHidden = false; module.show(focus: true)
        precondition(presentations.count == 2 && Set(presentations).count == 1, "opening again reuses the only drawer panel")
        let auto = (shown?.contentView as! NearbyTransferView).subviews.compactMap { $0 as? NSSwitch }.first!
        surfaceService.autoCopy = true
        precondition(auto.state == .off, "hidden drawer does not mutate its controls on background updates")
        module.show(focus: true)
        precondition(auto.state == .on, "drawer refreshes latest model immediately when reopened")
        var settingsRequested = false
        module.onSettings = { settingsRequested = true }
        (shown?.contentView as? NearbyTransferView)?.onSettings?()
        precondition(settingsRequested && !module.isDrawerVisible && surfaceService.running, "settings route dismisses drawer without disconnecting service")
        module.stop(); let countBefore = presentations.count; module.show(focus: true)
        precondition(presentations.count == countBefore, "disabled module cannot show a drawer")
        print("PASS nearby: mutual pairing, encrypted acknowledged text/files/images, session auto-copy, same-name and empty files, cancellation, teardown and native offscreen layout; no discovery, live windows or general clipboard")
        print("PASS single drawer: settings guide only, main hides before presentation, one reusable panel, settings route dismisses drawer; presentation injected, no live windows")
    }
}
