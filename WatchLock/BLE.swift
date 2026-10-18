import Foundation
import CoreBluetooth

protocol BLEControlling: AnyObject {
    var isScanning: Bool { get }
    var isConnected: Bool { get }
    var nextDeadline: TimeInterval? { get }
    var onMeasurement: ((UUID, Int, UInt64) -> Void)? { get set }
    var onAvailability: ((BluetoothAvailability) -> Void)? { get set }
    var onConnectionChanged: ((Bool) -> Void)? { get set }
    var onDiscovery: ((UUID, String?, Int) -> Void)? { get set }
    func apply(_ effect: MonitoringEffect, now: TimeInterval)
    func startDiscovery(now: TimeInterval)
    func stopDiscovery(now: TimeInterval)
    func tick(now: TimeInterval)
    func stop()
}

// One central per monitoring generation prevents same-UUID late central callbacks
// from a cancelled A → B → A connection being attributed to the new A.
final class BLE: NSObject, BLEControlling, CBCentralManagerDelegate {
    var onMeasurement: ((UUID, Int, UInt64) -> Void)?
    var onAvailability: ((BluetoothAvailability) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onDiscovery: ((UUID, String?, Int) -> Void)?
    private var policy = RadioPolicy()
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var delegate: MeasurementDelegate?
    private var pendingConnection: (UUID, UInt64)?
    private var hasState = false
    var isScanning: Bool { central?.isScanning ?? false }
    var isConnected: Bool { policy.isConnected }
    var nextDeadline: TimeInterval? { policy.nextDeadline }

    override init() { super.init(); replaceCentral() }
    func apply(_ effect: MonitoringEffect, now: TimeInterval) {
        switch effect {
        case .startRadio(let id, let epoch):
            stop(); replaceCentral()
            execute(policy.handle(.monitor(id: id, generation: epoch), now: now))
        case .stopRadio: stop()
        case .requestLock: break
        }
    }
    func startDiscovery(now: TimeInterval) { execute(policy.handle(.startDiscovery, now: now)) }
    func stopDiscovery(now: TimeInterval) { execute(policy.handle(.stopDiscovery, now: now)) }
    func tick(now: TimeInterval) { execute(policy.handle(.tick, now: now)) }
    func stop() {
        execute(policy.handle(.stop, now: monotonicNow()))
        central?.stopScan()
        pendingConnection = nil; delegate = nil
        for peripheral in peripherals.values {
            peripheral.delegate = nil
            if peripheral.state != .disconnected { central?.cancelPeripheralConnection(peripheral) }
        }
        peripherals.removeAll()
        onConnectionChanged?(false)
    }
    private func replaceCentral() {
        central?.delegate = nil; hasState = false
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    private func execute(_ actions: [RadioAction]) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let central else { return }
        for action in actions {
            switch action {
            case .startScan:
                if central.state == .poweredOn { central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
            case .stopScan: central.stopScan()
            case .connect(let id, let epoch):
                // Each retry has a distinct central identity, including retries of the same UUID.
                central.stopScan()
                for peripheral in peripherals.values {
                    peripheral.delegate = nil
                    central.cancelPeripheralConnection(peripheral)
                }
                peripherals.removeAll(); delegate = nil
                replaceCentral()
                pendingConnection = (id, epoch)
                connectPending()
            case .disconnect(let id):
                if pendingConnection?.0 == id { pendingConnection = nil }
                if let peripheral = peripherals[id] {
                    peripheral.delegate = nil; delegate = nil
                    central.cancelPeripheralConnection(peripheral)
                }
                onConnectionChanged?(false)
            case .readRSSI(let id, let epoch):
                guard let peripheral = peripherals[id], peripheral.state == .connected,
                      let delegate, delegate.generation == epoch else { continue }
                delegate.pending = true
                peripheral.readRSSI()
            }
        }
    }
    private func connectPending() {
        guard let central, central.state == .poweredOn, let (id, epoch) = pendingConnection,
              policy.targetID == id, policy.generation == epoch, policy.expectsConnection else { return }
        let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let peripheral else { return }
        peripherals[id] = peripheral
        central.connect(peripheral, options: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central else { return }
        switch central.state {
        case .poweredOn:
            hasState = true; onAvailability?(.available)
            guard central === self.central else { return }
            connectPending()
            if policy.isScanning { execute([.startScan(discovery: true)]) }
        case .unauthorized: hasState = true; onAvailability?(.unauthorized)
        case .poweredOff, .unsupported: hasState = true; onAvailability?(.unavailable)
        default: if hasState { onAvailability?(.unavailable) }
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard central === self.central else { return }
        if policy.isDiscovering {
            onDiscovery?(peripheral.identifier, advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name, RSSI.intValue)
        }
        if peripheral.identifier == policy.targetID {
            peripherals[peripheral.identifier] = peripheral
            execute(policy.handle(.discovered(id: peripheral.identifier, generation: policy.generation), now: monotonicNow()))
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard central === self.central else { central.cancelPeripheralConnection(peripheral); return }
        let epoch = policy.generation
        guard peripheral.identifier == policy.targetID, policy.expectsConnection else { central.cancelPeripheralConnection(peripheral); return }
        pendingConnection = nil
        let reader = MeasurementDelegate(generation: epoch) { [weak self, weak peripheral] requestDelegate, rssi in
            guard let self, let peripheral, self.delegate === requestDelegate,
                  self.policy.generation == epoch, self.policy.isConnected else { return }
            self.execute(self.policy.handle(.rssiCompleted(id: peripheral.identifier, generation: epoch), now: monotonicNow()))
            if let rssi { self.onMeasurement?(peripheral.identifier, rssi, epoch) }
        }
        delegate = reader; peripheral.delegate = reader
        onConnectionChanged?(true)
        execute(policy.handle(.connected(id: peripheral.identifier, generation: epoch), now: monotonicNow()))
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { disconnected(central, peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { disconnected(central, peripheral) }
    private func disconnected(_ central: CBCentralManager, _ peripheral: CBPeripheral) {
        guard central === self.central, peripheral.identifier == policy.targetID else { return }
        delegate = nil; peripheral.delegate = nil
        onConnectionChanged?(false)
        execute(policy.handle(.disconnected(id: peripheral.identifier, generation: policy.generation), now: monotonicNow()))
    }
}

private final class MeasurementDelegate: NSObject, CBPeripheralDelegate {
    let generation: UInt64
    var pending = false
    private let completed: (MeasurementDelegate, Int?) -> Void
    init(generation: UInt64, completed: @escaping (MeasurementDelegate, Int?) -> Void) { self.generation = generation; self.completed = completed }
    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard pending else { return }
        pending = false
        let value = RSSI.intValue
        completed(self, error == nil && (-127 ... -1).contains(value) ? value : nil)
    }
}
