import CoreBluetooth

/// BLE link to the ESP32-C5 ("ITS-G5-RX"), see firmware/main/bt_stream.c.
/// Reconnect is iOS-style: a pending `connect` never times out, so after a drop we just
/// call it again and iOS reconnects whenever the receiver is back — also in background.
final class Receiver: NSObject {
    enum State: Equatable { case off, scanning, connecting, connected, unauthorized }

    static let serviceUUID = CBUUID(string: "B6E57E90-12D8-4A47-9B21-3F0000000001")
    static let notifyUUID = CBUUID(string: "B6E57E90-12D8-4A47-9B21-3F0000000002")
    static let configUUID = CBUUID(string: "B6E57E90-12D8-4A47-9B21-3F0000000003")
    static let macUUID = CBUUID(string: "B6E57E90-12D8-4A47-9B21-3F0000000004")
    private static let knownPeripheralKey = "receiver.peripheral"

    var onState: (State) -> Void = { _ in }
    var onData: (Data) -> Void = { _ in }
    /// Sniff/BLE duty-cycle in ms: [discSniff, discBle, connSniff, connBle].
    var onConfig: ([Int]) -> Void = { _ in }
    var onMac: (String) -> Void = { _ in }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var configChr: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "v2x2.receiver"])
    }

    /// Forget the paired receiver and look for any "ITS-G5-RX".
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.knownPeripheralKey)
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        start()
    }

    func writeConfig(_ values: [Int]) {
        guard let p = peripheral, let c = configChr, values.count == 4 else { return }
        var d = Data()
        for v in values { let u = UInt16(clamping: v); d.append(UInt8(u & 0xFF)); d.append(UInt8(u >> 8)) }
        p.writeValue(d, for: c, type: .withResponse)
    }

    private func start() {
        guard central.state == .poweredOn else { return }
        if let id = UserDefaults.standard.string(forKey: Self.knownPeripheralKey).flatMap(UUID.init(uuidString:)),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
        } else if let p = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]).first {
            connect(p)
        } else {
            onState(.scanning)
            central.scanForPeripherals(withServices: [Self.serviceUUID])
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        onState(.connecting)
        central.connect(p)
    }
}

extension Receiver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: start()
        case .unauthorized: onState(.unauthorized)
        default: onState(.off)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let p = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first {
            peripheral = p
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.knownPeripheralKey)
        onState(.connected)
        p.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        configChr = nil
        guard p == peripheral else { return } // forget() cancelled it on purpose
        onState(.connecting)
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        onState(.connecting)
        central.connect(p)
    }
}

extension Receiver: CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        p.discoverCharacteristics([Self.notifyUUID, Self.configUUID, Self.macUUID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for c in s.characteristics ?? [] {
            switch c.uuid {
            case Self.notifyUUID: p.setNotifyValue(true, for: c)
            case Self.configUUID: configChr = c; p.readValue(for: c)
            case Self.macUUID: p.readValue(for: c)
            default: break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let v = c.value, error == nil else { return }
        switch c.uuid {
        case Self.notifyUUID:
            onData(v)
        case Self.configUUID where v.count == 8:
            onConfig((0..<4).map { Int(v[$0 * 2]) | Int(v[$0 * 2 + 1]) << 8 })
        case Self.macUUID where v.count == 6:
            onMac(v.map { String(format: "%02X", $0) }.joined(separator: ":"))
        default:
            break
        }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        if c.uuid == Self.configUUID { p.readValue(for: c) }
    }
}
