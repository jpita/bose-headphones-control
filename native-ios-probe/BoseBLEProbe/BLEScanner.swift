import CoreBluetooth
import Foundation

struct ProbeDevice: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var isLikelyBose: Bool
    var connection: String
}

struct ProbeCharacteristic: Identifiable {
    let id: String
    let service: String
    let uuid: String
    let properties: String
    var value: String?
}

@MainActor
final class BLEScanner: NSObject, ObservableObject {
    @Published private(set) var bluetoothState = "Starting Bluetooth…"
    @Published private(set) var isScanning = false
    @Published private(set) var devices: [ProbeDevice] = []
    @Published private(set) var characteristics: [ProbeCharacteristic] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var bmapAvailable = false
    @Published private(set) var bmapStatus = "Waiting for Bose control service…"
    @Published private(set) var bmapVersion: String?
    @Published private(set) var battery: Int?
    @Published private(set) var currentMode: Int?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristicObjects: [String: CBCharacteristic] = [:]
    private var autoConnectionAttempted = Set<UUID>()
    private var bmapCharacteristic: CBCharacteristic?
    private var bmapRequest: BMAPReadRequest?

    private enum BMAPReadRequest: Equatable {
        case waitingForNotifications
        case version
        case battery
        case currentMode
    }

    private static let bmapSecureUUID = CBUUID(string: "C65B8F2F-AEE2-4C89-B758-BC4892D6F2D8")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard central.state == .poweredOn else {
            addLog("Bluetooth is not ready: \(stateName(central.state))")
            return
        }
        devices = []
        characteristics = []
        characteristicObjects = [:]
        autoConnectionAttempted = []
        bmapCharacteristic = nil
        bmapAvailable = false
        bmapStatus = "Waiting for Bose control service…"
        bmapVersion = nil
        battery = nil
        currentMode = nil
        central.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
        isScanning = true
        addLog("Scanning for BLE advertisements (read-only)")
    }

    func stopScanning() {
        central.stopScan()
        isScanning = false
        addLog("Scan stopped")
    }

    func connect(to id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central.stopScan()
        isScanning = false
        updateDevice(id) { $0.connection = "Connecting…" }
        addLog("Connecting to \(displayName(peripheral))")
        central.connect(peripheral)
    }

    func disconnect() {
        guard let peripheral = peripherals.values.first(where: { $0.state == .connected }) else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func read(_ id: String) {
        guard let characteristic = characteristicObjects[id],
              characteristic.properties.contains(.read),
              let peripheral = characteristic.service?.peripheral else { return }
        addLog("READ \(characteristic.uuid.uuidString)")
        peripheral.readValue(for: characteristic)
    }

    func readBoseStatus() {
        guard let characteristic = bmapCharacteristic,
              let peripheral = characteristic.service?.peripheral,
              peripheral.state == .connected else {
            bmapStatus = "Bose control service is not connected."
            return
        }
        guard bmapRequest == nil else { return }

        bmapVersion = nil
        battery = nil
        currentMode = nil
        bmapStatus = "Preparing read-only BMAP queries…"
        if characteristic.isNotifying {
            sendBMAPGet(.version, peripheral: peripheral, characteristic: characteristic)
        } else {
            bmapRequest = .waitingForNotifications
            addLog("BMAP enabling encrypted response notifications")
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    var report: String {
        let device = connectedName ?? "No connected BLE device"
        let rows = characteristics.map {
            "service=\($0.service) characteristic=\($0.uuid) properties=\($0.properties) value=\($0.value ?? "not read")"
        }
        return (["Bose BLE Probe", "device=\(device)", "bluetooth=\(bluetoothState)"] + rows + ["", "Log:"] + log).joined(separator: "\n")
    }

    private func isBose(name: String, advertisementData: [String: Any]) -> Bool {
        let normalized = name.lowercased()
        if normalized.contains("bose") || normalized.contains("qc 45") || normalized.contains("quietcomfort") {
            return true
        }
        if let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           manufacturer.count >= 2 {
            let companyID = UInt16(manufacturer[0]) | (UInt16(manufacturer[1]) << 8)
            return companyID == 0x009E
        }
        return false
    }

    private func displayName(_ peripheral: CBPeripheral, advertisementData: [String: Any]? = nil) -> String {
        if let localName = advertisementData?[CBAdvertisementDataLocalNameKey] as? String, !localName.isEmpty {
            return localName
        }
        return peripheral.name ?? "Unnamed BLE device"
    }

    private func key(for characteristic: CBCharacteristic) -> String {
        "\(characteristic.service?.uuid.uuidString ?? "?")/\(characteristic.uuid.uuidString)"
    }

    private func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.writeWithoutResponse) { names.append("write-no-response") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.authenticatedSignedWrites) { names.append("signed-write") }
        if properties.contains(.extendedProperties) { names.append("extended") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notify-encrypted") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicate-encrypted") }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    private func updateDevice(_ id: UUID, change: (inout ProbeDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        change(&devices[index])
    }

    private func addLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        log.insert("[\(formatter.string(from: Date()))] \(message)", at: 0)
        print("[BLEProbe] \(message)")
    }

    private func sendBMAPGet(
        _ request: BMAPReadRequest,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic
    ) {
        let address: (UInt8, UInt8)
        switch request {
        case .version: address = (0, 1)
        case .battery: address = (2, 2)
        case .currentMode: address = (31, 3)
        case .waitingForNotifications: return
        }

        bmapRequest = request
        let packet = Data([0x00, address.0, address.1, 0x01, 0x00])
        addLog("BMAP GET [\(address.0).\(address.1)]")
        peripheral.writeValue(packet, for: characteristic, type: .withResponse)
    }

    private func acceptBMAPNotification(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else {
            addLog("BMAP response too short: \(data.map { String(format: "%02x", $0) }.joined())")
            return
        }

        let segment = bytes[0]
        guard segment == 0 else {
            addLog("BMAP segmented response not needed by this small status test")
            bmapStatus = "Received an unsupported segmented response."
            bmapRequest = nil
            return
        }

        let block = bytes[1]
        let function = bytes[2]
        let operation = bytes[3] & 0x0f
        let length = Int(bytes[4])
        guard bytes.count >= 5 + length else {
            addLog("BMAP malformed response [\(block).\(function)]")
            return
        }
        let payload = Array(bytes[5..<(5 + length)])
        addLog("BMAP RX [\(block).\(function)] op=\(operation) \(payload.map { String(format: "%02x", $0) }.joined())")

        if operation == 4 {
            let code = payload.first.map(String.init) ?? "unknown"
            bmapStatus = "Bose returned protocol error \(code)."
            bmapRequest = nil
            return
        }

        switch bmapRequest {
        case .version where block == 0 && function == 1:
            bmapVersion = String(bytes: payload.prefix { $0 != 0 }, encoding: .utf8) ?? "unknown"
            sendBMAPGet(.battery, peripheral: peripheral, characteristic: characteristic)
        case .battery where block == 2 && function == 2:
            battery = payload.first.map(Int.init)
            sendBMAPGet(.currentMode, peripheral: peripheral, characteristic: characteristic)
        case .currentMode where block == 31 && function == 3:
            currentMode = payload.first.map(Int.init)
            bmapStatus = "Success: Bose status read over BLE."
            bmapRequest = nil
        default:
            addLog("BMAP unsolicited or out-of-order response")
        }
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "Ready"
        case .poweredOff: return "Powered off"
        case .unauthorized: return "Permission denied"
        case .unsupported: return "Unsupported"
        case .resetting: return "Resetting"
        case .unknown: return "Unknown"
        @unknown default: return "Unknown"
        }
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothState = stateName(central.state)
            addLog("Bluetooth: \(bluetoothState)")
            if central.state == .poweredOn { startScanning() }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            peripherals[peripheral.identifier] = peripheral
            let name = displayName(peripheral, advertisementData: advertisementData)
            let likelyBose = isBose(name: name, advertisementData: advertisementData)
            if let index = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
                devices[index].name = name
                devices[index].rssi = RSSI.intValue
                devices[index].isLikelyBose = likelyBose
            } else {
                devices.append(ProbeDevice(
                    id: peripheral.identifier,
                    name: name,
                    rssi: RSSI.intValue,
                    isLikelyBose: likelyBose,
                    connection: "Discovered"
                ))
            }
            devices.sort {
                if $0.isLikelyBose != $1.isLikelyBose { return $0.isLikelyBose }
                return $0.rssi > $1.rssi
            }
            if likelyBose && !autoConnectionAttempted.contains(peripheral.identifier) {
                autoConnectionAttempted.insert(peripheral.identifier)
                connect(to: peripheral.identifier)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedName = displayName(peripheral)
            updateDevice(peripheral.identifier) { $0.connection = "Connected" }
            peripheral.delegate = self
            addLog("Connected; discovering services only")
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            updateDevice(peripheral.identifier) { $0.connection = "Failed" }
            addLog("Connection failed: \(error?.localizedDescription ?? "unknown error")")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            connectedName = nil
            bmapAvailable = false
            bmapCharacteristic = nil
            bmapRequest = nil
            bmapStatus = "Disconnected"
            updateDevice(peripheral.identifier) { $0.connection = "Disconnected" }
            addLog("Disconnected: \(error?.localizedDescription ?? "cleanly")")
        }
    }
}

extension BLEScanner: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                addLog("Service discovery failed: \(error.localizedDescription)")
                return
            }
            let services = peripheral.services ?? []
            addLog("Found \(services.count) service(s)")
            for service in services { peripheral.discoverCharacteristics(nil, for: service) }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                addLog("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
                return
            }
            for characteristic in service.characteristics ?? [] {
                let id = key(for: characteristic)
                characteristicObjects[id] = characteristic
                if characteristic.uuid == Self.bmapSecureUUID {
                    bmapCharacteristic = characteristic
                    bmapAvailable = true
                    bmapStatus = "Bose control service found."
                }
                let properties = propertyNames(characteristic.properties)
                if !characteristics.contains(where: { $0.id == id }) {
                    characteristics.append(ProbeCharacteristic(
                        id: id,
                        service: service.uuid.uuidString,
                        uuid: characteristic.uuid.uuidString,
                        properties: properties,
                        value: nil
                    ))
                }
                addLog("CHAR service=\(service.uuid.uuidString) uuid=\(characteristic.uuid.uuidString) properties=\(properties)")
            }
            characteristics.sort { ($0.service, $0.uuid) < ($1.service, $1.uuid) }
            addLog("\(service.uuid): \(service.characteristics?.count ?? 0) characteristic(s)")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if characteristic.uuid == Self.bmapSecureUUID,
               error == nil,
               let value = characteristic.value {
                acceptBMAPNotification(value, peripheral: peripheral, characteristic: characteristic)
                return
            }
            let id = key(for: characteristic)
            if let index = characteristics.firstIndex(where: { $0.id == id }) {
                if let error {
                    characteristics[index].value = "ERROR: \(error.localizedDescription)"
                } else {
                    characteristics[index].value = characteristic.value?.map { String(format: "%02x", $0) }.joined() ?? "empty"
                }
            }
            addLog("READ result \(characteristic.uuid): \(error?.localizedDescription ?? "ok")")
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == Self.bmapSecureUUID else { return }
            if let error {
                bmapStatus = "Could not enable Bose responses: \(error.localizedDescription)"
                bmapRequest = nil
                addLog(bmapStatus)
                return
            }
            guard characteristic.isNotifying else {
                bmapStatus = "Bose response notifications are off."
                bmapRequest = nil
                return
            }
            addLog("BMAP response notifications ready")
            if bmapRequest == .waitingForNotifications {
                sendBMAPGet(.version, peripheral: peripheral, characteristic: characteristic)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == Self.bmapSecureUUID else { return }
            if let error {
                bmapStatus = "BMAP query failed: \(error.localizedDescription)"
                bmapRequest = nil
                addLog(bmapStatus)
            }
        }
    }
}
