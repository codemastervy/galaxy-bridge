import Foundation

/// Stage 3: GATT service the iPhone app hosts (iPhone = peripheral, watch = central).
/// Source: GMS wearable.node.ble (czjj UUID table, czjo slot mapping, czjr connect sequence).
public enum Clockwork {
    public static let service = UUID(uuidString: "2feb2e7e-d3a1-491f-961a-ae85b5920549")!

    /// Watch writes framed packets here.
    public static let watchToPhone = UUID(uuidString: "07b18b65-9076-4050-a754-21adc1e12422")!
    /// Phone notifies framed packets here.
    public static let phoneToWatch = UUID(uuidString: "280adb07-4033-40c4-b2c0-8a3c75df4165")!
    /// Notify to ask the watch to reconnect.
    public static let reconnect = UUID(uuidString: "ffeddd90-74bc-11e4-82f8-0800200c9a66")!
    /// Watch subscribes and writes ascii(MTU - 3) to start a session; phone notifies to reset.
    public static let reset = UUID(uuidString: "0eb6f3c9-df9c-4679-bcae-06ba51f7920f")!
    /// Watch reads; must return 0x01 once the user has confirmed pairing.
    public static let pairingConfirm = UUID(uuidString: "1699e0b2-357c-4c98-8007-7a50b5b3e771")!
    /// Watch reads; 0x00 = stay paired, 0x01 = decommission (factory-reset) the watch.
    public static let decommission = UUID(uuidString: "65bbb4b0-c1c7-11e4-8dfc-aa07a5b093db")!
}

/// Services iOS itself exposes to a bonded accessory; the watch's own ANCS/AMS clients use them.
public enum AppleAccessoryServices {
    public static let ancs = UUID(uuidString: "7905f431-b5ce-4e99-a40f-4b1e122d00d0")!
    public static let ams = UUID(uuidString: "89D3502B-0F36-433A-8EF4-C502AD55F8DC")!
    public static let currentTime = UUID(uuidString: "00001805-0000-1000-8000-00805f9b34fb")!
}
