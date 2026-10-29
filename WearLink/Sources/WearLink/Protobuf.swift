import Foundation

/// Minimal protobuf wire-format writer/reader. Wear OS uses proto2 lite messages;
/// we only need varints, length-delimited fields and skipping unknowns.
public struct ProtoWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private mutating func tag(_ field: Int, _ wireType: UInt64) {
        varint(UInt64(field) << 3 | wireType)
    }

    public mutating func int32(_ field: Int, _ value: Int32) {
        tag(field, 0)
        // Negative int32 is sign-extended to 64 bits on the wire.
        varint(UInt64(bitPattern: Int64(value)))
    }

    public mutating func int64(_ field: Int, _ value: Int64) {
        tag(field, 0)
        varint(UInt64(bitPattern: value))
    }

    public mutating func bool(_ field: Int, _ value: Bool) {
        tag(field, 0)
        varint(value ? 1 : 0)
    }

    public mutating func bytes(_ field: Int, _ value: Data) {
        tag(field, 2)
        varint(UInt64(value.count))
        data.append(value)
    }

    public mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }
}

public enum ProtoError: Error, Equatable {
    case truncated
    case unsupportedWireType(UInt64)
}

public enum ProtoValue: Equatable {
    case varint(UInt64)
    case bytes(Data)
    case fixed32(UInt32)
    case fixed64(UInt64)

    public var asInt: Int64? {
        if case .varint(let v) = self { return Int64(bitPattern: v) }
        return nil
    }

    public var asData: Data? {
        if case .bytes(let d) = self { return d }
        return nil
    }

    public var asString: String? {
        asData.flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Parses a message into (field number → values in order). Good enough for the
/// handful of messages we inspect; unknown fields are kept rather than dropped.
public struct ProtoMessage {
    public private(set) var fields: [Int: [ProtoValue]] = [:]

    public init(_ data: Data) throws {
        var i = data.startIndex

        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < data.endIndex, shift < 64 else { throw ProtoError.truncated }
                let b = data[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
        }

        func take(_ n: Int) throws -> Data {
            guard n >= 0, data.distance(from: i, to: data.endIndex) >= n else { throw ProtoError.truncated }
            let chunk = data[i..<data.index(i, offsetBy: n)]
            i = data.index(i, offsetBy: n)
            return Data(chunk)
        }

        while i < data.endIndex {
            let key = try readVarint()
            let field = Int(key >> 3)
            let value: ProtoValue
            switch key & 7 {
            case 0: value = .varint(try readVarint())
            case 1: value = .fixed64(try take(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
            case 2: value = .bytes(try take(Int(try readVarint())))
            case 5: value = .fixed32(try take(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            case let t: throw ProtoError.unsupportedWireType(t)
            }
            fields[field, default: []].append(value)
        }
    }

    public func first(_ field: Int) -> ProtoValue? {
        fields[field]?.first
    }
}
