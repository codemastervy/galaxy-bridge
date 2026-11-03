import Foundation

/// Stage-by-stage record of a pairing attempt. Events carry only sizes, field numbers and
/// state names, never payload bytes, keys or verification codes, so logs are safe to share.
public enum PairingStage: String, CaseIterable, Codable {
    /// Stage 1: find the watch's setup service, write capabilities, bond.
    case setupDiscovery = "1a-setup-discovery"
    case setupCapabilities = "1b-setup-capabilities"
    case setupBond = "1c-setup-bond"
    /// Stage 3: the watch connects to our Clockwork service.
    case clockworkConnect = "3a-clockwork-connect"
    case clockworkConfirm = "3b-clockwork-confirm-reads"
    case clockworkStart = "3c-clockwork-start"
    /// Stage 4: wire protocol over the packet stream.
    case packetStream = "4-packet-stream"
    case wireFrames = "4-wire-frames"
    /// Stage 4a: the watch starts the encrypted channel.
    case encryption = "4a-encryption"
    /// Stage 4b: Connect handshake (only valid after encryption).
    case connectHandshake = "4b-connect"
}

public enum StageResult: String, Codable {
    case started
    case passed
    case failed
    /// Can't continue for a known reason (e.g. a missing component), not a malfunction.
    case blocked
}

public struct PairingEvent: Codable, Equatable {
    public var time: Date
    public var stage: PairingStage
    public var result: StageResult
    public var detail: String

    public init(stage: PairingStage, result: StageResult, detail: String, time: Date = Date()) {
        self.time = time
        self.stage = stage
        self.result = result
        self.detail = detail
    }

    public var line: String {
        let mark: String
        switch result {
        case .started: mark = "…"
        case .passed: mark = "✓"
        case .failed: mark = "✗"
        case .blocked: mark = "■"
        }
        return "\(mark) [\(stage.rawValue)] \(result.rawValue): \(detail)"
    }
}

public final class PairingLog {
    public private(set) var events: [PairingEvent] = []
    public var onEvent: ((PairingEvent) -> Void)?

    public init() {}

    public func record(_ stage: PairingStage, _ result: StageResult, _ detail: String) {
        let e = PairingEvent(stage: stage, result: result, detail: detail)
        events.append(e)
        onEvent?(e)
    }

    /// The furthest stage that passed, and the first failure/block after it, for a summary.
    public var summary: String {
        let passed = events.filter { $0.result == .passed }.map(\.stage)
        let furthest = PairingStage.allCases.last { passed.contains($0) }
        let stop = events.last { $0.result == .failed || $0.result == .blocked }
        var s = "Furthest stage passed: \(furthest?.rawValue ?? "none")"
        if let stop { s += "\nStopped at: \(stop.stage.rawValue) (\(stop.result.rawValue)) — \(stop.detail)" }
        return s
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return try e.encode(events)
    }
}
