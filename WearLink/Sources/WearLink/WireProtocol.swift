import CryptoKit
import Foundation

/// Stage 4: Wear OS data-layer wire protocol carried over the PacketLink stream.
/// Source: GMS czah (framing), damq (MessagePiece), damp (RootMessage), dakh (Connect).
public enum Wire {
    /// RootMessage (damp) field numbers.
    public enum Root {
        public static let connect = 7
        public static let cryptoNegotiation = 17
        public static let iosAuth = 19
    }

    /// MessagePiece (damq) field numbers.
    enum Piece {
        static let root = 1
        static let digest = 2
        static let index = 3
        static let total = 4
        static let queueId = 5
    }

    /// base64url without padding of SHA-1(root), as computed by GMS cyvg.q.
    public static func digest(_ root: Data) -> String {
        Data(Insecure.SHA1.hash(data: root))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// One unencrypted frame carrying a whole RootMessage as a single piece.
    public static func frame(root: Data, queueId: Int32? = nil) -> Data {
        var piece = ProtoWriter()
        piece.bytes(Piece.root, root)
        piece.string(Piece.digest, digest(root))
        piece.int32(Piece.index, 1)
        piece.int32(Piece.total, 1)
        if let queueId { piece.int32(Piece.queueId, queueId) }
        return lengthPrefixed(piece.data)
    }

    public static func lengthPrefixed(_ payload: Data) -> Data {
        var n = UInt32(payload.count).bigEndian
        var out = Data(bytes: &n, count: 4)
        out.append(payload)
        return out
    }
}

/// Splits a byte stream back into length-prefixed frame payloads.
public struct FrameReader {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}

public struct MessagePiece: Equatable {
    public var root: Data
    public var digest: String
    public var index: Int
    public var total: Int

    public init(_ payload: Data) throws {
        let m = try ProtoMessage(payload)
        root = m.first(Wire.Piece.root)?.asData ?? Data()
        digest = m.first(Wire.Piece.digest)?.asString ?? ""
        index = Int(m.first(Wire.Piece.index)?.asInt ?? 1)
        total = Int(m.first(Wire.Piece.total)?.asInt ?? 1)
    }
}

/// The handshake message each side sends first (dakh, RootMessage field 7).
public struct ConnectMessage: Equatable {
    public var nodeId: String
    public var displayName: String
    public var androidId: Int64
    public var peerType: Int32?
    public var wireVersion: Int32?

    public init(nodeId: String, displayName: String, androidId: Int64,
                peerType: Int32? = nil, wireVersion: Int32? = nil) {
        self.nodeId = nodeId
        self.displayName = displayName
        self.androidId = androidId
        self.peerType = peerType
        self.wireVersion = wireVersion
    }

    public init(_ data: Data) throws {
        let m = try ProtoMessage(data)
        nodeId = m.first(1)?.asString ?? ""
        displayName = m.first(2)?.asString ?? ""
        androidId = m.first(3)?.asInt ?? 0
        peerType = m.first(4)?.asInt.map(Int32.init(truncatingIfNeeded:))
        wireVersion = m.first(5)?.asInt.map(Int32.init(truncatingIfNeeded:))
    }

    public var encoded: Data {
        var w = ProtoWriter()
        w.string(1, nodeId)
        w.string(2, displayName)
        w.int64(3, androidId)
        if let peerType { w.int32(4, peerType) }
        if let wireVersion { w.int32(5, wireVersion) }
        return w.data
    }

    /// Wrapped in a RootMessage, ready for `Wire.frame`.
    public var rootMessage: Data {
        var w = ProtoWriter()
        w.bytes(Wire.Root.connect, encoded)
        return w.data
    }
}
