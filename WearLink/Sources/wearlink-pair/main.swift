import CoreBluetooth
import Foundation
import WearLink

// wearlink-pair: runs each stage of Wear OS iPhone-mode pairing against a real watch from a Mac
// and reports exactly where it succeeds or stops. Logs contain no payloads or secrets.

let usage = """
usage: wearlink-pair <command> [options]

  scan  [--seconds N]                 Stage 1a: list nearby watches; marks ones on the setup screen
  setup <identifier|name> [--json F]  Stage 1a–1c: write iPhone capabilities to a watch on its
                                      setup screen and bond (macOS shows the pairing prompt)
  serve [--approve] [--json F]        Stage 3–4: host the Clockwork service the watch connects to
                                      after Stage 1, and run the stream until it stops
  status                              Show the saved pairing record (Keychain), without secrets
  forget                              Delete the saved pairing record

Stages stop at 4a (encryption) until a LinkEncryption implementation is installed; see HANDOFF.md.
"""

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let log = PairingLog()
log.onEvent = { print($0.line); fflush(stdout) }

func finish(_ code: Int32) -> Never {
    print("\n" + log.summary)
    if let path = option("--json"), let data = try? log.json() {
        try? data.write(to: URL(fileURLWithPath: path))
        print("Diagnostics written to \(path)")
    }
    exit(code)
}

// MARK: Stage 1 — watch is the peripheral

final class SetupRunner: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let target: String?
    let scanSeconds: Double
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var seen: [UUID: (name: String, setup: Bool, rssi: Int)] = [:]

    init(target: String?, scanSeconds: Double) {
        self.target = target
        self.scanSeconds = scanSeconds
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            log.record(.setupDiscovery, .started, "scanning \(Int(scanSeconds)) s for watches")
            c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) { self.scanDone() }
        case .unauthorized:
            log.record(.setupDiscovery, .failed, "Bluetooth permission denied (System Settings → Privacy & Security → Bluetooth)")
            finish(2)
        case .poweredOff:
            log.record(.setupDiscovery, .failed, "Bluetooth is off")
            finish(2)
        default: break
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let services = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (ad[CBAdvertisementDataSolicitedServiceUUIDsKey] as? [CBUUID] ?? [])
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let setup = services.contains(CBUUID(nsuuid: SetupPairing.service))
        guard setup || name.localizedCaseInsensitiveContains("watch") || name.localizedCaseInsensitiveContains("galaxy") else { return }
        seen[p.identifier] = (name.isEmpty ? "(no name)" : name, setup, rssi.intValue)
        if let target, peripheral == nil,
           p.identifier.uuidString.caseInsensitiveCompare(target) == .orderedSame || name.localizedCaseInsensitiveContains(target) {
            peripheral = p
            c.stopScan()
            log.record(.setupDiscovery, .passed, "found \(name.isEmpty ? p.identifier.uuidString : name); connecting")
            p.delegate = self
            c.connect(p)
        }
    }

    func scanDone() {
        guard peripheral == nil else { return }
        central.stopScan()
        if seen.isEmpty {
            log.record(.setupDiscovery, .failed, "no watches found nearby")
        } else {
            print("\nNearby watches:")
            for (id, w) in seen.sorted(by: { $0.value.rssi > $1.value.rssi }) {
                print("  \(id.uuidString)  \(w.name)  RSSI \(w.rssi)\(w.setup ? "  [setup screen]" : "")")
            }
            let detail = target == nil ? "scan complete; \(seen.count) watch(es)" : "\"\(target!)\" not found"
            log.record(.setupDiscovery, target == nil ? .passed : .failed, detail)
        }
        finish(target == nil ? 0 : 1)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log.record(.setupDiscovery, .failed, "connect failed: \(error?.localizedDescription ?? "unknown")")
        finish(1)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log.record(.setupBond, .failed, "watch disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
        finish(1)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == CBUUID(nsuuid: SetupPairing.service) }) else {
            let found = (p.services ?? []).map(\.uuid.uuidString).joined(separator: ", ")
            log.record(.setupDiscovery, .failed,
                       "watch doesn't expose the setup pairing service, so it isn't on its setup screen. Services seen: \(found.isEmpty ? "none" : found)")
            finish(1)
        }
        p.discoverCharacteristics([CBUUID(nsuuid: SetupPairing.pairingCharacteristic),
                                   CBUUID(nsuuid: SetupPairing.capabilitiesCharacteristic)], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = s.characteristics ?? []
        guard let caps = chars.first(where: { $0.uuid == CBUUID(nsuuid: SetupPairing.capabilitiesCharacteristic) }),
              let status = chars.first(where: { $0.uuid == CBUUID(nsuuid: SetupPairing.pairingCharacteristic) }) else {
            log.record(.setupDiscovery, .failed, "setup service is missing its pairing characteristics")
            finish(1)
        }
        p.setNotifyValue(true, for: status)
        let payload = SetupPairing.capabilitiesPayload()
        log.record(.setupCapabilities, .started, "writing capabilities (companion OS iOS, BLE role \(SetupPairing.gattTransportBleRole)); this needs bonding, accept the prompt on both screens")
        p.writeValue(payload, for: caps, type: .withResponse)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if let error {
            log.record(.setupCapabilities, .failed, "capabilities write rejected: \(error.localizedDescription)")
            finish(1)
        }
        log.record(.setupCapabilities, .passed, "watch accepted iPhone capabilities")
        log.record(.setupBond, .passed, "link is bonded and encrypted (the write required it)")
        do {
            try PairingRecords().save(PairingRecord(watchIdentifier: p.identifier))
        } catch {
            log.record(.setupBond, .failed, "couldn't save pairing record to the Keychain: \(error)")
        }
        print("\nNext: run `wearlink-pair serve` — the watch should now connect to this Mac's Clockwork service.")
        // Stay connected briefly so the watch can finish its side, then leave Stage 3 to `serve`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(0) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        if let v = c.value, let b = v.first {
            log.record(.setupBond, .started, "watch reports bond status \(b)")
        }
    }
}

// MARK: Stages 3–4 — watch is the central

final class ClockworkServer: NSObject, CBPeripheralManagerDelegate {
    var manager: CBPeripheralManager!
    let session: ClockworkSession
    var characteristics: [UUID: CBMutableCharacteristic] = [:]
    var queue: [(CBMutableCharacteristic, Data)] = []
    var watch: CBCentral?

    init(approve: Bool) {
        let approval = ApprovalFlag(approved: approve)
        session = ClockworkSession(log: log, encryption: nil) { approval.approved }
        super.init()
        if !approve {
            // Ask on stdin; the confirm characteristic reads 00 until the user says yes.
            Thread {
                print("Type y + Enter when the watch asks you to confirm pairing on this Mac.")
                while let line = readLine() {
                    if line.lowercased().hasPrefix("y") { approval.approved = true; print("Approved.") }
                }
            }.start()
        }
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    final class ApprovalFlag: @unchecked Sendable {
        var approved: Bool
        init(approved: Bool) { self.approved = approved }
    }

    func peripheralManagerDidUpdateState(_ m: CBPeripheralManager) {
        guard m.state == .poweredOn else {
            if m.state == .unauthorized || m.state == .poweredOff {
                log.record(.clockworkConnect, .failed, m.state == .poweredOff ? "Bluetooth is off" : "Bluetooth permission denied")
                finish(2)
            }
            return
        }
        func make(_ id: UUID, _ props: CBCharacteristicProperties, _ perms: CBAttributePermissions) -> CBMutableCharacteristic {
            let c = CBMutableCharacteristic(type: CBUUID(nsuuid: id), properties: props, value: nil, permissions: perms)
            characteristics[id] = c
            return c
        }
        let service = CBMutableService(type: CBUUID(nsuuid: Clockwork.service), primary: true)
        // Everything requires an encrypted (bonded) link.
        service.characteristics = [
            make(Clockwork.watchToPhone, [.write, .writeWithoutResponse], .writeEncryptionRequired),
            make(Clockwork.phoneToWatch, [.notify], .readEncryptionRequired),
            make(Clockwork.reconnect, [.notify], .readEncryptionRequired),
            make(Clockwork.reset, [.notify, .write], [.readEncryptionRequired, .writeEncryptionRequired]),
            make(Clockwork.pairingConfirm, [.read], .readEncryptionRequired),
            make(Clockwork.decommission, [.read], .readEncryptionRequired),
        ]
        m.add(service)
    }

    func peripheralManager(_ m: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            log.record(.clockworkConnect, .failed, "couldn't publish the Clockwork service: \(error.localizedDescription)")
            finish(1)
        }
        m.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: Clockwork.service)],
                            CBAdvertisementDataLocalNameKey: "WearLink"])
        log.record(.clockworkConnect, .started, "Clockwork service published; waiting for the watch to connect")
    }

    func peripheralManager(_ m: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        noteWatch(request.central)
        guard let value = session.read(UUID(uuidString: request.characteristic.uuid.uuidString)!) else {
            m.respond(to: request, withResult: .readNotPermitted)
            return
        }
        guard request.offset <= value.count else { m.respond(to: request, withResult: .invalidOffset); return }
        request.value = value.subdata(in: request.offset..<value.count)
        m.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ m: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            noteWatch(r.central)
            let out = session.write(UUID(uuidString: r.characteristic.uuid.uuidString)!, r.value ?? Data())
            for o in out { if let c = characteristics[o.characteristic] { notify(c, o.value) } }
        }
        if let first = requests.first { m.respond(to: first, withResult: .success) }
        if session.isStopped { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(self.exitCode) } }
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didSubscribeTo c: CBCharacteristic) {
        noteWatch(central)
        session.subscribed(UUID(uuidString: c.uuid.uuidString)!)
    }

    func peripheralManager(_ m: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom c: CBCharacteristic) {
        session.disconnected()
        finish(exitCode)
    }

    func peripheralManagerIsReady(toUpdateSubscribers m: CBPeripheralManager) {
        while let (c, v) = queue.first {
            guard m.updateValue(v, for: c, onSubscribedCentrals: nil) else { return }
            queue.removeFirst()
        }
    }

    private func notify(_ c: CBMutableCharacteristic, _ v: Data) {
        if queue.isEmpty, manager.updateValue(v, for: c, onSubscribedCentrals: nil) { return }
        queue.append((c, v))
    }

    private func noteWatch(_ central: CBCentral) {
        guard watch == nil else { return }
        watch = central
        session.connected()
    }

    var exitCode: Int32 {
        log.events.last.map { $0.result == .passed ? 0 : $0.result == .blocked ? 3 : 1 } ?? 1
    }
}

// MARK: Entry

switch args.first {
case "scan":
    let runner = SetupRunner(target: nil, scanSeconds: Double(option("--seconds") ?? "10") ?? 10)
    withExtendedLifetime(runner) { RunLoop.main.run() }
case "setup":
    guard args.count >= 2, !args[1].hasPrefix("--") else { print(usage); exit(64) }
    let runner = SetupRunner(target: args[1], scanSeconds: 20)
    withExtendedLifetime(runner) { RunLoop.main.run() }
case "serve":
    let server = ClockworkServer(approve: args.contains("--approve"))
    withExtendedLifetime(server) { RunLoop.main.run() }
case "status":
    do {
        if let r = try PairingRecords().load() {
            print("Paired watch: \(r.watchIdentifier.uuidString), since \(r.pairedAt.formatted()), session stored: \(r.session != nil ? "yes" : "no")")
        } else {
            print("No pairing record.")
        }
    } catch { print("Keychain error: \(error)"); exit(1) }
case "forget":
    do { try PairingRecords().forget(); print("Pairing record deleted.") } catch { print("Keychain error: \(error)"); exit(1) }
default:
    print(usage)
    exit(args.isEmpty ? 0 : 64)
}
