import CoreBluetooth
import Foundation
import os
import UserNotifications
import WearLink

/// Connects to the Galaxy Bridge watch app over GBLink and keeps the connection alive,
/// including in the background (bluetooth-central mode + state restoration).
@MainActor
final class WatchLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case notPaired
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case connected
        /// iOS has an old bond for this watch that doesn't meet the security requirement.
        case needsRepair
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var watchBattery: Int?
    @Published private(set) var watchAppVersion: String?
    @Published private(set) var lastError: String?
    @Published private(set) var hasKnownWatch = UserDefaults.standard.string(forKey: WatchLink.knownPeripheralKey) != nil
    @Published private(set) var isPairing = false
    @Published private(set) var nearby: [NearbyWatch] = []
    @Published private(set) var watchStatus: WatchStatus?
    /// True while the watch is ringing for "Find my watch".
    @Published private(set) var findingWatch = false

    struct NearbyWatch: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
    }

    var onSamples: ((String, [HealthSample]) async -> Bool)?
    var onShutter: (() -> Void)?
    var onFindPhone: ((Bool) -> Void)?
    /// Called once the link is up so the app can push phone battery, weather and calendar.
    var onConnected: (() -> Void)?

    private static let restoreId = "nz.galaxybridge.watchlink"
    private static let knownPeripheralKey = "knownPeripheral"
    private let log = Logger(subsystem: "GalaxyBridge", category: "WatchLink")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var toPhone: CBCharacteristic?
    private var toWatch: CBCharacteristic?
    private var assembler = GBLinkAssembler()
    private var pendingWrites: [Data] = []
    private var writeInFlight = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreId])
    }

    func send(_ message: GBMessage) {
        guard let peripheral, let toWatch, status == .connected else { return }
        do {
            let max = min(peripheral.maximumWriteValueLength(for: .withResponse), 512)
            pendingWrites += GBLink.chunks(for: try message.encoded(), maxChunk: max)
            pumpWrites(peripheral, toWatch)
        } catch {
            log.error("encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func findWatch(_ on: Bool) {
        findingWatch = on && status == .connected
        send(.find(on: on))
    }

    /// Changes a watch setting. The UI updates optimistically; the watch replies with its status.
    func set(_ key: WatchSetting, _ value: Int) {
        guard key.range.contains(value) else { return }
        watchStatus?.settings[key.rawValue] = value
        send(.set(key: key, value: value))
    }

    /// Forget the paired watch, e.g. before pairing a different one.
    func forgetWatch() {
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralKey)
        knownPeripheralIgnored = nil
        hasKnownWatch = false
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        watchStatus = nil
        status = .notPaired
    }

    /// Lists nearby watches whose Galaxy Bridge app is in pairing mode. Nothing connects until
    /// the user picks one.
    func startPairing() {
        isPairing = true
        nearby = []
        lastError = nil
        guard central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: GBLink.service)],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopPairing() {
        isPairing = false
        nearby = []
        central.stopScan()
        if !hasKnownWatch { status = .notPaired } else { startSearching() }
    }

    func pair(with watch: NearbyWatch) {
        knownPeripheralIgnored = nil
        guard let p = central.retrievePeripherals(withIdentifiers: [watch.id]).first else { return }
        pairingCandidate = watch.id
        connect(p)
    }

    private var pairingCandidate: UUID?
    /// Set when the bond needs replacing; stops the reconnect loop until the user re-pairs.
    private var knownPeripheralIgnored: UUID?

    private func pumpWrites(_ p: CBPeripheral, _ c: CBCharacteristic) {
        guard !writeInFlight, !pendingWrites.isEmpty else { return }
        writeInFlight = true
        p.writeValue(pendingWrites.removeFirst(), for: c, type: .withResponse)
    }

    private var warnedLowBattery = false

    /// Posts one local notification when the watch drops to 15%, like a native companion app.
    private func updateBattery(_ pct: Int) {
        watchBattery = pct
        if pct > 20 { warnedLowBattery = false }
        guard pct <= 15, !warnedLowBattery, watchStatus?.charging != true else { return }
        warnedLowBattery = true
        let content = UNMutableNotificationContent()
        content.title = "Watch battery low"
        content.body = "Your Galaxy Watch is at \(pct)%."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "watchBattery", content: content, trigger: nil))
    }

    private var knownId: UUID? {
        UserDefaults.standard.string(forKey: Self.knownPeripheralKey).flatMap(UUID.init(uuidString:))
    }

    /// Reconnects only to the watch the user paired; never to other Galaxy Bridge watches.
    private func startSearching() {
        guard central.state == .poweredOn, !isPairing else { return }
        guard let id = knownId else {
            status = .notPaired
            return
        }
        status = .searching
        if let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
        } else {
            central.scanForPeripherals(withServices: [CBUUID(nsuuid: GBLink.service)])
        }
    }

    private func connect(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        status = .connecting
        central.connect(p)
    }

    private func reset() {
        toPhone = nil
        toWatch = nil
        assembler = GBLinkAssembler()
        pendingWrites.removeAll()
        writeInFlight = false
    }

    private func handle(_ data: Data) {
        let message: GBMessage
        do {
            message = try GBMessage.decode(data)
        } catch {
            // Don't echo peer content into logs; it is untrusted.
            log.error("rejected message from watch")
            lastError = "Ignored an invalid message from the watch"
            return
        }
        switch message {
        case let .hello(version, app):
            watchAppVersion = app
            if version != GBLink.protocolVersion {
                lastError = "Watch app version doesn't match; update both apps"
            }
            send(.hello(protocolVersion: GBLink.protocolVersion, appVersion: AppInfo.version))
            send(.getStatus)
        case let .samples(batchId, items):
            Task {
                // Ack only after HealthKit has stored the batch, so the watch keeps it otherwise.
                if await onSamples?(batchId, items) == true {
                    send(.ack(batchId: batchId))
                }
            }
        case .shutter:
            onShutter?()
        case let .battery(percent):
            updateBattery(percent)
        case let .status(s):
            watchStatus = s
            updateBattery(s.pct)
            watchAppVersion = s.app
        case let .find(on):
            onFindPhone?(on)
        case .ack, .set, .getStatus, .phoneBattery, .weather, .events:
            break // phone → watch only
        }
    }
}

extension WatchLink: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        MainActor.assumeIsolated {
            if let restored {
                peripheral = restored
                restored.delegate = self
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if isPairing {
                    startPairing()
                } else if let p = peripheral, p.state == .connected {
                    p.discoverServices([CBUUID(nsuuid: GBLink.service)])
                } else {
                    startSearching()
                }
            case .unauthorized: status = .unauthorized
            default: status = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advert = (advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data])?[CBUUID(nsuuid: GBLink.service)]
            .flatMap(GBAdvert.init)
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            if isPairing {
                guard let advert, advert.readyToPair, pairingCandidate == nil else { return }
                let name = advert.name.isEmpty ? "Galaxy Watch" : "Galaxy Watch (\(advert.name))"
                if let i = nearby.firstIndex(where: { $0.id == id }) {
                    nearby[i].rssi = rssi
                } else {
                    nearby.append(NearbyWatch(id: id, name: name, rssi: rssi))
                }
            } else if id == knownId {
                connect(peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            reset()
            peripheral.discoverServices([CBUUID(nsuuid: GBLink.service)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            lastError = error?.localizedDescription
            startSearching()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            reset()
            if pairingCandidate == peripheral.identifier {
                pairingCandidate = nil
                lastError = "Pairing didn't finish. Make sure the watch is in pairing mode and the codes match."
                startPairing()
                return
            }
            findingWatch = false
            guard peripheral.identifier == knownId, knownPeripheralIgnored != peripheral.identifier else { return }
            status = .connecting
            // A pending connect has no timeout, so iOS reconnects when the watch is back in range.
            central.connect(peripheral)
        }
    }
}

extension WatchLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(nsuuid: GBLink.service) }) else {
                lastError = "This watch isn't running Galaxy Bridge"
                central.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([CBUUID(nsuuid: GBLink.toPhone), CBUUID(nsuuid: GBLink.toWatch)],
                                               for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == CBUUID(nsuuid: GBLink.toPhone) { toPhone = c }
                if c.uuid == CBUUID(nsuuid: GBLink.toWatch) { toWatch = c }
            }
            guard let toPhone, toWatch != nil else {
                lastError = "Watch app is missing expected features"
                return
            }
            // The characteristic needs an encrypted link, so this triggers Bluetooth pairing.
            peripheral.setNotifyValue(true, for: toPhone)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                let code = (error as? CBATTError)?.code
                if code == .insufficientAuthentication || code == .insufficientEncryption,
                   pairingCandidate != peripheral.identifier {
                    // An old, weaker bond: reconnecting would just loop. The user has to re-pair.
                    status = .needsRepair
                    lastError = "Re-pair needed: in iPhone Settings → Bluetooth, tap ⓘ next to the watch → Forget This Device. Then tap Forget this watch here and pair again."
                    knownPeripheralIgnored = peripheral.identifier
                } else {
                    lastError = "Pairing didn't complete: \(error.localizedDescription)"
                }
                central.cancelPeripheralConnection(peripheral)
                return
            }
            status = .connected
            lastError = nil
            if pairingCandidate == peripheral.identifier {
                pairingCandidate = nil
                isPairing = false
                nearby = []
                central.stopScan()
            }
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralKey)
            hasKnownWatch = true
            send(.hello(protocolVersion: GBLink.protocolVersion, appVersion: AppInfo.version))
            onConnected?()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated {
            guard error == nil, let value else { return }
            do {
                if let message = try assembler.append(value) { handle(message) }
            } catch {
                log.error("dropped malformed chunk")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            writeInFlight = false
            if error != nil {
                pendingWrites.removeAll()
                return
            }
            if let toWatch { pumpWrites(peripheral, toWatch) }
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}
