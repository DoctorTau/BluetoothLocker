import Foundation

enum MonitoringState: String { case nearby, far, noSignal, bluetoothUnavailable, suspended }
enum BluetoothAvailability { case available, unavailable, unauthorized }
enum ScreenState { case locked, unlocked, unknown }
enum LockReason: String { case weakSignal, noSignal, bluetoothUnavailable, permissionRevoked, manual }
enum LockOutcome: Equatable { case confirmed, failed(String) }
enum MonitoringEffect: Equatable { case startRadio(UUID, UInt64), stopRadio, requestLock(LockReason) }
enum MonitoringEvent {
    case start(primary: SavedDevice), sample(id: UUID, rssi: Int, generation: UInt64)
    case bluetoothChanged(BluetoothAvailability), sessionChanged(ScreenState)
    case sleep, wake, pause(minutes: Int), resume, calibrationChanged(Bool), lockCompleted(LockOutcome), tick, stop
}

struct MonitoringEngine {
    private(set) var state: MonitoringState = .suspended
    private(set) var generation: UInt64 = 0
    private(set) var lastMeasurementAt: TimeInterval?
    private(set) var rawRSSI: Int?
    private(set) var smoothedRSSI: Double?
    private(set) var pauseUntil: TimeInterval?
    private(set) var fault: String?
    private(set) var isActive = false
    private var primary: SavedDevice?
    private var availability: BluetoothAvailability = .unavailable
    private var availabilityKnown = false
    var isBluetoothAvailable: Bool { availabilityKnown && availability == .available }
    private var screen: ScreenState = .unknown
    private var awake = true
    private var enabled = false
    private var lockPending = false
    private var calibrating = false
    private var samples: [(time: TimeInterval, value: Int)] = []
    private var startedAt: TimeInterval = 0
    private var weakSince: TimeInterval?

    var needsTick: Bool { awake && (enabled || pauseUntil != nil) }

    mutating func handle(_ event: MonitoringEvent, now: TimeInterval) -> [MonitoringEffect] {
        switch event {
        case .start(let device):
            guard (try? device.settings.validate()) != nil else { return [] }
            if enabled && primary == device { return [] }
            let effects = suspend()
            primary = device; enabled = true
            if availabilityKnown && availability != .available && fault == nil { initialBluetoothFault() }
            return effects + activate(now: now)
        case .stop:
            enabled = false; primary = nil; pauseUntil = nil; calibrating = false
            return suspend()
        case .sleep:
            awake = false; calibrating = false
            return suspend()
        case .wake:
            guard !awake else { return [] }
            awake = true
            expirePause(now: now)
            return activate(now: now)
        case .sessionChanged(let value):
            guard screen != value else { return [] }
            screen = value
            if value != .unlocked { calibrating = false; return suspend() }
            return activate(now: now)
        case .bluetoothChanged(let value):
            let previouslyKnown = availabilityKnown
            availabilityKnown = true
            guard !previouslyKnown || availability != value else { return [] }
            availability = value
            if value != .available && isActive {
                if calibrating { calibrating = false }
                return request(value == .unauthorized ? .permissionRevoked : .bluetoothUnavailable)
            }
            if value == .available { return activate(now: now) }
            if enabled && fault == nil { initialBluetoothFault() }
            return []
        case .pause(let minutes):
            guard [15, 30, 60].contains(minutes) else { return [] }
            pauseUntil = now + Double(minutes * 60); calibrating = false
            return suspend()
        case .resume:
            pauseUntil = nil
            guard isBluetoothAvailable else { if enabled { initialBluetoothFault() }; return [] }
            fault = nil
            return activate(now: now)
        case .calibrationChanged(let value):
            guard calibrating != value else { return [] }
            calibrating = value
            if !value && isActive { clearMeasurements(); startedAt = now; state = .noSignal }
            return []
        case .lockCompleted(let outcome):
            lockPending = false
            switch outcome {
            case .confirmed: screen = .locked
            case .failed(let message): fault = message
            }
            return suspend()
        case .sample(let id, let rssi, let epoch):
            guard isActive, epoch == generation, id == primary?.id, (-127 ... -1).contains(rssi) else { return [] }
            lastMeasurementAt = now; rawRSSI = rssi
            samples.append((now, rssi))
            updateSignal(now: now)
        case .tick:
            expirePause(now: now)
            if !isActive { return activate(now: now) }
            updateSignal(now: now)
        }
        guard isActive, !calibrating, let settings = primary?.settings else { return [] }
        let signalDeadline = lastMeasurementAt.map { $0 + settings.noSignalTimeout } ?? (startedAt + 15)
        if now >= signalDeadline { return request(.noSignal) }
        if let weakSince, now - weakSince >= settings.weakSignalDelay { return request(.weakSignal) }
        return []
    }

    private mutating func initialBluetoothFault() {
        fault = "Bluetooth недоступен при запуске. Включите Bluetooth и нажмите «Возобновить»."
        state = .bluetoothUnavailable
    }
    private mutating func activate(now: TimeInterval) -> [MonitoringEffect] {
        guard !isActive, enabled, let primary, awake, screen == .unlocked,
              isBluetoothAvailable, pauseUntil == nil, fault == nil, !lockPending else { return [] }
        generation &+= 1; isActive = true; startedAt = now
        clearMeasurements(); state = .noSignal
        return [.startRadio(primary.id, generation)]
    }
    private mutating func suspend() -> [MonitoringEffect] {
        let hadRadio = isActive
        isActive = false; generation &+= 1
        clearMeasurements(); state = .suspended
        return hadRadio ? [.stopRadio] : []
    }
    private mutating func request(_ reason: LockReason) -> [MonitoringEffect] {
        guard !lockPending else { return [] }
        lockPending = true; isActive = false; generation &+= 1
        state = reason == .bluetoothUnavailable || reason == .permissionRevoked ? .bluetoothUnavailable : .suspended
        return [.requestLock(reason)]
    }
    private mutating func expirePause(now: TimeInterval) {
        if let pauseUntil, now >= pauseUntil { self.pauseUntil = nil }
    }
    private mutating func clearMeasurements() {
        samples.removeAll(); rawRSSI = nil; smoothedRSSI = nil; lastMeasurementAt = nil; weakSince = nil
    }
    private mutating func updateSignal(now: TimeInterval) {
        guard let settings = primary?.settings else { return }
        samples.removeAll { now - $0.time >= settings.noSignalTimeout }
        if samples.count > 5 { samples.removeFirst(samples.count - 5) }
        guard !samples.isEmpty else { smoothedRSSI = nil; weakSince = nil; state = .noSignal; return }
        let mean = Double(samples.reduce(0) { $0 + $1.value }) / Double(samples.count)
        smoothedRSSI = mean
        if mean < settings.threshold {
            if weakSince == nil { weakSince = now }
            state = .far
        } else if state != .far || mean >= settings.threshold + 5 {
            weakSince = nil; state = .nearby
        }
    }
}
