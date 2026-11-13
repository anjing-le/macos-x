// Pinned v0.0.149 wire peer from d71fd03. Keep independent of the current codec
// to verify real old/new handshake, SAS, encryption and record compatibility.
import Foundation
import CryptoKit
import MacOSXCore

final class LegacyNearbyCipherFixture {
    private struct Hello: Codable { let version: Int; let key: Data; let nonce: Data }
    private struct Record: Codable { let sequence: UInt64; let payload: Data }
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    private var key: SymmetricKey?
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    public private(set) var code: String?
    public private(set) var localConfirmed = false
    public private(set) var remoteConfirmed = false
    public var ready: Bool { localConfirmed && remoteConfirmed && key != nil }
    public init() {}
    public func hello() throws -> Data {
        try JSONEncoder().encode(Hello(version: 1, key: privateKey.publicKey.rawRepresentation, nonce: nonce))
    }
    public func receiveHello(_ data: Data) throws {
        guard key == nil, data.count <= 512 else { throw NearbyFailure.invalid }
        let peer = try JSONDecoder().decode(Hello.self, from: data)
        guard peer.version == 1, peer.key.count == 32, peer.nonce.count == 32,
              peer.key != privateKey.publicKey.rawRepresentation else { throw NearbyFailure.invalid }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.key)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let local = privateKey.publicKey.rawRepresentation + nonce, remote = peer.key + peer.nonce
        let transcript = local.lexicographicallyPrecedes(remote) ? local + remote : remote + local
        let salt = Data(SHA256.hash(data: transcript))
        key = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                            sharedInfo: Data("macos-x-nearby-v1".utf8), outputByteCount: 32)
        let check = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
            sharedInfo: Data("macos-x-nearby-sas-v1".utf8), outputByteCount: 4)
        let number = check.withUnsafeBytes { $0.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } } % 1_000_000
        code = String(format: "%06llu", number)
    }
    public func confirm() throws -> Data {
        guard key != nil else { throw NearbyFailure.unpaired }
        let data = try seal(NearbyMessage("confirm")); localConfirmed = true; return data
    }
    public func seal(_ message: NearbyMessage) throws -> Data {
        guard let key, message.type == "confirm" || ready else { throw NearbyFailure.unpaired }
        try message.validate(); guard sent < UInt64.max else { throw NearbyFailure.invalid }
        let sequence = sent + 1
        let plain = try JSONEncoder().encode(message)
        guard plain.count <= NearbyMessage.maximumPacket - 1024 else { throw NearbyFailure.invalid }
        let box = try AES.GCM.seal(plain, using: key, authenticating: Data("nearby-v1:\(sequence)".utf8))
        let data = try JSONEncoder().encode(Record(sequence: sequence, payload: box.combined!))
        guard data.count <= NearbyMessage.maximumPacket else { throw NearbyFailure.invalid }
        sent = sequence; return data
    }
    public func open(_ data: Data) throws -> NearbyMessage {
        guard let key, data.count <= NearbyMessage.maximumPacket else { throw NearbyFailure.invalid }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard received < UInt64.max, record.sequence == received + 1 else { throw NearbyFailure.replay }
        let box = try AES.GCM.SealedBox(combined: record.payload)
        let plain = try AES.GCM.open(box, using: key, authenticating: Data("nearby-v1:\(record.sequence)".utf8))
        let message = try JSONDecoder().decode(NearbyMessage.self, from: plain); try message.validate()
        guard message.type == "confirm" || ready else { throw NearbyFailure.unpaired }
        received = record.sequence
        if message.type == "confirm" { remoteConfirmed = true }
        return message
    }
}
