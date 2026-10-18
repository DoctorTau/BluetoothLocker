import Foundation
import Testing
@testable import WatchLockCore

struct MonitoringEngineTests {
    let watch = SavedDevice(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Watch")
    func active() -> MonitoringEngine {
        var engine = MonitoringEngine()
        _ = engine.handle(.bluetoothChanged(.available), now: 0)
        _ = engine.handle(.sessionChanged(.unlocked), now: 0)
        _ = engine.handle(.start(primary: watch), now: 0)
        return engine
    }
    @Test func testNoSignalAndOnlyPrimary() {
        var e = active()
        #expect(e.state == .noSignal)
        _ = e.handle(.sample(id: UUID(), rssi: -40, generation: e.generation), now: 14)
        for invalid in [0, 127, -128] { _ = e.handle(.sample(id: watch.id, rssi: invalid, generation: e.generation), now: 14) }
        #expect(e.lastMeasurementAt == nil)
        #expect(e.handle(.tick, now: 15) == [.requestLock(.noSignal)])
        #expect(e.handle(.tick, now: 16).isEmpty)
    }
    @Test func testSmoothingAndWeakDelay() {
        var e = active()
        for (time, rssi) in [(0.0, -60), (2, -95), (4, -55)] { _ = e.handle(.sample(id: watch.id, rssi: rssi, generation: e.generation), now: time) }
        #expect(e.handle(.tick, now: 8).isEmpty)
        e = active()
        for time in [0.0, 2, 4] { _ = e.handle(.sample(id: watch.id, rssi: -90, generation: e.generation), now: time) }
        #expect(e.handle(.tick, now: 5) == [.requestLock(.weakSignal)])
    }
    @Test func testLastFiveAndHysteresis() {
        var e = active()
        for i in 0..<5 { _ = e.handle(.sample(id: watch.id, rssi: -76, generation: e.generation), now: Double(i) / 10) }
        #expect(e.state == .far)
        for i in 0..<5 { _ = e.handle(.sample(id: watch.id, rssi: -72, generation: e.generation), now: 1 + Double(i) / 10) }
        #expect(e.state == .far)
        for i in 0..<5 { _ = e.handle(.sample(id: watch.id, rssi: -70, generation: e.generation), now: 2 + Double(i) / 10) }
        #expect(e.smoothedRSSI == -70)
        #expect(e.state == .nearby)
    }
    @Test func testGenerationAndWake() {
        var e = active()
        let old = e.generation
        _ = e.handle(.start(primary: SavedDevice(id: UUID(), name: "B")), now: 1)
        _ = e.handle(.start(primary: watch), now: 2)
        _ = e.handle(.sample(id: watch.id, rssi: -60, generation: old), now: 3)
        #expect(e.lastMeasurementAt == nil)
        #expect(e.handle(.sleep, now: 4) == [.stopRadio])
        _ = e.handle(.wake, now: 100)
        _ = e.handle(.wake, now: 110)
        #expect(e.handle(.tick, now: 114).isEmpty)
        #expect(e.handle(.tick, now: 115) == [.requestLock(.noSignal)])
    }
    @Test func testPauseAndUnknownSession() {
        var e = active()
        _ = e.handle(.pause(minutes: 15), now: 0)
        _ = e.handle(.sleep, now: 2)
        #expect(e.handle(.tick, now: 900).isEmpty)
        _ = e.handle(.sessionChanged(.locked), now: 901)
        #expect(e.handle(.wake, now: 902).isEmpty)
        #expect(e.state == .suspended)
        _ = e.handle(.sessionChanged(.unknown), now: 903)
        #expect(e.handle(.resume, now: 904).isEmpty)
    }
    @Test func testBluetoothAndFault() {
        var e = active()
        #expect(e.handle(.bluetoothChanged(.unauthorized), now: 1) == [.requestLock(.permissionRevoked)])
        #expect(e.handle(.bluetoothChanged(.unauthorized), now: 2).isEmpty)
        _ = e.handle(.lockCompleted(.failed("failure")), now: 3)
        _ = e.handle(.bluetoothChanged(.available), now: 4)
        _ = e.handle(.sessionChanged(.unlocked), now: 4)
        #expect(e.handle(.tick, now: 100).isEmpty)
        #expect(e.state == .suspended)
        #expect(e.handle(.resume, now: 101).contains(.startRadio(watch.id, e.generation)))
        var startup = MonitoringEngine()
        _ = startup.handle(.bluetoothChanged(.unauthorized), now: 0)
        _ = startup.handle(.sessionChanged(.unlocked), now: 0)
        #expect(startup.handle(.start(primary: watch), now: 0).isEmpty)
        #expect(startup.handle(.tick, now: 20).isEmpty)
    }
    @Test func testCalibrationSuppressesLock() {
        var e = active()
        _ = e.handle(.calibrationChanged(true), now: 1)
        #expect(e.handle(.tick, now: 100).isEmpty)
        _ = e.handle(.calibrationChanged(false), now: 100)
        #expect(e.handle(.tick, now: 114).isEmpty)
        #expect(e.handle(.tick, now: 115) == [.requestLock(.noSignal)])
    }
    func shortTimeout() -> MonitoringEngine {
        var e = active()
        var device = watch
        device.settings = DeviceSettings(weakSignalDelay: 1, noSignalTimeout: 5)
        _ = e.handle(.start(primary: device), now: 0)
        return e
    }
    @Test func testInitialUnavailableRequiresExplicitResume() {
        var e = MonitoringEngine()
        _ = e.handle(.bluetoothChanged(.unavailable), now: 0)
        _ = e.handle(.sessionChanged(.unlocked), now: 0)
        _ = e.handle(.start(primary: watch), now: 0)
        #expect(e.handle(.bluetoothChanged(.available), now: 1).isEmpty)
        #expect(e.handle(.tick, now: 100).isEmpty)
        #expect(!e.isActive)
        #expect(e.fault != nil)
        #expect(!e.handle(.resume, now: 101).isEmpty)
        #expect(e.isActive)
    }
    @Test func testInitialPendingAvailabilityIsNotRefusal() {
        var e = MonitoringEngine()
        _ = e.handle(.sessionChanged(.unlocked), now: 0)
        #expect(e.handle(.start(primary: watch), now: 0).isEmpty)
        #expect(e.fault == nil)
        #expect(!e.handle(.bluetoothChanged(.available), now: 1).isEmpty)
        #expect(e.isActive)
    }
    @Test func testEveryActivationGetsFirstMeasurementPeriod() {
        var e = shortTimeout()
        #expect(e.handle(.tick, now: 5).isEmpty)
        #expect(e.handle(.tick, now: 14).isEmpty)
        #expect(e.handle(.tick, now: 15) == [.requestLock(.noSignal)])
        e = shortTimeout()
        _ = e.handle(.sessionChanged(.locked), now: 1)
        _ = e.handle(.sessionChanged(.unlocked), now: 100)
        #expect(e.handle(.tick, now: 105).isEmpty)
        #expect(e.handle(.tick, now: 115) == [.requestLock(.noSignal)])
        e = shortTimeout()
        _ = e.handle(.pause(minutes: 15), now: 0)
        _ = e.handle(.tick, now: 900)
        #expect(e.handle(.tick, now: 905).isEmpty)
        #expect(e.handle(.tick, now: 915) == [.requestLock(.noSignal)])
        e = shortTimeout()
        _ = e.handle(.calibrationChanged(true), now: 1)
        _ = e.handle(.calibrationChanged(false), now: 100)
        #expect(e.handle(.tick, now: 105).isEmpty)
        #expect(e.handle(.tick, now: 115) == [.requestLock(.noSignal)])
        e = shortTimeout()
        var next = watch; next.id = UUID(); next.settings.noSignalTimeout = 5
        _ = e.handle(.start(primary: next), now: 100)
        #expect(e.handle(.tick, now: 105).isEmpty)
        #expect(e.handle(.tick, now: 115) == [.requestLock(.noSignal)])
    }
    @Test func testFreshSignalEndsAcquisitionGrace() {
        var e = shortTimeout()
        _ = e.handle(.sleep, now: 1)
        _ = e.handle(.wake, now: 100)
        _ = e.handle(.sample(id: watch.id, rssi: -90, generation: e.generation), now: 101)
        #expect(e.handle(.tick, now: 102) == [.requestLock(.weakSignal)])
        e = shortTimeout()
        _ = e.handle(.sample(id: watch.id, rssi: -60, generation: e.generation), now: 1)
        #expect(e.handle(.tick, now: 6) == [.requestLock(.noSignal)])
    }

    @Test func testSessionPollingWhileEnabledAndAwake() {
        var e = MonitoringEngine()
        #expect(!e.needsTick)
        _ = e.handle(.start(primary: watch), now: 0)
        #expect(e.needsTick) // Initial unknown session must be rechecked.
        _ = e.handle(.sessionChanged(.locked), now: 1)
        #expect(e.needsTick)
        _ = e.handle(.sleep, now: 2)
        #expect(!e.needsTick)
        _ = e.handle(.wake, now: 3)
        #expect(e.needsTick)
        _ = e.handle(.stop, now: 4)
        #expect(!e.needsTick)
    }

    @Test func testConfirmedLockAndFaultRemainPollableWithoutRetry() {
        var e = active()
        #expect(e.handle(.tick, now: 15) == [.requestLock(.noSignal)])
        _ = e.handle(.lockCompleted(.confirmed), now: 15)
        #expect(!e.isActive && e.needsTick)
        #expect(e.handle(.tick, now: 16).isEmpty)
        let unlockEffects = e.handle(.sessionChanged(.unlocked), now: 17)
        #expect(unlockEffects == [.startRadio(watch.id, e.generation)])
        let freshGeneration = e.generation
        #expect(e.handle(.sessionChanged(.unlocked), now: 18).isEmpty)
        #expect(e.generation == freshGeneration)
        #expect(e.lastMeasurementAt == nil)

        e = active()
        #expect(e.handle(.tick, now: 15) == [.requestLock(.noSignal)])
        _ = e.handle(.lockCompleted(.failed("failure")), now: 15)
        #expect(e.needsTick && !e.isActive)
        #expect(e.handle(.tick, now: 100).isEmpty)
        #expect(e.fault == "failure")
    }

}
