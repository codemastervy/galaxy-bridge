import Foundation

/// Stage 1: the watch's setup-time BLE pairing service (watch is the peripheral).
/// Source: SecClockworkSetupWizard PairingGattServer / CtkdEnabledPairingManager.
public enum SetupPairing {
    public static let service = UUID(uuidString: "1c81447b-f48d-4d17-a606-3ff36527045a")!
    /// read + notify: bond status
    public static let pairingCharacteristic = UUID(uuidString: "6fcfb474-ce57-48ff-a4ce-b43767d6d04a")!
    /// encrypted write: WearPairingCapabilities (writing it triggers BLE bonding)
    public static let capabilitiesCharacteristic = UUID(uuidString: "b2ae0493-d87f-475c-b656-5840e0a13fc8")!

    public enum CompanionOS: Int32 {
        case unknown = 0
        case iOS = 1
        case android = 2
    }

    /// Value stored by the watch in Settings.Global `companion_ble_role`.
    /// Role 1 makes the watch use the L2CAP transport, which demands Apple App Attest from
    /// one of Google's own app IDs. Any other value selects the GATT Clockwork transport.
    public static let gattTransportBleRole: Int32 = 2

    /// uint16 little-endian length followed by the protobuf message.
    public static func capabilitiesPayload(os: CompanionOS = .iOS,
                                           bleRole: Int32 = gattTransportBleRole) -> Data {
        var proto = ProtoWriter()
        proto.int32(1, os.rawValue)
        proto.int32(2, bleRole)
        let body = proto.data
        var out = Data([UInt8(body.count & 0xFF), UInt8(body.count >> 8)])
        out.append(body)
        return out
    }
}
