import XCTest
@testable import WearLink

/// Drives ClockworkSession with the byte sequences a watch sends (per PROTOCOL_NOTES Stage 3–4).
/// This is a test fixture for the state machine, not a stand-in for pairing with hardware.
final class ClockworkSessionTests: XCTestCase {
    var log: PairingLog!
    var approved = false
    var session: ClockworkSession!
    let watchLink = PacketLink(mtu: 185)

    override func setUp() {
        log = PairingLog()
        approved = false
        session = ClockworkSession(log: log) { [unowned self] in self.approved }
    }

    private func startStream() {
        session.connected()
        XCTAssertEqual(session.read(Clockwork.pairingConfirm), Data([0]))
        approved = true
        XCTAssertEqual(session.read(Clockwork.pairingConfirm), Data([1]))
        XCTAssertEqual(session.read(Clockwork.decommission), Data([0]))
        for c in [Clockwork.phoneToWatch, Clockwork.reconnect, Clockwork.reset] { session.subscribed(c) }
        XCTAssertEqual(session.write(Clockwork.reset, Data("182".utf8)), [])
        XCTAssertEqual(session.state, .started(mtu: 185))
    }

    /// Sends a root message from the "watch" as one or more frames; returns the session's replies.
    @discardableResult
    private func watchSends(root: Data, pieces: Int = 1) -> [ClockworkSession.Outgoing] {
        let digest = Wire.digest(root)
        let size = (root.count + pieces - 1) / pieces
        var out: [ClockworkSession.Outgoing] = []
        for i in 0..<pieces {
            var p = ProtoWriter()
            p.bytes(1, root.subdata(in: (i * size)..<min(root.count, (i + 1) * size)))
            p.string(2, digest)
            p.int32(3, Int32(i + 1))
            p.int32(4, Int32(pieces))
            for packet in watchLink.packets(for: Wire.lengthPrefixed(p.data)) {
                out += session.write(Clockwork.watchToPhone, packet)
            }
        }
        return out
    }

    private func cryptoRoot(handshake: Data, mode: Int32) -> Data {
        var inner = ProtoWriter()
        inner.bytes(1, handshake)
        inner.int32(4, mode)
        var root = ProtoWriter()
        root.bytes(Wire.Root.cryptoNegotiation, inner.data)
        return root.data
    }

    func testStopsAtEncryptionWithoutReplyingInPlaintext() {
        startStream()
        let replies = watchSends(root: cryptoRoot(handshake: Data(repeating: 7, count: 140), mode: 2))
        // Only packet-level acks go back; nothing carrying a frame.
        XCTAssertTrue(replies.allSatisfy { $0.value.count == 2 && $0.value[0] == 0x02 })
        guard case .stopped = session.state else { return XCTFail("expected stop") }
        let last = log.events.last!
        XCTAssertEqual(last.stage, .encryption)
        XCTAssertEqual(last.result, .blocked)
        XCTAssertTrue(log.summary.contains("4-wire-frames"))
    }

    func testLogNeverContainsPayloadBytes() throws {
        startStream()
        let secret = Data("SECRET-HANDSHAKE".utf8)
        watchSends(root: cryptoRoot(handshake: secret, mode: 2))
        let json = String(decoding: try log.json(), as: UTF8.self)
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertFalse(json.contains(secret.base64EncodedString()))
    }

    func testReassemblesMultiPieceMessages() {
        startStream()
        watchSends(root: cryptoRoot(handshake: Data(repeating: 1, count: 600), mode: 2), pieces: 3)
        XCTAssertEqual(log.events.last?.stage, .encryption)
    }

    func testRejectsPlaintextConnect() {
        startStream()
        let connect = ConnectMessage(nodeId: "n", displayName: "Watch", androidId: 1, peerType: 3, wireVersion: 1)
        watchSends(root: connect.rootMessage)
        XCTAssertEqual(log.events.last?.stage, .connectHandshake)
        XCTAssertEqual(log.events.last?.result, .failed)
    }

    func testRejectsBadDigest() {
        startStream()
        var p = ProtoWriter()
        p.bytes(1, Data([0x38, 0x01]))
        p.string(2, "wrong")
        p.int32(3, 1)
        p.int32(4, 1)
        for packet in watchLink.packets(for: Wire.lengthPrefixed(p.data)) {
            _ = session.write(Clockwork.watchToPhone, packet)
        }
        XCTAssertEqual(log.events.last?.result, .failed)
        XCTAssertEqual(log.events.last?.stage, .wireFrames)
    }

    func testRejectsBadResetValue() {
        session.connected()
        _ = session.write(Clockwork.reset, Data("lots".utf8))
        XCTAssertEqual(log.events.last?.stage, .clockworkStart)
        XCTAssertEqual(log.events.last?.result, .failed)
    }

    func testDataBeforeStartFails() {
        _ = session.write(Clockwork.watchToPhone, Data([0, 0, 0, 1]))
        XCTAssertEqual(log.events.last?.stage, .packetStream)
        XCTAssertEqual(log.events.last?.result, .failed)
    }

    func testAppAttestRequestExplainsBleRole() {
        startStream()
        var root = ProtoWriter()
        root.bytes(Wire.Root.iosAuth, Data([1]))
        watchSends(root: root.data)
        XCTAssertTrue(log.events.last!.detail.contains("BLE role"))
    }

    func testPairingRecordRoundTripsThroughStore() throws {
        final class MemoryStore: SecretStore {
            var items: [String: Data] = [:]
            func save(_ data: Data, account: String) throws { items[account] = data }
            func load(account: String) throws -> Data? { items[account] }
            func delete(account: String) throws { items[account] = nil }
        }
        let store = MemoryStore()
        let records = PairingRecords(store: store)
        let r = PairingRecord(watchIdentifier: UUID(), session: Data([1, 2, 3]))
        try records.save(r)
        XCTAssertEqual(try records.load(), r)
        try records.forget()
        XCTAssertNil(try records.load())
    }
}
