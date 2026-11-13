import Foundation
@preconcurrency import MultipeerConnectivity
import MacOSXCore

struct NearbyDevice: Equatable {
    let id: String
    let name: String
}

@MainActor protocol NearbyLink: AnyObject {
    var onDevices: (([NearbyDevice]) -> Void)? { get set }
    var onInvitation: ((NearbyDevice) -> Void)? { get set }
    var onConnected: ((NearbyDevice) -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start()
    func stop()
    func invite(_ device: NearbyDevice)
    func answer(_ accept: Bool)
    func send(_ data: Data) throws
    func disconnect()
}

/// No discovery, sockets, or system permissions are touched until start().
@MainActor final class NearbyMultipeerLink: NSObject, NearbyLink {
    var onDevices: (([NearbyDevice]) -> Void)?
    var onInvitation: ((NearbyDevice) -> Void)?
    var onConnected: ((NearbyDevice) -> Void)?
    var onDisconnected: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onError: ((Error) -> Void)?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peers: [String: MCPeerID] = [:]
    private var selected: MCPeerID?
    private var announcedConnection = false
    private nonisolated let inboundBudget = NearbyPacketBudget()
    private var invitation: ((Bool, MCSession?) -> Void)?
    private var timeout: DispatchWorkItem?
    private static let service = "macosx-nearby"

    func start() {
        guard session == nil else { return }
        var name = Host.current().localizedName ?? "Mac"
        while name.utf8.count > 60 { name.removeLast() }
        if name.isEmpty { name = "Mac" }
        let peer = MCPeerID(displayName: name)
        let session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        self.session = session; session.delegate = self
        let advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["protocol": "1"], serviceType: Self.service)
        let browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.service)
        self.advertiser = advertiser; self.browser = browser
        advertiser.delegate = self; browser.delegate = self
        advertiser.startAdvertisingPeer(); browser.startBrowsingForPeers()
    }
    func stop() {
        timeout?.cancel(); timeout = nil
        invitation?(false, nil); invitation = nil
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        advertiser?.delegate = nil; browser?.delegate = nil
        session?.delegate = nil; session?.disconnect()
        session = nil; advertiser = nil; browser = nil; selected = nil; announcedConnection = false
        peers.removeAll(); onDevices?([])
    }
    func disconnect() {
        let restart = session != nil
        stop(); onDisconnected?()
        if restart { start() }
    }
    func invite(_ device: NearbyDevice) {
        guard selected == nil, invitation == nil, let peer = peers[device.id], let session else { return }
        selected = peer
        browser?.invitePeer(peer, to: session, withContext: Data([1]), timeout: 30)
    }
    func answer(_ accept: Bool) {
        timeout?.cancel(); timeout = nil
        let callback = invitation; invitation = nil
        callback?(accept, accept ? session : nil)
        if !accept { selected = nil }
    }
    func send(_ data: Data) throws {
        guard data.count <= NearbyMessage.maximumPacket, let session, let peer = selected,
              session.connectedPeers.contains(peer) else { throw NearbyFailure.unpaired }
        try session.send(data, toPeers: [peer], with: .reliable)
    }
    private func device(_ peer: MCPeerID) -> NearbyDevice {
        if let key = peers.first(where: { $0.value == peer })?.key { return NearbyDevice(id: key, name: peer.displayName) }
        let key = UUID().uuidString; peers[key] = peer
        return NearbyDevice(id: key, name: peer.displayName)
    }
}

extension NearbyMultipeerLink: MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        guard info?["protocol"] == "1" else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser, self.peers.count < 64 || self.peers.values.contains(peerID) else { return }
            _ = self.device(peerID)
            self.onDevices?(self.peers.map { NearbyDevice(id: $0.key, name: $0.value.displayName) }.sorted { $0.name < $1.name })
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.browser === browser else { return }
            self.peers = self.peers.filter { $0.value != peerID || $0.value == self.selected }
            self.onDevices?(self.peers.map { NearbyDevice(id: $0.key, name: $0.value.displayName) }.sorted { $0.name < $1.name })
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { [weak self] in guard self?.browser === browser else { return }; self?.onError?(error) }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { [weak self] in guard self?.advertiser === advertiser else { return }; self?.onError?(error) }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                 withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.advertiser === advertiser, context == Data([1]), let session = self.session else { invitationHandler(false, nil); return }
            // Both sides explicitly chose the same peer at once.
            if self.selected == peerID, self.invitation == nil { invitationHandler(true, session); return }
            guard self.selected == nil, self.invitation == nil else { invitationHandler(false, nil); return }
            self.selected = peerID; self.invitation = invitationHandler
            self.onInvitation?(self.device(peerID))
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.session === session, self.invitation != nil else { return }
                self.answer(false); self.onDisconnected?()
            }
            self.timeout = timeout; DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
        }
    }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session === session, self.selected == peerID else { return }
            if state == .connected, !self.announcedConnection {
                self.announcedConnection = true; self.onConnected?(self.device(peerID))
            }
            if state == .notConnected { self.disconnect() }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= NearbyMessage.maximumPacket, inboundBudget.reserve() else { return }
        DispatchQueue.main.async { [weak self] in
            defer { self?.inboundBudget.release() }
            guard let self, self.session === session, self.selected == peerID else { return }
            if !self.announcedConnection {
                self.announcedConnection = true; self.onConnected?(self.device(peerID))
            }
            self.onData?(data)
        }
    }
    nonisolated func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?, fromPeer peerID: MCPeerID,
                            certificateHandler: @escaping (Bool) -> Void) {
        // This channel is additionally authenticated by user-compared ECDH SAS;
        // all application data, including file chunks, is AEAD encrypted.
        certificateHandler(true)
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { stream.close() }
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { progress.cancel() }
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

private final class NearbyPacketBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    func reserve() -> Bool { lock.lock(); defer { lock.unlock() }; guard pending < 8 else { return false }; pending += 1; return true }
    func release() { lock.lock(); pending -= 1; lock.unlock() }
}
