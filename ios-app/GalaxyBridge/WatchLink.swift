import CoreBluetooth
import Foundation
import os
import WearLink

/// Connects to the Galaxy Bridge watch app over GBLink and keeps the connection alive,
/// including in the background (bluetooth-central mode + state restoration).
@MainActor
final class WatchLink: NSObject, ObservableObject {
    enum Status: Equatable {
        case bluetoothOff
        case unauthorized
        case searching
        case connecting
        case connected
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var watchBattery: Int?
    @Published private(set) var watchAppVersion: String?
    @Published private(set) var lastError: String?

    var onSamples: ((String, [HealthSample]) async -> Bool)?
    var onShutter: (() -> Void)?

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
            let max = peripheral.maximumWriteValueLength(for: .withResponse)
            pendingWrites += GBLink.chunks(for: try message.encoded(), maxChunk: max)
            pumpWrites(peripheral, toWatch)
        } catch {
            log.error("encode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Forget the paired watch, e.g. before pairing a different one.
    func forgetWatch() {
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralKey)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    private func pumpWrites(_ p: CBPeripheral, _ c: CBCharacteristic) {
        guard !writeInFlight, !pendingWrites.isEmpty else { return }
        writeInFlight = true
        p.writeValue(pendingWrites.removeFirst(), for: c, type: .withResponse)
    }

    private func startSearching() {
        guard central.state == .poweredOn else { return }
        status = .searching
        if let saved = UserDefaults.standard.string(forKey: Self.knownPeripheralKey),
           let id = UUID(uuidString: saved),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known)
            return
        }
        if let connected = central.retrieveConnectedPeripherals(withServices: [CBUUID(nsuuid: GBLink.service)]).first {
            connect(connected)
            return
        }
        central.scanForPeripherals(withServices: [CBUUID(nsuuid: GBLink.service)])
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
            watchBattery = percent
        case .ack:
            break
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
                if let p = peripheral, p.state == .connected {
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
        MainActor.assumeIsolated { connect(peripheral) }
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
                lastError = "Pairing didn't complete: \(error.localizedDescription)"
                return
            }
            status = .connected
            lastError = nil
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.knownPeripheralKey)
            send(.hello(protocolVersion: GBLink.protocolVersion, appVersion: AppInfo.version))
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
