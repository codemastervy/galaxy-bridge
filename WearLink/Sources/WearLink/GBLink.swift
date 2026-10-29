import Foundation

/// GBLink: the project's own channel between the Galaxy Bridge watch app and iPhone app.
/// It runs on a watch that is already set up, independent of the Wear OS companion protocol.
///
/// Transport: the watch is a GATT peripheral; both characteristics require an encrypted,
/// bonded link (Bluetooth LE Secure Connections), so confidentiality and integrity come
/// from the OS Bluetooth stack rather than custom cryptography.
///
/// Framing: each message is UTF-8 JSON, sent as one or more chunks.
///   chunk = [flags] + bytes          flags bit0 = first chunk, bit1 = last chunk
///   the first chunk's bytes start with a uint32 big-endian total length
/// The Kotlin side lives in watch-app/ and must stay in step with this file.
public enum GBLink {
    public static let service = UUID(uuidString: "3ed75be1-1098-4239-b80a-a7763a2d4855")!
    /// Watch → phone, notify.
    public static let toPhone = UUID(uuidString: "7ff2dd95-3428-49e6-83fb-37de84360199")!
    /// Phone → watch, write with response.
    public static let toWatch = UUID(uuidString: "e8038e21-fbf8-4a81-91a6-81a1bf361465")!

    public static let protocolVersion = 1
    public static let maxMessageBytes = 64 * 1024

    static let firstFlag: UInt8 = 0x01
    static let lastFlag: UInt8 = 0x02

    public static func chunks(for message: Data, maxChunk: Int) -> [Data] {
        precondition(maxChunk > 5, "ATT payload too small")
        var n = UInt32(message.count).bigEndian
        var body = Data(bytes: &n, count: 4)
        body.append(message)

        var out: [Data] = []
        var offset = 0
        let room = maxChunk - 1
        while offset < body.count {
            let end = min(offset + room, body.count)
            var flags: UInt8 = 0
            if offset == 0 { flags |= firstFlag }
            if end == body.count { flags |= lastFlag }
            out.append(Data([flags]) + body[offset..<end])
            offset = end
        }
        return out
    }
}

public enum GBLinkError: Error, Equatable {
    case chunkOutOfOrder
    case tooLarge
    case lengthMismatch
}

/// Reassembles chunks into messages, rejecting anything malformed or oversized.
public struct GBLinkAssembler {
    private var buffer: Data?
    private var expected = 0

    public init() {}

    /// Returns a complete message when `chunk` finishes one. On error the partial
    /// message is discarded and the caller should treat the peer as misbehaving.
    public mutating func append(_ chunk: Data) throws -> Data? {
        guard let flags = chunk.first else { throw GBLinkError.chunkOutOfOrder }
        let bytes = chunk.dropFirst()

        if flags & GBLink.firstFlag != 0 {
            guard bytes.count >= 4 else { buffer = nil; throw GBLinkError.lengthMismatch }
            expected = bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard expected <= GBLink.maxMessageBytes else { buffer = nil; throw GBLinkError.tooLarge }
            buffer = Data(bytes.dropFirst(4))
        } else {
            guard buffer != nil else { throw GBLinkError.chunkOutOfOrder }
            buffer!.append(bytes)
        }

        guard let current = buffer else { return nil }
        if current.count > expected {
            buffer = nil
            throw GBLinkError.lengthMismatch
        }
        guard flags & GBLink.lastFlag != 0 else { return nil }
        buffer = nil
        guard current.count == expected else { throw GBLinkError.lengthMismatch }
        return current
    }
}

// MARK: Messages

public enum SampleKind: String, Codable, CaseIterable {
    case heartRate = "hr"        // beats per minute, instantaneous (start == end)
    case steps = "steps"         // count over [start, end]
    case activeEnergy = "kcal"   // kilocalories over [start, end]
    case distance = "dist"       // metres over [start, end]

    /// Physically plausible bounds per sample, used to reject corrupt or hostile input.
    var validRange: ClosedRange<Double> {
        switch self {
        case .heartRate: return 25...250
        case .steps: return 0...50_000
        case .activeEnergy: return 0...5_000
        case .distance: return 0...100_000
        }
    }
}

public struct HealthSample: Codable, Equatable {
    public var kind: SampleKind
    /// Milliseconds since the Unix epoch.
    public var start: Int64
    public var end: Int64
    public var value: Double

    enum CodingKeys: String, CodingKey {
        case kind = "k", start, end, value = "v"
    }

    public init(kind: SampleKind, start: Int64, end: Int64, value: Double) {
        self.kind = kind
        self.start = start
        self.end = end
        self.value = value
    }

    public var startDate: Date { Date(timeIntervalSince1970: Double(start) / 1000) }
    public var endDate: Date { Date(timeIntervalSince1970: Double(end) / 1000) }
}

public enum GBMessage: Equatable {
    case hello(protocolVersion: Int, appVersion: String)
    case samples(batchId: String, items: [HealthSample])
    case ack(batchId: String)
    case shutter
    case battery(percent: Int)

    private struct Envelope: Codable {
        var t: String
        var v: Int?
        var app: String?
        var id: String?
        var items: [HealthSample]?
        var pct: Int?
    }

    public static let maxSamplesPerBatch = 500
    static let maxClockSkew: TimeInterval = 5 * 60
    static let maxSampleAge: TimeInterval = 30 * 24 * 3600

    public func encoded() throws -> Data {
        let e: Envelope
        switch self {
        case let .hello(v, app): e = Envelope(t: "hello", v: v, app: app)
        case let .samples(id, items): e = Envelope(t: "samples", id: id, items: items)
        case let .ack(id): e = Envelope(t: "ack", id: id)
        case .shutter: e = Envelope(t: "shutter")
        case let .battery(pct): e = Envelope(t: "battery", pct: pct)
        }
        return try JSONEncoder().encode(e)
    }

    public enum Invalid: Error, Equatable {
        case unknownType(String)
        case missingField(String)
        case outOfRange(String)
    }

    /// Strict decode: unknown types, missing fields and implausible values are rejected
    /// instead of being coerced, so nothing malformed reaches HealthKit.
    public static func decode(_ data: Data, now: Date = Date()) throws -> GBMessage {
        guard data.count <= GBLink.maxMessageBytes else { throw Invalid.outOfRange("size") }
        let e = try JSONDecoder().decode(Envelope.self, from: data)
        switch e.t {
        case "hello":
            guard let v = e.v else { throw Invalid.missingField("v") }
            let app = e.app ?? ""
            guard app.count <= 32 else { throw Invalid.outOfRange("app") }
            return .hello(protocolVersion: v, appVersion: app)
        case "samples":
            guard let id = e.id, isBatchId(id) else { throw Invalid.missingField("id") }
            guard let items = e.items else { throw Invalid.missingField("items") }
            guard items.count <= maxSamplesPerBatch else { throw Invalid.outOfRange("items") }
            let latest = now.addingTimeInterval(maxClockSkew)
            let earliest = now.addingTimeInterval(-maxSampleAge)
            for s in items {
                guard s.value.isFinite, s.kind.validRange.contains(s.value) else {
                    throw Invalid.outOfRange(s.kind.rawValue)
                }
                guard s.end >= s.start, s.startDate >= earliest, s.endDate <= latest else {
                    throw Invalid.outOfRange("time")
                }
            }
            return .samples(batchId: id, items: items)
        case "ack":
            guard let id = e.id, isBatchId(id) else { throw Invalid.missingField("id") }
            return .ack(batchId: id)
        case "shutter":
            return .shutter
        case "battery":
            guard let pct = e.pct else { throw Invalid.missingField("pct") }
            guard (0...100).contains(pct) else { throw Invalid.outOfRange("pct") }
            return .battery(percent: pct)
        default:
            throw Invalid.unknownType(String(e.t.prefix(32)))
        }
    }

    static func isBatchId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}
