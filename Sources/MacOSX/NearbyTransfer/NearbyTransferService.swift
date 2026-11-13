import AppKit
import UniformTypeIdentifiers
import ImageIO
import MacOSXCore

struct NearbyTransferRecord: Identifiable {
    enum State: Equatable { case sending, received, sent, failed, cancelled }
    let id: UUID
    let name: String
    let incoming: Bool
    let kind: String
    var size: Int64
    var completed: Int64 = 0
    var state: State = .sending
    var url: URL?
    var text: String?
    var thumbnail: CGImage?
}

@MainActor final class NearbyTransferService {
    var onChange: (() -> Void)?
    var onAttention: (() -> Void)?
    var onPin: ((CGImage) -> Void)? { didSet { onChange?() } }
    private(set) var running = false
    private(set) var devices: [NearbyDevice] = []
    private(set) var device: NearbyDevice?
    private(set) var incomingInvitation = false
    private(set) var records: [NearbyTransferRecord] = []
    private(set) var status = ""
    var autoCopy = false { didSet { onChange?() } }
    var ready: Bool { running && cipher?.ready == true }
    var pairingCode: String? { cipher?.code }
    var confirmed: Bool { cipher?.localConfirmed == true }
    var pendingCount: Int { queued.count }
    private let link: any NearbyLink
    private let clipboard: NSPasteboard
    private let receiveFolder: URL
    private let io = DispatchQueue(label: "cc.anjing.macos-x.nearby.prepare", qos: .utility)
    private var cipher: NearbyCipher?
    private var generation = UUID()
    private var pairingTimeout: DispatchWorkItem?
    private var sendTimeout: DispatchWorkItem?
    private var receiveTimeout: DispatchWorkItem?
    private var sendDeadline: TimeInterval = 0
    private var receiveDeadline: TimeInterval = 0
    private var progressNotice: DispatchWorkItem?
    private var outgoing: NearbyFilePipe?
    private var incoming: NearbyFilePipe?
    private var incomingBusy = false
    private var waitingOffset: Int64?
    private var lastOutgoingOffset: Int64 = 0
    private var awaitingAcceptance = false
    private var awaitingDone = false
    private var preparing = false
    private var preparingClipboard = false
    private var queued: [(URL, String, Bool)] = []
    private var temporarySend: URL?
    private var scopedURL: URL?
    private var pendingText: UUID?
    private var pendingCopy: UUID?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var sleeping = false

    init(link: any NearbyLink, clipboard: NSPasteboard = .general, receiveFolder: URL? = nil) {
        self.link = link; self.clipboard = clipboard
        self.receiveFolder = receiveFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("macos-x", isDirectory: true).appendingPathComponent("Nearby", isDirectory: true)
        link.onDevices = { [weak self] value in self?.devices = value; self?.changed() }
        link.onInvitation = { [weak self] device in
            guard let self, self.running, self.device == nil else { self?.link.answer(false); return }
            self.device = device; self.incomingInvitation = true; self.changed(); self.onAttention?()
        }
        link.onConnected = { [weak self] device in self?.connected(device) }
        link.onDisconnected = { [weak self] in self?.reset() }
        link.onData = { [weak self] data in self?.receive(data) }
        link.onError = { [weak self] error in self?.status = AppLanguage.text("附近设备连接失败，请检查本地网络权限。") + " " + error.localizedDescription; self?.changed() }
    }
    func start() {
        guard !running else { return }
        running = true; status = ""; link.start()
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.sleeping = true; self.link.stop(); self.reset()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.sleeping else { return }
                self.sleeping = false; self.link.start(); self.changed()
            }
        }
        changed()
    }
    func stop() {
        guard running else { return }
        running = false; link.stop(); reset(); devices.removeAll()
        for index in records.indices { records[index].thumbnail = nil }
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver); self.sleepObserver = nil }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
        sleeping = false
        changed()
    }
    func connect(_ device: NearbyDevice) {
        guard running, self.device == nil else { return }
        self.device = device; status = AppLanguage.text("正在连接…"); armPairingTimeout(); link.invite(device); changed()
    }
    func answer(_ accept: Bool) {
        guard incomingInvitation else { return }
        incomingInvitation = false; link.answer(accept)
        if accept { armPairingTimeout() } else { reset() }
        changed()
    }
    func confirmPairing() {
        guard let cipher, cipher.code != nil, !cipher.localConfirmed else { return }
        do { try link.send(cipher.confirm()); pairedIfReady(); changed() }
        catch { failConnection() }
    }
    func disconnect() { link.disconnect(); reset() }
    private func reset() {
        generation = UUID(); pairingTimeout?.cancel(); pairingTimeout = nil
        sendTimeout?.cancel(); sendTimeout = nil; receiveTimeout?.cancel(); receiveTimeout = nil
        progressNotice?.cancel(); progressNotice = nil
        outgoing?.cancel(); incoming?.cancel(); outgoing = nil; incoming = nil
        for index in records.indices where records[index].state == .sending { records[index].state = .failed }
        if let temporarySend { removeTemporary(temporarySend) }; temporarySend = nil
        queued.filter { $0.2 }.forEach { removeTemporary($0.0) }; queued.removeAll()
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        preparing = false; preparingClipboard = false; incomingBusy = false; waitingOffset = nil; pendingText = nil; pendingCopy = nil
        awaitingAcceptance = false; awaitingDone = false
        cipher = nil; device = nil; incomingInvitation = false; autoCopy = false; status = ""; changed()
    }
    private func connected(_ device: NearbyDevice) {
        guard running, self.device?.id == device.id, cipher == nil else { return }
        incomingInvitation = false; cipher = NearbyCipher(); armPairingTimeout()
        do { try link.send(cipher!.hello()) } catch { failConnection() }
        changed()
    }
    private func armPairingTimeout() {
        pairingTimeout?.cancel(); let epoch = generation
        let task = DispatchWorkItem { [weak self] in guard let self, self.generation == epoch, !self.ready else { return }; self.failConnection() }
        pairingTimeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: task)
    }
    private func pairedIfReady() {
        if ready { pairingTimeout?.cancel(); pairingTimeout = nil; status = AppLanguage.text("已连接"); startNext() }
    }
    private func failConnection() { disconnect(); status = AppLanguage.text("连接已结束，请重新连接并核对配对码。"); changed() }
    private func receive(_ data: Data) {
        guard running, let cipher else { return }
        do {
            if cipher.code == nil {
                try cipher.receiveHello(data); status = AppLanguage.text("请核对两台 Mac 的配对码"); changed(); onAttention?(); return
            }
            let message = try cipher.open(data)
            if message.type == "confirm" { pairedIfReady(); changed(); return }
            try process(message)
        } catch { failConnection() }
    }
    private func send(_ message: NearbyMessage) throws {
        guard let cipher else { throw NearbyFailure.unpaired }
        try link.send(cipher.seal(message))
    }
    private func changed() { progressNotice?.cancel(); progressNotice = nil; onChange?() }
    private func updateProgress(_ id: UUID, completed: Int64) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].completed = completed
        guard progressNotice == nil else { return }
        let epoch = generation
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.progressNotice = nil; self.onChange?()
        }
        progressNotice = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
    }
    private func add(_ record: NearbyTransferRecord) {
        records.insert(record, at: 0)
        while records.count > 30, let index = records.lastIndex(where: { $0.state != .sending }) { records.remove(at: index) }
        changed()
    }
    private func update(_ id: UUID, _ body: (inout NearbyTransferRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        body(&records[index]); changed()
    }

    func sendFiles(_ urls: [URL]) {
        guard ready else { return }
        let capacity = max(0, 16 - queued.count - (outgoing == nil && !preparing ? 0 : 1))
        guard !urls.isEmpty, urls.count <= capacity, urls.allSatisfy(\.isFileURL) else {
            status = AppLanguage.text("每次最多等待传输 16 个文件。"); changed(); return
        }
        queued += urls.map { ($0, "file", false) }; startNext(); changed()
    }
    private func startNext() {
        guard ready, outgoing == nil, !preparing, pendingText == nil, !queued.isEmpty else { return }
        preparing = true; let epoch = generation, item = queued.removeFirst()
        let access = item.0.startAccessingSecurityScopedResource()
        io.async { [weak self] in
            let result = Result<Int64, Error> {
                let values = try item.0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size >= 0, Int64(size) <= NearbyMessage.maximumFile,
                      item.1 != "image" || Int64(size) <= NearbyMessage.maximumImage,
                      NearbyMessage.safeName(item.0.lastPathComponent) != nil else { throw NearbyFailure.invalid }
                return Int64(size)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch, self.ready else {
                    if access { item.0.stopAccessingSecurityScopedResource() }
                    if item.2 { try? FileManager.default.removeItem(at: item.0) }; return
                }
                self.preparing = false
                switch result {
                case .success(let size):
                    if access { self.scopedURL = item.0 }
                    if item.2 { self.temporarySend = item.0 }
                    let id = UUID(); self.outgoing = NearbyFilePipe(id: id, url: item.0, size: size, receiving: false)
                    self.lastOutgoingOffset = 0; self.awaitingAcceptance = true; self.awaitingDone = false
                    let name = item.1 == "image" ? AppLanguage.text("剪贴板图片.png") : item.0.lastPathComponent
                    self.add(NearbyTransferRecord(id: id, name: name, incoming: false, kind: item.1, size: size))
                    do { try self.send(NearbyMessage("offer", id: id, name: name, kind: item.1, size: size)); self.armSendTimeout(id) }
                    catch { self.failConnection() }
                case .failure:
                    if access { item.0.stopAccessingSecurityScopedResource() }
                    if item.2 { self.removeTemporary(item.0) }
                    self.status = AppLanguage.text("文件不可发送：请选择不超过 2 GB 的普通文件。"); self.changed(); self.startNext()
                }
            }
        }
    }
    private func readNext(_ pipe: NearbyFilePipe) {
        let epoch = generation
        pipe.read { [weak self, weak pipe] result in
            guard let self, let pipe, self.generation == epoch, self.outgoing === pipe, self.ready else { return }
            do {
                let (data, offset, digest) = try result.get()
                if let digest {
                    self.awaitingDone = true; try self.send(NearbyMessage("finish", id: pipe.id, digest: digest))
                } else {
                    self.waitingOffset = offset + Int64(data.count)
                    try self.send(NearbyMessage("chunk", id: pipe.id, offset: offset, bytes: data))
                }
                self.armSendTimeout(pipe.id)
            } catch { self.cancel(pipe.id, failed: true) }
        }
    }
    private func armSendTimeout(_ id: UUID) {
        sendDeadline = ProcessInfo.processInfo.systemUptime + 30
        if sendTimeout == nil { scheduleSendTimeout(id, epoch: generation, delay: 30) }
    }
    private func scheduleSendTimeout(_ id: UUID, epoch: UUID, delay: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.sendTimeout = nil
            guard self.outgoing?.id == id || self.pendingText == id else { return }
            let remaining = self.sendDeadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { self.cancel(id, failed: true) }
            else { self.scheduleSendTimeout(id, epoch: epoch, delay: remaining) }
        }
        sendTimeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func armReceiveTimeout(_ id: UUID) {
        receiveDeadline = ProcessInfo.processInfo.systemUptime + 30
        if receiveTimeout == nil { scheduleReceiveTimeout(id, epoch: generation, delay: 30) }
    }
    private func scheduleReceiveTimeout(_ id: UUID, epoch: UUID, delay: TimeInterval) {
        let task = DispatchWorkItem { [weak self] in
            guard let self, self.generation == epoch else { return }
            self.receiveTimeout = nil
            guard self.incoming?.id == id else { return }
            let remaining = self.receiveDeadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { self.cancel(id, failed: true) }
            else { self.scheduleReceiveTimeout(id, epoch: epoch, delay: remaining) }
        }
        receiveTimeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }
    private func finishOutgoing(_ state: NearbyTransferRecord.State) {
        if let pipe = outgoing { pipe.cancel(); update(pipe.id) { $0.state = state; if state == .sent { $0.completed = $0.size } } }
        outgoing = nil; waitingOffset = nil; awaitingAcceptance = false; awaitingDone = false
        sendTimeout?.cancel(); sendTimeout = nil
        if let temporarySend { removeTemporary(temporarySend) }; temporarySend = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        startNext()
    }
    func cancel(_ id: UUID, failed: Bool = false, notify: Bool = true) {
        if notify { try? send(NearbyMessage("cancel", id: id)) }
        if incoming?.id == id {
            incoming?.cancel(); incoming = nil; incomingBusy = false
            receiveTimeout?.cancel(); receiveTimeout = nil
            update(id) { $0.state = failed ? .failed : .cancelled }
        }
        if outgoing?.id == id { finishOutgoing(failed ? .failed : .cancelled) }
        if pendingText == id {
            pendingText = nil; sendTimeout?.cancel(); sendTimeout = nil
            update(id) { $0.state = failed ? .failed : .cancelled }; startNext()
        }
    }
    private func process(_ message: NearbyMessage) throws {
        guard ready, let id = message.id else { throw NearbyFailure.unpaired }
        switch message.type {
        case "text":
            guard !records.contains(where: { $0.id == id }) else { try send(NearbyMessage("done", id: id)); return }
            let text = message.text!
            add(NearbyTransferRecord(id: id, name: String(text.prefix(72)), incoming: true, kind: "text", size: Int64(text.utf8.count), state: .received, text: text))
            try send(NearbyMessage("done", id: id)); if autoCopy { copy(id, automatic: true) }; onAttention?()
        case "offer":
            guard incoming == nil, !records.contains(where: { $0.id == id }) else { try send(NearbyMessage("cancel", id: id)); return }
            let url = receiveFolder.appendingPathComponent(".nearby-\(id.uuidString).partial")
            incoming = NearbyFilePipe(id: id, url: url, size: message.size!, receiving: true); incomingBusy = false
            add(NearbyTransferRecord(id: id, name: message.name!, incoming: true, kind: message.kind!, size: message.size!))
            try send(NearbyMessage("accept", id: id)); armReceiveTimeout(id)
        case "accept":
            guard let pipe = outgoing, pipe.id == id else { return }
            guard awaitingAcceptance else { throw NearbyFailure.invalid }
            awaitingAcceptance = false; readNext(pipe)
        case "chunk":
            guard let pipe = incoming, pipe.id == id else { return }
            guard !incomingBusy else { throw NearbyFailure.invalid }
            incomingBusy = true; let epoch = generation
            pipe.write(message.bytes!, at: message.offset!) { [weak self, weak pipe] result in
                guard let self, let pipe, self.generation == epoch, self.incoming === pipe else { return }
                self.incomingBusy = false
                do {
                    let offset = try result.get(); self.updateProgress(id, completed: offset)
                    try self.send(NearbyMessage("ack", id: id, offset: offset)); self.armReceiveTimeout(id)
                } catch { self.cancel(id, failed: true) }
            }
        case "ack":
            guard let pipe = outgoing, pipe.id == id else { return }
            guard let expected = waitingOffset, message.offset == expected, expected > lastOutgoingOffset else { throw NearbyFailure.invalid }
            lastOutgoingOffset = expected; waitingOffset = nil; updateProgress(id, completed: expected); readNext(pipe)
        case "finish":
            guard let pipe = incoming, pipe.id == id else { return }
            guard !incomingBusy, let record = records.first(where: { $0.id == id }) else { throw NearbyFailure.invalid }
            incomingBusy = true; let epoch = generation
            pipe.finish(digest: message.digest!, name: record.name) { [weak self, weak pipe] result in
                guard let self, let pipe, self.generation == epoch, self.incoming === pipe else { return }
                switch result {
                case .success(let url):
                    self.incoming = nil; self.incomingBusy = false; self.receiveTimeout?.cancel(); self.receiveTimeout = nil
                    self.update(id) { $0.state = .received; $0.url = url; $0.completed = $0.size }
                    if record.kind == "image" { self.loadThumbnail(id, url: url) }
                    do { try self.send(NearbyMessage("done", id: id)) } catch { self.failConnection() }
                    if self.autoCopy, record.kind == "image" { self.copy(id, automatic: true) }; self.onAttention?()
                case .failure: self.cancel(id, failed: true)
                }
            }
        case "done":
            if outgoing?.id == id { guard awaitingDone else { throw NearbyFailure.invalid }; finishOutgoing(.sent) }
            else if pendingText == id { pendingText = nil; sendTimeout?.cancel(); sendTimeout = nil; update(id) { $0.state = .sent }; startNext() }
        case "cancel": cancel(id, notify: false)
        default: throw NearbyFailure.invalid
        }
    }
    func paste() {
        guard ready, !preparingClipboard else { return }
        if let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { sendFiles(urls); return }
        if let type = clipboard.availableType(from: [.png, .tiff]), let data = clipboard.data(forType: type) {
            guard data.count <= NearbyMessage.maximumImage, queued.count < 16 else { status = AppLanguage.text("图片过大，请作为文件发送。"); changed(); return }
            preparingClipboard = true
            let epoch = generation, url = FileManager.default.temporaryDirectory.appendingPathComponent("macos-x-nearby-\(UUID().uuidString).png")
            io.async { [weak self] in
                let result = Result<Void, Error> {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                          w > 0, h > 0, w <= 32_000_000 / h,
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw NearbyFailure.invalid }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw NearbyFailure.invalid }
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == epoch, self.ready else { try? FileManager.default.removeItem(at: url); return }
                    self.preparingClipboard = false
                    if case .success = result, self.queued.count < 16 { self.queued.append((url, "image", true)); self.startNext() }
                    else { self.removeTemporary(url); self.status = AppLanguage.text("无法读取剪贴板图片。"); self.changed() }
                }
            }
            return
        }
        guard let text = clipboard.string(forType: .string), !text.isEmpty,
              text.utf8.count <= NearbyMessage.maximumText else { status = AppLanguage.text("剪贴板为空或文字过长，请作为文件发送。"); changed(); return }
        guard pendingText == nil, outgoing == nil, !preparing else { status = AppLanguage.text("请等待当前传输完成。"); changed(); return }
        let id = UUID(); pendingText = id
        add(NearbyTransferRecord(id: id, name: String(text.prefix(72)), incoming: false, kind: "text", size: Int64(text.utf8.count), text: text))
        do { try send(NearbyMessage("text", id: id, text: text)); armSendTimeout(id) } catch { failConnection() }
    }
    func copy(_ id: UUID, pin: Bool = false, automatic: Bool = false) {
        guard let record = records.first(where: { $0.id == id }), record.state == .received else { return }
        if let text = record.text {
            clipboard.clearContents()
            status = clipboard.setString(text, forType: .string) ? AppLanguage.text("文字已复制") : AppLanguage.text("复制失败")
            changed(); return
        }
        guard record.kind == "image", let url = record.url, pendingCopy == nil else { return }
        pendingCopy = id; let epoch = generation, clipboardCount = clipboard.changeCount
        io.async { [weak self] in
            let image: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 32_000_000 / h else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, nil)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch, self.pendingCopy == id else { return }
                self.pendingCopy = nil
                guard pin || (self.clipboard.changeCount == clipboardCount && (!automatic || self.autoCopy)) else { return }
                guard let image else { self.status = AppLanguage.text("图片无法读取，请在 Finder 中查看。"); self.changed(); return }
                if pin { self.onPin?(image) }
                else {
                    self.clipboard.clearContents()
                    self.status = self.clipboard.writeObjects([NSImage(cgImage: image, size: .zero)]) ? AppLanguage.text("图片已复制") : AppLanguage.text("复制失败")
                }
                self.changed()
            }
        }
    }
    func reveal(_ id: UUID) {
        if let url = records.first(where: { $0.id == id && $0.state == .received })?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
    private func loadThumbnail(_ id: UUID, url: URL) {
        let epoch = generation
        io.async { [weak self] in
            let thumbnail: CGImage? = autoreleasepool {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 32_000_000 / h else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 96] as CFDictionary)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == epoch else { return }
                self.update(id) { $0.thumbnail = thumbnail }
            }
        }
    }
    private func removeTemporary(_ url: URL) { io.async { try? FileManager.default.removeItem(at: url) } }
}
