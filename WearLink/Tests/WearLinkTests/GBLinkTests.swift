import XCTest
@testable import WearLink

final class GBLinkFramingTests: XCTestCase {
    func testChunkRoundTrip() throws {
        let message = Data((0..<1000).map { UInt8($0 & 0xFF) })
        var assembler = GBLinkAssembler()
        var result: Data?
        for chunk in GBLink.chunks(for: message, maxChunk: 20) {
            XCTAssertLessThanOrEqual(chunk.count, 20)
            if let m = try assembler.append(chunk) { result = m }
        }
        XCTAssertEqual(result, message)
    }

    func testSingleChunkHasBothFlags() {
        let chunks = GBLink.chunks(for: Data("{}".utf8), maxChunk: 180)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].first, 0x03)
    }

    func testRejectsContinuationWithoutStart() {
        var assembler = GBLinkAssembler()
        XCTAssertThrowsError(try assembler.append(Data([0x02, 1, 2]))) {
            XCTAssertEqual($0 as? GBLinkError, .chunkOutOfOrder)
        }
    }

    func testRejectsOversizedDeclaredLength() {
        var assembler = GBLinkAssembler()
        let huge = UInt32(GBLink.maxMessageBytes + 1).bigEndian
        var chunk = Data([0x01])
        withUnsafeBytes(of: huge) { chunk.append(contentsOf: $0) }
        XCTAssertThrowsError(try assembler.append(chunk)) {
            XCTAssertEqual($0 as? GBLinkError, .tooLarge)
        }
    }

    func testRejectsMoreBytesThanDeclared() {
        var assembler = GBLinkAssembler()
        XCTAssertThrowsError(try assembler.append(Data([0x03, 0, 0, 0, 1, 0xAA, 0xBB]))) {
            XCTAssertEqual($0 as? GBLinkError, .lengthMismatch)
        }
    }

    func testRecoversAfterError() throws {
        var assembler = GBLinkAssembler()
        _ = try? assembler.append(Data([0x02, 9]))
        let ok = try assembler.append(GBLink.chunks(for: Data("x".utf8), maxChunk: 50)[0])
        XCTAssertEqual(ok, Data("x".utf8))
    }
}

final class GBMessageTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
    let batch = "8A0F5C2E-3B1D-4C8E-9F7A-1D2C3B4A5E6F"

    func testSamplesRoundTrip() throws {
        let m = GBMessage.samples(batchId: batch, items: [
            HealthSample(kind: .heartRate, start: nowMs - 60_000, end: nowMs - 60_000, value: 71),
            HealthSample(kind: .steps, start: nowMs - 120_000, end: nowMs - 60_000, value: 140),
        ])
        XCTAssertEqual(try GBMessage.decode(m.encoded(), now: now), m)
    }

    func testRejectsImplausibleHeartRate() {
        let m = GBMessage.samples(batchId: batch, items: [
            HealthSample(kind: .heartRate, start: nowMs, end: nowMs, value: 900),
        ])
        XCTAssertThrowsError(try GBMessage.decode(m.encoded(), now: now))
    }

    func testRejectsNonFiniteValue() throws {
        let json = #"{"t":"samples","id":"\#(batch)","items":[{"k":"hr","start":1,"end":1,"v":1e999}]}"#
        XCTAssertThrowsError(try GBMessage.decode(Data(json.utf8), now: now))
    }

    func testRejectsFutureAndAncientSamples() {
        for start in [nowMs + 3_600_000, nowMs - 90 * 24 * 3_600_000] {
            let m = GBMessage.samples(batchId: batch, items: [
                HealthSample(kind: .steps, start: start, end: start, value: 1),
            ])
            XCTAssertThrowsError(try GBMessage.decode(m.encoded(), now: now))
        }
    }

    func testRejectsEndBeforeStart() {
        let m = GBMessage.samples(batchId: batch, items: [
            HealthSample(kind: .distance, start: nowMs, end: nowMs - 1, value: 5),
        ])
        XCTAssertThrowsError(try GBMessage.decode(m.encoded(), now: now))
    }

    func testRejectsBadBatchIdAndUnknownType() {
        XCTAssertThrowsError(try GBMessage.decode(Data(#"{"t":"ack","id":"../../x"}"#.utf8)))
        XCTAssertThrowsError(try GBMessage.decode(Data(#"{"t":"rm -rf"}"#.utf8)))
    }

    func testRejectsTooManySamples() {
        let items = (0...GBMessage.maxSamplesPerBatch).map { _ in
            HealthSample(kind: .steps, start: nowMs, end: nowMs, value: 1)
        }
        XCTAssertThrowsError(try GBMessage.decode(GBMessage.samples(batchId: batch, items: items).encoded(), now: now))
    }

    func testBatteryRange() throws {
        XCTAssertEqual(try GBMessage.decode(GBMessage.battery(percent: 55).encoded()), .battery(percent: 55))
        XCTAssertThrowsError(try GBMessage.decode(Data(#"{"t":"battery","pct":101}"#.utf8)))
    }
}
