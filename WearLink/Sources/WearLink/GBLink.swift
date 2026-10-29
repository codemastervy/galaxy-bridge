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

/// Watch info and settings, as reported by the watch app (see WatchSettings.kt).
public struct WatchStatus: Codable, Equatable {
    public var model: String
    public var os: String
    public var app: String
    public var pct: Int
    public var charging: Bool
    public var freeMB: Int
    public var totalMB: Int
    public var settings: [String: Int]
    public var perms: Permissions
    /// Watch clock minus phone clock in seconds, measured when the status arrived.
    public var clockOffset: TimeInterval = 0

    public struct Permissions: Codable, Equatable {
        public var system: Bool
        public var dnd: Bool
        /// The watch is subscribed to iPhone notifications (ANCS).
        public var ancs: Bool
    }
}

/// Settings keys the watch accepts, with their allowed ranges. Mirrors WatchSettings.kt.
public enum WatchSetting: String, CaseIterable {
    case notifications = "notify"
    case calls = "calls"
    case clearOnIPhone = "clearSync"
    case music = "music"
    case syncHeart = "sync.hr"
    case syncSteps = "sync.steps"
    case syncEnergy = "sync.kcal"
    case syncDistance = "sync.dist"
    case brightness = "brightness"
    case screenTimeout = "timeout"
    case doNotDisturb = "dnd"

    public var range: ClosedRange<Int> {
        switch self {
        case .brightness: return 1...255
        case .screenTimeout: return 5...600
        default: return 0...1
        }
    }
}

public struct CalendarItem: Codable, Equatable {
    public var title: String
    /// Milliseconds since the Unix epoch.
    public var start: Int64
    public var end: Int64
    public var allDay: Bool

    public init(title: String, start: Int64, end: Int64, allDay: Bool) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
    }
}

public struct WeatherReport: Equatable {
    public var place: String
    public var tempC: Double
    public var highC: Double
    public var lowC: Double
    /// WMO weather interpretation code.
    public var code: Int
    public var at: Int64

    public init(place: String, tempC: Double, highC: Double, lowC: Double, code: Int, at: Int64) {
        self.place = place
        self.tempC = tempC
        self.highC = highC
        self.lowC = lowC
        self.code = code
        self.at = at
    }
}

public enum GBMessage: Equatable {
    // Both directions
    case hello(protocolVersion: Int, appVersion: String)
    /// Watch → phone: find my phone. Phone → watch: find my watch.
    case find(on: Bool)
    // Watch → phone
    case samples(batchId: String, items: [HealthSample])
    case shutter
    case battery(percent: Int)
    case status(WatchStatus)
    // Phone → watch
    case ack(batchId: String)
    case set(key: WatchSetting, value: Int)
    case getStatus
    case phoneBattery(percent: Int, charging: Bool)
    case weather(WeatherReport)
    case events([CalendarItem])

    private struct Envelope: Codable {
        var t: String
        var v: Int?
        var app: String?
        var id: String?
        var items: [HealthSample]?
        var pct: Int?
        var on: Bool?
        var key: String?
        var value: Int?
        var charging: Bool?
        var place: String?
        var temp: Double?
        var hi: Double?
        var lo: Double?
        var code: Int?
        var at: Int64?
        var events: [CalendarItem]?
        // status
        var model: String?
        var os: String?
        var freeMB: Int?
        var totalMB: Int?
        var settings: [String: Int]?
        var perms: WatchStatus.Permissions?
        /// Watch clock when a samples batch was sent, in epoch ms.
        var now: Int64?
        var time: Int64?
        var tz: String?

        init(t: String) { self.t = t }
    }

    public static let maxSamplesPerBatch = 500
    public static let maxEvents = 20
    static let maxClockSkew: TimeInterval = 5 * 60
    static let maxSampleAge: TimeInterval = 30 * 24 * 3600

    public func encoded() throws -> Data {
        var e: Envelope
        switch self {
        case let .hello(v, app):
            e = Envelope(t: "hello"); e.v = v; e.app = app
            // Lets the watch notice if its clock or time zone is wrong.
            e.time = Int64(Date().timeIntervalSince1970 * 1000)
            e.tz = TimeZone.current.identifier
        case let .find(on): e = Envelope(t: "find"); e.on = on
        case let .samples(id, items): e = Envelope(t: "samples"); e.id = id; e.items = items
        case .shutter: e = Envelope(t: "shutter")
        case let .battery(pct): e = Envelope(t: "battery"); e.pct = pct
        case let .status(s):
            e = Envelope(t: "status")
            e.model = s.model; e.os = s.os; e.app = s.app; e.pct = s.pct; e.charging = s.charging
            e.freeMB = s.freeMB; e.totalMB = s.totalMB; e.settings = s.settings; e.perms = s.perms
        case let .ack(id): e = Envelope(t: "ack"); e.id = id
        case let .set(key, value): e = Envelope(t: "set"); e.key = key.rawValue; e.value = value
        case .getStatus: e = Envelope(t: "status")
        case let .phoneBattery(pct, charging): e = Envelope(t: "phone"); e.pct = pct; e.charging = charging
        case let .weather(w):
            e = Envelope(t: "weather")
            e.place = w.place; e.temp = w.tempC; e.hi = w.highC; e.lo = w.lowC; e.code = w.code; e.at = w.at
        case let .events(items):
            // The watch reads the list from "items" objects; reuse that key.
            return try JSONSerialization.data(withJSONObject: [
                "t": "events",
                "items": items.map { ["title": $0.title, "start": $0.start, "end": $0.end, "allDay": $0.allDay] as [String: Any] },
            ])
        }
        return try JSONEncoder().encode(e)
    }

    public enum Invalid: Error, Equatable {
        case unknownType(String)
        case missingField(String)
        case outOfRange(String)
    }

    /// Strict decode of what the watch sends. Unknown types, missing fields and bad values are
    /// rejected. In a samples batch, implausible samples are dropped individually (and never
    /// reach HealthKit) so the rest of the batch can still be stored and acknowledged.
    public static func decode(_ data: Data, now: Date = Date()) throws -> GBMessage {
        guard data.count <= GBLink.maxMessageBytes else { throw Invalid.outOfRange("size") }
        let e = try JSONDecoder().decode(Envelope.self, from: data)
        switch e.t {
        case "hello":
            guard let v = e.v else { throw Invalid.missingField("v") }
            let app = e.app ?? ""
            guard app.count <= 32 else { throw Invalid.outOfRange("app") }
            return .hello(protocolVersion: v, appVersion: app)
        case "find":
            return .find(on: e.on ?? false)
        case "samples":
            guard let id = e.id, isBatchId(id) else { throw Invalid.missingField("id") }
            guard let items = e.items else { throw Invalid.missingField("items") }
            guard items.count <= maxSamplesPerBatch else { throw Invalid.outOfRange("items") }
            return .samples(batchId: id, items: corrected(items, watchNow: e.now, now: now).filter { isPlausible($0, now: now) })
        case "ack":
            guard let id = e.id, isBatchId(id) else { throw Invalid.missingField("id") }
            return .ack(batchId: id)
        case "shutter":
            return .shutter
        case "battery":
            guard let pct = e.pct else { throw Invalid.missingField("pct") }
            guard (0...100).contains(pct) else { throw Invalid.outOfRange("pct") }
            return .battery(percent: pct)
        case "status":
            guard let model = e.model, let os = e.os, let app = e.app, let pct = e.pct,
                  let settings = e.settings, let perms = e.perms else { throw Invalid.missingField("status") }
            guard (0...100).contains(pct), model.count <= 32, os.count <= 32, app.count <= 32,
                  settings.count <= 32 else { throw Invalid.outOfRange("status") }
            // Keep only known keys with in-range values.
            var known: [String: Int] = [:]
            for (k, v) in settings {
                if let key = WatchSetting(rawValue: k), key.range.contains(v) { known[k] = v }
            }
            var status = WatchStatus(model: model, os: os, app: app, pct: pct, charging: e.charging ?? false,
                                     freeMB: max(0, e.freeMB ?? 0), totalMB: max(0, e.totalMB ?? 0),
                                     settings: known, perms: perms)
            if let t = e.time { status.clockOffset = Double(t) / 1000 - now.timeIntervalSince1970 }
            return .status(status)
        default:
            throw Invalid.unknownType(String(e.t.prefix(32)))
        }
    }

    static let maxUncorrectedSkew: Int64 = 2 * 60 * 1000

    /// If the watch's clock is off by more than two minutes, shift its timestamps onto the
    /// phone's clock. Batches are sent right after they're read, so transit time is negligible.
    static func corrected(_ items: [HealthSample], watchNow: Int64?, now: Date) -> [HealthSample] {
        guard let watchNow else { return items }
        let skew = Int64(now.timeIntervalSince1970 * 1000) - watchNow
        guard abs(skew) > maxUncorrectedSkew else { return items }
        return items.map {
            var s = $0
            s.start += skew
            s.end += skew
            return s
        }
    }

    public static func isPlausible(_ s: HealthSample, now: Date = Date()) -> Bool {
        let latest = now.addingTimeInterval(maxClockSkew)
        let earliest = now.addingTimeInterval(-maxSampleAge)
        return s.value.isFinite && s.kind.validRange.contains(s.value)
            && s.end >= s.start && s.startDate >= earliest && s.endDate <= latest
    }

    static func isBatchId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}

/// Scan-response service data the watch app advertises under `GBLink.service`:
///   [version = 1, flags, name (UTF-8, ≤ 10 bytes)]     flags bit0 = ready to pair
/// Lets the iPhone list nearby watches and only offer ones the user has put in pairing mode.
public struct GBAdvert: Equatable {
    public var readyToPair: Bool
    public var name: String

    public static let maxNameBytes = 10

    public init(readyToPair: Bool, name: String) {
        self.readyToPair = readyToPair
        self.name = name
    }

    public init?(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 1, bytes.count <= 2 + Self.maxNameBytes else { return nil }
        readyToPair = bytes[1] & 0x01 != 0
        // Untrusted text from the air: decode leniently and keep only printable characters.
        name = String(decoding: bytes[2...], as: UTF8.self)
            .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }
    }
}
