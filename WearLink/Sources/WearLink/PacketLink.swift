import Foundation

/// Reliable byte stream over the two Clockwork data characteristics.
/// Mirrors GMS DataSender (czjn), BleOutputStream (cziz) and DataReceiver (czjk):
///
///   data packet: [flags, ackId, seq] + chunk     (flags bit 1 set => bytes 0-1 are an ack)
///   ack packet:  [0x02, id]  cumulative ack through id
///                [0x03, id]  nack: resend everything after id
///
/// Pure state machine: callers feed it bytes and send whatever it returns, so it can be
/// unit tested without Bluetooth.
public final class PacketLink {
    public let maxChunk: Int
    public let window: Int

    private var nextSeq: UInt8 = 0
    private var unacked: [Data] = []        // oldest first, each a full packet
    private var expectedSeq: UInt8 = 0
    private var reportedLoss = false

    /// - Parameter mtu: ATT MTU negotiated with the watch.
    public init(mtu: Int, window: Int = 16) {
        // The watch uses (MTU - 3) as the characteristic payload and the packet header is 3 bytes.
        maxChunk = max(1, mtu - 3 - 3)
        self.window = window
    }

    public var canSend: Bool { unacked.count < window }
    public var pendingCount: Int { unacked.count }

    /// Splits `bytes` into packets to write. Callers must respect `canSend`/window.
    public func packets(for bytes: Data) -> [Data] {
        var out: [Data] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = bytes.index(offset, offsetBy: maxChunk, limitedBy: bytes.endIndex) ?? bytes.endIndex
            var packet = Data([0, 0, nextSeq])
            packet.append(bytes[offset..<end])
            unacked.append(packet)
            out.append(packet)
            nextSeq &+= 1
            offset = end
        }
        return out
    }

    public struct Incoming {
        /// In-order payload bytes delivered to the stream.
        public var delivered = Data()
        /// Packets to write back (acks or retransmissions).
        public var replies: [Data] = []
    }

    public func receive(_ packet: Data) -> Incoming {
        var result = Incoming()
        let bytes = [UInt8](packet)
        guard bytes.count >= 2 else { return result }

        if bytes[0] & 0x02 != 0 {
            result.replies += handleAck(id: bytes[1], positive: bytes[0] & 0x01 == 0)
        }

        guard bytes.count >= 3 else { return result }
        let seq = bytes[2]
        if seq == expectedSeq {
            result.delivered.append(contentsOf: bytes[3...])
            result.replies.append(Data([0x02, seq]))
            expectedSeq &+= 1
            reportedLoss = false
        } else {
            let behind = Int(expectedSeq &- seq)
            if behind <= window {
                // Duplicate of something we already have: re-ack the last good packet.
                result.replies.append(Data([0x02, expectedSeq &- 1]))
            } else if !reportedLoss {
                result.replies.append(Data([0x03, expectedSeq]))
                reportedLoss = true
            }
        }
        return result
    }

    /// Everything still unacknowledged, for an ack-timeout retransmit.
    public func retransmitAll() -> [Data] { unacked }

    private func handleAck(id: UInt8, positive: Bool) -> [Data] {
        guard let first = unacked.first?[2] else { return [] }
        let index = Int(id &- first)
        guard index < unacked.count else { return [] }  // redundant ack
        if positive {
            unacked.removeFirst(index + 1)
            return []
        }
        unacked.removeFirst(index)
        return unacked
    }
}
