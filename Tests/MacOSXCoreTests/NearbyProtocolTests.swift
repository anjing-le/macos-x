import XCTest
@testable import MacOSXCore

final class NearbyProtocolTests: XCTestCase {
    private func paired() throws -> (NearbyCipher, NearbyCipher) {
        let a = NearbyCipher(), b = NearbyCipher()
        try a.receiveHello(b.hello()); try b.receiveHello(a.hello())
        XCTAssertEqual(a.code, b.code); XCTAssertEqual(a.code?.count, 6)
        let ac = try a.confirm(), bc = try b.confirm()
        _ = try b.open(ac); _ = try a.open(bc)
        XCTAssertTrue(a.ready && b.ready)
        return (a, b)
    }
    func testBothPeopleMustConfirmBeforeContent() throws {
        let a = NearbyCipher(), b = NearbyCipher()
        try a.receiveHello(b.hello()); try b.receiveHello(a.hello())
        XCTAssertThrowsError(try a.seal(NearbyMessage("text", id: UUID(), text: "private")))
        _ = try b.open(a.confirm())
        XCTAssertFalse(a.ready); XCTAssertFalse(b.ready)
        XCTAssertThrowsError(try b.seal(NearbyMessage("text", id: UUID(), text: "private")))
        _ = try a.open(b.confirm()); XCTAssertTrue(a.ready && b.ready)
    }
    func testEncryptedTextAndFileChunksRoundTrip() throws {
        let (a, b) = try paired()
        let text = "private clipboard"
        let sealed = try a.seal(NearbyMessage("text", id: UUID(), text: text))
        XCTAssertFalse(String(data: sealed, encoding: .utf8)!.contains(text))
        XCTAssertEqual(try b.open(sealed).text, text)
        let bytes = Data((0..<NearbyMessage.chunkBytes).map { UInt8($0 % 251) })
        let packet = try b.seal(NearbyMessage("chunk", id: UUID(), offset: 0, bytes: bytes))
        XCTAssertLessThanOrEqual(packet.count, NearbyMessage.maximumPacket)
        XCTAssertEqual(try a.open(packet).bytes, bytes)
    }
    func testReplayTamperingAndDifferentSessionRejected() throws {
        let (a, b) = try paired(), (c, _) = try paired()
        let packet = try a.seal(NearbyMessage("text", id: UUID(), text: "one"))
        XCTAssertThrowsError(try c.open(packet))
        _ = try b.open(packet); XCTAssertThrowsError(try b.open(packet))
        var invalid = try a.seal(NearbyMessage("text", id: UUID(), text: "two"))
        invalid[invalid.count / 2] ^= 1
        XCTAssertThrowsError(try b.open(invalid))
    }
    func testPacketAndFilesystemBoundaries() throws {
        for name in ["", ".", "..", "../x", "/tmp/x", "a/b", "a\\b", "a:b", ".hidden", "x\u{0}"] {
            XCTAssertNil(NearbyMessage.safeName(name))
        }
        XCTAssertNotNil(NearbyMessage.safeName("report 1.pdf"))
        XCTAssertThrowsError(try NearbyMessage("offer", id: UUID(), name: "x", kind: "file", size: NearbyMessage.maximumFile + 1).validate())
        XCTAssertThrowsError(try NearbyMessage("offer", id: UUID(), name: "x.png", kind: "image", size: NearbyMessage.maximumImage + 1).validate())
        XCTAssertThrowsError(try NearbyMessage("chunk", id: UUID(), offset: 0, bytes: Data(count: NearbyMessage.chunkBytes + 1)).validate())
        XCTAssertThrowsError(try NearbyMessage("chunk", id: UUID(), offset: -1, bytes: Data([1])).validate())
        XCTAssertThrowsError(try NearbyMessage("text", id: UUID(), text: String(repeating: "a", count: NearbyMessage.maximumText + 1)).validate())
        let a = NearbyCipher(); XCTAssertThrowsError(try a.receiveHello(Data(count: 513)))
        let b = NearbyCipher(); try a.receiveHello(b.hello()); XCTAssertThrowsError(try a.receiveHello(b.hello()))
    }
}
