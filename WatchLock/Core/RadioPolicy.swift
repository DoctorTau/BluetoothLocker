import Foundation

enum RadioEvent {
    case monitor(id: UUID, generation: UInt64), startDiscovery, stopDiscovery
    case discovered(id: UUID, generation: UInt64), connected(id: UUID, generation: UInt64)
    case disconnected(id: UUID, generation: UInt64), rssiCompleted(id: UUID, generation: UInt64), tick, stop
}
enum RadioAction: Equatable {
    case startScan(discovery: Bool), stopScan, connect(UUID, UInt64), disconnect(UUID), readRSSI(UUID, UInt64)
}

struct RadioPolicy {
    private(set) var generation: UInt64 = 0
    private(set) var isScanning = false
    private(set) var isConnected = false
    private(set) var targetID: UUID?
    private var discoveryUntil: TimeInterval?
    var isDiscovering: Bool { discoveryUntil != nil }
    private var hasScannedInCycle = false
    private var recovering = false
    private var connectedAt: TimeInterval?
    private enum Phase { case idle, connecting, scanning, waiting, connected }
    private var phase: Phase = .idle
    private var deadline: TimeInterval?
    private var nextRead: TimeInterval?
    private var pendingReadUntil: TimeInterval?
    var nextDeadline: TimeInterval? { [discoveryUntil, deadline, pendingReadUntil, pendingReadUntil == nil ? nextRead : nil].compactMap { $0 }.min() }
    var expectsConnection: Bool { phase == .connecting }

    mutating func handle(_ event: RadioEvent, now: TimeInterval) -> [RadioAction] {
        switch event {
        case .monitor(let id, let epoch):
            if targetID == id && generation == epoch { return [] }
            var actions = stop()
            targetID = id; generation = epoch
            hasScannedInCycle = false; recovering = false
            actions += connect(now: now)
            return actions
        case .startDiscovery:
            guard discoveryUntil == nil else { return [] }
            var actions: [RadioAction] = []
            if isScanning { actions.append(.stopScan) }
            if phase == .connecting, let targetID { actions.append(.disconnect(targetID)) }
            if !isConnected { phase = .idle; deadline = nil }
            discoveryUntil = now + 20; isScanning = true
            return actions + [.startScan(discovery: true)]
        case .stopDiscovery:
            guard discoveryUntil != nil else { return [] }
            discoveryUntil = nil; isScanning = false
            if !isConnected { hasScannedInCycle = false }
            return [.stopScan] + (isConnected ? [] : connect(now: now))
        case .discovered(let id, let epoch):
            guard discoveryUntil == nil, id == targetID, epoch == generation, phase == .scanning else { return [] }
            isScanning = false
            return [.stopScan] + connect(now: now)
        case .connected(let id, let epoch):
            guard id == targetID, epoch == generation, phase == .connecting else { return [.disconnect(id)] }
            let actions: [RadioAction] = isScanning && discoveryUntil == nil ? [.stopScan] : []
            if discoveryUntil == nil { isScanning = false }
            phase = .connected; isConnected = true; connectedAt = now; deadline = nil; nextRead = now
            return actions + read(now: now)
        case .disconnected(let id, let epoch):
            guard id == targetID, epoch == generation, phase == .connected || phase == .connecting else { return [] }
            let wasConnected = isConnected
            isConnected = false; nextRead = nil; pendingReadUntil = nil
            if discoveryUntil != nil { phase = .idle; deadline = nil; return [] }
            if wasConnected {
                // One immediate known retry; a rapidly flapping recovered link must cool down.
                if !recovering || now - (connectedAt ?? now) >= 25 {
                    recovering = true; hasScannedInCycle = false
                    return connect(now: now)
                }
                wait(now: now)
                return []
            }
            return connectionFailed(now: now)
        case .rssiCompleted(let id, let epoch):
            guard id == targetID, epoch == generation, isConnected else { return [] }
            pendingReadUntil = nil
            return []
        case .stop: return stop()
        case .tick:
            if let until = discoveryUntil, now >= until { return handle(.stopDiscovery, now: now) }
            if let until = pendingReadUntil, now >= until, let targetID {
                let recovery = handle(.disconnected(id: targetID, generation: generation), now: now)
                return [.disconnect(targetID)] + recovery
            }
            if discoveryUntil == nil, let deadline, now >= deadline {
                switch phase {
                case .connecting:
                    let recovery = connectionFailed(now: now)
                    return (targetID.map { [.disconnect($0)] } ?? []) + recovery
                case .scanning:
                    wait(now: now); isScanning = false
                    return [.stopScan]
                case .waiting:
                    hasScannedInCycle = false; recovering = true
                    return connect(now: now)
                default: break
                }
            }
            return read(now: now)
        }
    }
    private mutating func wait(now: TimeInterval) { phase = .waiting; deadline = now + 25 }
    private mutating func connectionFailed(now: TimeInterval) -> [RadioAction] {
        if hasScannedInCycle { wait(now: now); return [] }
        recovering = true; hasScannedInCycle = true
        phase = .scanning; deadline = now + 5; isScanning = true
        return [.startScan(discovery: false)]
    }
    private mutating func connect(now: TimeInterval) -> [RadioAction] {
        guard let targetID else { return [] }
        phase = .connecting; deadline = now + 5; isConnected = false
        return [.connect(targetID, generation)]
    }
    private mutating func read(now: TimeInterval) -> [RadioAction] {
        guard isConnected, let targetID, pendingReadUntil == nil, let nextRead, now >= nextRead else { return [] }
        self.nextRead = now + 2; pendingReadUntil = now + 5
        return [.readRSSI(targetID, generation)]
    }
    private mutating func stop() -> [RadioAction] {
        var actions: [RadioAction] = isScanning ? [.stopScan] : []
        if let targetID, phase == .connecting || phase == .connected { actions.append(.disconnect(targetID)) }
        targetID = nil; isScanning = false; isConnected = false; phase = .idle
        deadline = nil; discoveryUntil = nil; nextRead = nil; pendingReadUntil = nil
        hasScannedInCycle = false; recovering = false; connectedAt = nil
        return actions
    }
}
