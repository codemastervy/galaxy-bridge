import XCTest
@testable import WearLink

final class PairingTests: XCTestCase {
    func testIOSCapabilitiesPayloadSelectsGattTransport() {
        XCTAssertEqual([UInt8](SetupPairing.capabilitiesPayload()), [0x04, 0x00, 0x08, 0x01, 0x10, 0x02])
    }
}

final class PacketLinkTests: XCTestCase {
    func testChunksAndSequenceNumbers() {
        let link = PacketLink(mtu: 10) // chunk = 4
        let packets = link.packets(for: Data([1, 2, 3, 4, 5, 6]))
        XCTAssertEqual(packets.map { [UInt8]($0) }, [[0, 0, 0, 1, 2, 3, 4], [0, 0, 1, 5, 6]])
        XCTAssertEqual(link.pendingCount, 2)
    }

    func testCumulativeAckClearsWindow() {
        let link = PacketLink(mtu: 10)
        _ = link.packets(for: Data(repeating: 9, count: 12)) // seq 0,1,2
        _ = link.receive(Data([0x02, 1]))
        XCTAssertEqual(link.pendingCount, 1)
    }

    func testNackRetransmitsRemainder() {
        let link = PacketLink(mtu: 10)
        _ = link.packets(for: Data(repeating: 9, count: 12))
        let out = link.receive(Data([0x03, 1]))
        XCTAssertEqual(out.replies.map { $0[2] }, [1, 2])
    }

    func testInOrderDeliveryAndAck() {
        let link = PacketLink(mtu: 23)
        let a = link.receive(Data([0, 0, 0, 0xAA]))
        XCTAssertEqual(a.delivered, Data([0xAA]))
        XCTAssertEqual(a.replies, [Data([0x02, 0])])

        let dup = link.receive(Data([0, 0, 0, 0xAA]))
        XCTAssertTrue(dup.delivered.isEmpty)
        XCTAssertEqual(dup.replies, [Data([0x02, 0])])

        let gap = link.receive(Data([0, 0, 40, 0xBB]))
        XCTAssertTrue(gap.delivered.isEmpty)
        XCTAssertEqual(gap.replies, [Data([0x03, 1])])
    }

    func testRoundTripBetweenTwoLinks() {
        let phone = PacketLink(mtu: 20), watch = PacketLink(mtu: 20)
        let message = Data((0..<100).map { UInt8($0) })
        var received = Data()
        for p in phone.packets(for: message) {
            let r = watch.receive(p)
            received.append(r.delivered)
            r.replies.forEach { _ = phone.receive($0) }
        }
        XCTAssertEqual(received, message)
        XCTAssertEqual(phone.pendingCount, 0)
    }
}

final class WireTests: XCTestCase {
    func testDigestMatchesJavaBase64UrlNoPad() {
        // SHA1("abc") = a9993e36 4706816a ba3e2571 7850c26c 9cd0d89d
        XCTAssertEqual(Wire.digest(Data("abc".utf8)), "qZk-NkcGgWq6PiVxeFDCbJzQ2J0")
    }

    func testFrameRoundTrip() throws {
        let connect = ConnectMessage(nodeId: "a1b2c3", displayName: "iPhone", androidId: 42, peerType: 2)
        let frame = Wire.frame(root: connect.rootMessage)

        var reader = FrameReader()
        let frames = reader.append(frame.prefix(3)) + reader.append(frame.dropFirst(3))
        XCTAssertEqual(frames.count, 1)

        let piece = try MessagePiece(frames[0])
        XCTAssertEqual(piece.digest, Wire.digest(piece.root))
        XCTAssertEqual(piece.index, 1)
        XCTAssertEqual(piece.total, 1)

        let root = try ProtoMessage(piece.root)
        let decoded = try ConnectMessage(XCTUnwrap(root.first(Wire.Root.connect)?.asData))
        XCTAssertEqual(decoded, connect)
    }
}
