import Foundation

/// Phone side of the Clockwork GATT service (Stage 3–4), independent of CoreBluetooth.
/// The GATT server feeds it reads, subscriptions and writes; it returns what to notify back.
///
/// Encryption is mandatory on this transport. Without a `LinkEncryption` the session stops
/// the moment the watch starts the handshake and never sends anything in plaintext beyond the
/// packet-level acks the stream requires.
public final class ClockworkSession {
    public struct Outgoing: Equatable {
        public var characteristic: UUID
        public var value: Data
    }

    public enum State: Equatable {
        case waiting
        case started(mtu: Int)
        case encrypting
        case established
        case stopped(String)
    }

    public private(set) var state: State = .waiting
    private let log: PairingLog
    private let encryption: LinkEncryption?
    private let userConfirmed: () -> Bool

    private var link: PacketLink?
    private var frames = FrameReader()
    private var pieces: [String: [Int: Data]] = [:]
    private var subscriptions = Set<UUID>()
    private var sawConfirmRead = false

    static let maxPieces = 64
    static let maxRootBytes = 1 << 20

    /// - Parameters:
    ///   - encryption: the UKEY2-backed channel, or nil (the session then stops at Stage 4a).
    ///   - userConfirmed: whether the user has approved pairing; drives the confirm characteristic.
    public init(log: PairingLog, encryption: LinkEncryption? = nil, userConfirmed: @escaping () -> Bool) {
        self.log = log
        self.encryption = encryption
        self.userConfirmed = userConfirmed
    }

    public var isStopped: Bool { if case .stopped = state { return true } else { return false } }

    // MARK: GATT events

    public func connected() {
        log.record(.clockworkConnect, .passed, "watch connected to the Clockwork service")
    }

    public func read(_ characteristic: UUID) -> Data? {
        switch characteristic {
        case Clockwork.pairingConfirm:
            let ok = userConfirmed()
            if !sawConfirmRead || ok {
                log.record(.clockworkConfirm, ok ? .passed : .started,
                           ok ? "pairing-confirm read → 01" : "pairing-confirm read → 00 (waiting for user approval)")
            }
            sawConfirmRead = true
            return Data([ok ? 1 : 0])
        case Clockwork.decommission:
            log.record(.clockworkConfirm, .passed, "decommission read → 00 (stay paired)")
            return Data([0])
        default:
            return nil
        }
    }

    public func subscribed(_ characteristic: UUID) {
        subscriptions.insert(characteristic)
        let names = [Clockwork.phoneToWatch: "data", Clockwork.reconnect: "reconnect", Clockwork.reset: "reset"]
        log.record(.clockworkStart, .started, "watch subscribed to \(names[characteristic] ?? characteristic.uuidString)")
    }

    public func disconnected() {
        if !isStopped { stop(.clockworkConnect, .failed, "watch disconnected") }
        link = nil
    }

    /// Returns notifications to send on `phoneToWatch`.
    public func write(_ characteristic: UUID, _ value: Data) -> [Outgoing] {
        guard !isStopped else { return [] }
        switch characteristic {
        case Clockwork.reset:
            return start(value)
        case Clockwork.watchToPhone:
            return receive(value)
        default:
            log.record(.clockworkStart, .failed, "unexpected write to \(characteristic.uuidString)")
            return []
        }
    }

    // MARK: Stage 3c

    private func start(_ value: Data) -> [Outgoing] {
        // The watch writes ascii(MTU - 3).
        guard let text = String(data: value, encoding: .ascii), let payload = Int(text),
              (20...514).contains(payload) else {
            stop(.clockworkStart, .failed, "reset write wasn't an ATT payload size (\(value.count) bytes)")
            return []
        }
        let missing = [Clockwork.phoneToWatch, Clockwork.reset].filter { !subscriptions.contains($0) }
        if !missing.isEmpty {
            log.record(.clockworkStart, .started, "stream started before data/reset subscriptions")
        }
        link = PacketLink(mtu: payload + 3)
        frames = FrameReader()
        pieces = [:]
        state = .started(mtu: payload + 3)
        log.record(.clockworkStart, .passed, "stream started, ATT payload \(payload)")
        return []
    }

    // MARK: Stage 4

    private func receive(_ packet: Data) -> [Outgoing] {
        guard let link else {
            stop(.packetStream, .failed, "data before the stream was started")
            return []
        }
        let incoming = link.receive(packet)
        var out = incoming.replies.map { Outgoing(characteristic: Clockwork.phoneToWatch, value: $0) }
        if !incoming.delivered.isEmpty, case .started = state {
            log.record(.packetStream, .passed, "receiving packets (\(incoming.delivered.count) bytes in order)")
        }
        for frame in frames.append(incoming.delivered) {
            out += handle(frame: frame)
            if isStopped { break }
        }
        return out
    }

    private func handle(frame: Data) -> [Outgoing] {
        var payload = frame
        if state == .established, let encryption {
            do {
                payload = try encryption.open(frame)
            } catch {
                stop(.encryption, .failed, "a frame failed authentication; dropping the connection")
                return []
            }
        }
        let piece: MessagePiece
        do {
            piece = try MessagePiece(payload)
        } catch {
            stop(.wireFrames, .failed, "frame isn't a MessagePiece (\(payload.count) bytes)")
            return []
        }
        guard let root = reassemble(piece) else { return [] }
        return handle(root: root)
    }

    /// Joins multi-piece roots by digest and checks the digest matches the reassembled bytes.
    private func reassemble(_ piece: MessagePiece) -> Data? {
        guard piece.total >= 1, piece.total <= Self.maxPieces, (1...piece.total).contains(piece.index) else {
            stop(.wireFrames, .failed, "piece \(piece.index)/\(piece.total) out of range")
            return nil
        }
        if piece.total == 1 {
            guard Wire.digest(piece.root) == piece.digest else {
                stop(.wireFrames, .failed, "digest mismatch on single-piece message")
                return nil
            }
            return piece.root
        }
        var parts = pieces[piece.digest, default: [:]]
        parts[piece.index] = piece.root
        let size = parts.values.reduce(0) { $0 + $1.count }
        guard size <= Self.maxRootBytes, pieces.count < 16 else {
            stop(.wireFrames, .failed, "multi-piece message too large")
            return nil
        }
        guard parts.count == piece.total else {
            pieces[piece.digest] = parts
            return nil
        }
        pieces[piece.digest] = nil
        let root = (1...piece.total).reduce(into: Data()) { $0.append(parts[$1]!) }
        guard Wire.digest(root) == piece.digest else {
            stop(.wireFrames, .failed, "digest mismatch after reassembling \(piece.total) pieces")
            return nil
        }
        return root
    }

    private func handle(root: Data) -> [Outgoing] {
        let message: ProtoMessage
        do {
            message = try ProtoMessage(root)
        } catch {
            stop(.wireFrames, .failed, "root message isn't valid protobuf")
            return []
        }
        let fields = message.fields.keys.sorted()
        log.record(.wireFrames, .passed, "root message with field(s) \(fields.map(String.init).joined(separator: ","))")

        if let crypto = message.first(Wire.Root.cryptoNegotiation)?.asData {
            return handleCrypto(crypto)
        }
        if message.first(Wire.Root.connect) != nil {
            guard state == .established else {
                stop(.connectHandshake, .failed, "watch sent Connect without encryption; refusing")
                return []
            }
            let connect = try? ConnectMessage(message.first(Wire.Root.connect)!.asData ?? Data())
            stop(.connectHandshake, .blocked,
                 "encrypted Connect received (peer type \(connect?.peerType.map(String.init) ?? "?"), wire version \(connect?.wireVersion.map(String.init) ?? "?")); data layer beyond Connect isn't implemented")
            return []
        }
        if message.first(Wire.Root.iosAuth) != nil {
            stop(.encryption, .failed, "watch asked for App Attest (L2CAP mode); Stage 1 must send a BLE role other than 1")
            return []
        }
        return []
    }

    // MARK: Stage 4a

    private func handleCrypto(_ bytes: Data) -> [Outgoing] {
        let negotiation = try? ProtoMessage(bytes)
        let handshake = negotiation?.first(1)?.asData ?? Data()
        let mode = negotiation?.first(4)?.asInt
        let modeName = mode == 2 ? "new pairing" : mode == 1 ? "resume" : "mode \(mode.map(String.init) ?? "?")"
        log.record(.encryption, .started, "watch started the encrypted channel (\(modeName), \(handshake.count)-byte handshake message)")

        guard let encryption else {
            stop(.encryption, .blocked,
                 "no LinkEncryption is installed, so the session stops here without replying. The UKEY2 responder (google/ukey2) is required; see HANDOFF.md. No plaintext fallback.")
            return []
        }
        state = .encrypting
        do {
            var out: [Outgoing] = []
            if let reply = try encryption.handleHandshakeMessage(handshake) {
                var inner = ProtoWriter()
                inner.bytes(1, reply)
                var root = ProtoWriter()
                root.bytes(Wire.Root.cryptoNegotiation, inner.data)
                out += send(root: root.data, sealed: false)
            }
            if encryption.isEstablished {
                state = .established
                log.record(.encryption, .passed, "encrypted channel established; user compares the code on the watch")
            }
            return out
        } catch {
            stop(.encryption, .failed, "handshake rejected; dropping the connection")
            return []
        }
    }

    private func send(root: Data, sealed: Bool) -> [Outgoing] {
        guard let link else { return [] }
        var piece = ProtoWriter()
        piece.bytes(1, root)
        piece.string(2, Wire.digest(root))
        piece.int32(3, 1)
        piece.int32(4, 1)
        var payload = piece.data
        if sealed {
            guard let encryption, let s = try? encryption.seal(payload) else { return [] }
            payload = s
        }
        return link.packets(for: Wire.lengthPrefixed(payload)).map { Outgoing(characteristic: Clockwork.phoneToWatch, value: $0) }
    }

    private func stop(_ stage: PairingStage, _ result: StageResult, _ detail: String) {
        state = .stopped(detail)
        log.record(stage, result, detail)
    }
}
