import Foundation
import ServiceManagement
import CoreGraphics

private enum SelfCheckError: Error { case failed(String), fakeUnavailable }
private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SelfCheckError.failed(message) }
}
private final class FakeScreen: ScreenLocking {
    var current: ScreenState = .unlocked
    var unavailable = false
    var calls = 0
    var onRequest: (() -> Void)?
    func screenState() -> ScreenState { current }
    func requestLock() throws -> Int32 { calls += 1; onRequest?(); if unavailable { throw SelfCheckError.fakeUnavailable }; return 0 }
}
private final class FakeRadio: BLEControlling {
    var isScanning = false
    var isConnected = false
    var nextDeadline: TimeInterval?
    var onMeasurement: ((UUID, Int, UInt64) -> Void)?
    var onAvailability: ((BluetoothAvailability) -> Void)?
    var onConnectionChanged: ((Bool) -> Void)?
    var onDiscovery: ((UUID, String?, Int) -> Void)?
    var effects: [MonitoringEffect] = []
    func apply(_ effect: MonitoringEffect, now: TimeInterval) { effects.append(effect); if case .startRadio = effect { isConnected = true } }
    func startDiscovery(now: TimeInterval) { isScanning = true; nextDeadline = now + 20 }
    func stopDiscovery(now: TimeInterval) { isScanning = false; nextDeadline = nil }
    func tick(now: TimeInterval) {}
    func stop() { effects.append(.stopRadio); isScanning = false; isConnected = false; nextDeadline = nil }
}

// This entry point creates only fakes and an isolated temporary preference suite.
// Guard-based checks remain enabled in optimized builds; no NSApplication or radio.
func runSelfChecks() throws {
    for value: Any in [true, NSNumber(value: 1)] { try check(ScreenLockAdapter.parseLockFlag(value) == .locked, "locked flag") }
    for value: Any in [false, NSNumber(value: 0)] { try check(ScreenLockAdapter.parseLockFlag(value) == .unlocked, "unlocked flag") }
    for value: Any in ["1", 2, 0.5, [1]] { try check(ScreenLockAdapter.parseLockFlag(value) == .unknown, "invalid flag") }
    try check(ScreenLockAdapter.parseLockFlag(nil) == .unknown, "missing flag")
    let activeSession: [String: Any] = [ScreenLockAdapter.lockFlagKey: false, kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
    try check(ScreenLockAdapter.parseSession(activeSession) == .unlocked, "active unlocked session")
    let activeWithoutPrivateFlag: [String: Any] = [kCGSessionOnConsoleKey as String: true, kCGSessionLoginDoneKey as String: true]
    try check(ScreenLockAdapter.parseSession(activeWithoutPrivateFlag) == .unlocked, "active session without private flag")
    try check(ScreenLockAdapter.parseSession(nil) == .unknown, "missing session dictionary")
    try check(ScreenLockAdapter.parseSession([:]) == .unknown, "empty session dictionary")
    var malformedSession = activeWithoutPrivateFlag
    malformedSession[ScreenLockAdapter.lockFlagKey] = "0"
    try check(ScreenLockAdapter.parseSession(malformedSession) == .unknown, "present malformed lock flag")
    try check(ScreenLockAdapter.parseSession([ScreenLockAdapter.lockFlagKey: true]) == .locked, "explicit locked flag")
    var incompleteSession = activeWithoutPrivateFlag
    incompleteSession.removeValue(forKey: kCGSessionLoginDoneKey as String)
    try check(ScreenLockAdapter.parseSession(incompleteSession) == .unknown, "missing login state")
    incompleteSession = activeWithoutPrivateFlag
    incompleteSession.removeValue(forKey: kCGSessionOnConsoleKey as String)
    try check(ScreenLockAdapter.parseSession(incompleteSession) == .unknown, "missing console state")
    var failedLogin = activeWithoutPrivateFlag
    failedLogin[kCGSessionLoginDoneKey as String] = false
    try check(ScreenLockAdapter.parseSession(failedLogin) == .unknown, "incomplete login")
    var backgroundSession = activeSession
    backgroundSession[kCGSessionOnConsoleKey as String] = false
    try check(ScreenLockAdapter.parseSession(backgroundSession) == .unknown, "inactive session cannot monitor")
    backgroundSession = activeWithoutPrivateFlag
    backgroundSession[kCGSessionOnConsoleKey as String] = false
    try check(ScreenLockAdapter.parseSession(backgroundSession) == .unknown, "inactive session without private flag")
    try check(ScreenLockAdapter.parseSession([ScreenLockAdapter.lockFlagKey: false]) == .unknown, "incomplete session")
    var missingFlagVerification = LockVerification(returnCode: 0, now: 0)
    try check(missingFlagVerification.observe(ScreenLockAdapter.parseSession(activeWithoutPrivateFlag), now: 0) == nil, "missing flag cannot confirm lock")
    let missingFlagOutcome = missingFlagVerification.observe(ScreenLockAdapter.parseSession(activeWithoutPrivateFlag), now: 3)
    try check(missingFlagOutcome != nil && missingFlagOutcome != .confirmed, "missing flag must fail lock verification at deadline")
    var explicitLockVerification = LockVerification(returnCode: 0, now: 0)
    try check(explicitLockVerification.observe(ScreenLockAdapter.parseSession([ScreenLockAdapter.lockFlagKey: true]), now: 0) == .confirmed, "explicit flag confirms lock")
    let suite = "local.shatravkada.WatchLock.selfcheck.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw SelfCheckError.failed("suite") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = ConfigurationStore(defaults: defaults)
    let watch = SavedDevice(id: UUID(), name: "Watch")
    var configuration = Configuration(devices: [watch], primaryID: watch.id, monitoringEnabled: true)
    try store.save(configuration)
    let before = defaults.data(forKey: ConfigurationStore.key)
    configuration.devices[0].settings.threshold = .nan
    do { try store.save(configuration); throw SelfCheckError.failed("invalid saved") }
    catch is ConfigurationError {}
    try check(defaults.data(forKey: ConfigurationStore.key) == before, "invalid save changed data")
    defaults.set(Data("broken".utf8), forKey: ConfigurationStore.key)
    do { _ = try store.load(); throw SelfCheckError.failed("corrupt loaded") }
    catch is DecodingError {}
    try check(defaults.data(forKey: ConfigurationStore.key) == Data("broken".utf8), "corrupt overwritten")
    let corruptApp = AppDelegate(lockAdapter: FakeScreen(), radio: FakeRadio(), store: store)
    do { try corruptApp.saveConfiguration(Configuration(), now: 0); throw SelfCheckError.failed("corrupt overwritten by coordinator") }
    catch is ConfigurationStoreError {}
    corruptApp.shutdown()
    try check(defaults.data(forKey: ConfigurationStore.key) == Data("broken".utf8), "corrupt store preserved by coordinator")
    configuration.devices[0].settings = DeviceSettings()
    var disabled = configuration; disabled.monitoringEnabled = false
    try store.save(disabled)
    let unavailableApp = AppDelegate(lockAdapter: FakeScreen(), radio: FakeRadio(), store: store)
    do { try unavailableApp.saveConfiguration(configuration, now: 0); throw SelfCheckError.failed("enabled with unavailable Bluetooth") }
    catch is CoordinatorError {}
    let unchanged = try store.load()
    try check(unchanged == disabled, "unavailable enable wrote configuration")
    unavailableApp.shutdown()
    try store.save(configuration)
    let discoveryRadio = FakeRadio(), discoveryScreen = FakeScreen()
    let discoveryApp = AppDelegate(lockAdapter: discoveryScreen, radio: discoveryRadio, store: store)
    discoveryApp.perform(.startDiscovery)
    try check(discoveryRadio.isScanning, "discovery refreshes stale unknown session")
    discoveryApp.perform(.stopDiscovery)
    discoveryApp.process(.sessionChanged(.unlocked), now: 0)
    discoveryScreen.current = .locked
    discoveryApp.perform(.startDiscovery)
    try check(!discoveryRadio.isScanning, "discovery rejects newly locked session")
    discoveryScreen.current = .unknown
    discoveryApp.process(.sessionChanged(.unlocked), now: 0)
    discoveryApp.perform(.startDiscovery)
    try check(!discoveryRadio.isScanning && discoveryScreen.calls == 0, "discovery rejects newly unknown session without locking")
    discoveryApp.shutdown()
    let pollingRadio = FakeRadio(), pollingScreen = FakeScreen()
    let pollingApp = AppDelegate(lockAdapter: pollingScreen, radio: pollingRadio, store: store)
    try check(pollingApp.statusSymbolName == "shield", "inactive monitoring uses plain shield even when configured enabled")
    pollingApp.process(.bluetoothChanged(.available), now: 0)
    pollingApp.process(.sessionChanged(.unlocked), now: 0)
    pollingApp.process(.start(primary: watch), now: 0)
    try check(pollingApp.statusSymbolName == "lock.shield", "active monitoring uses shield with lock")
    let pollingTimer = pollingApp.ticker
    try check(pollingTimer?.isValid == true, "enabled coordinator owns session ticker")
    pollingScreen.onRequest = { pollingScreen.current = .locked }
    pollingApp.tick(now: 15)
    try check(pollingScreen.calls == 1 && pollingApp.lastConfirmedLock != nil, "fake automatic lock confirmed")
    try check(!pollingApp.engine.isActive && !pollingRadio.isConnected && !pollingRadio.isScanning, "locked coordinator stops radio")
    try check(pollingApp.statusSymbolName == "shield", "locked session uses plain shield")
    try check(pollingApp.ticker === pollingTimer && pollingTimer?.isValid == true, "confirmed lock retains session ticker")
    pollingApp.tick(now: 16)
    try check(pollingScreen.calls == 1 && !pollingRadio.isConnected, "locked poll must not retry or connect")
    pollingScreen.current = .unlocked // No notification delivered; only the existing ticker rechecks.
    pollingApp.tick(now: 17)
    let unlockedGeneration = pollingApp.engine.generation
    try check(pollingApp.engine.isActive && pollingRadio.isConnected && pollingApp.engine.lastMeasurementAt == nil, "poll discovers unlock with fresh measurement epoch")
    try check(pollingApp.statusSymbolName == "lock.shield", "resumed monitoring restores shield with lock")
    pollingApp.tick(now: 18)
    try check(pollingApp.engine.generation == unlockedGeneration && pollingScreen.calls == 1, "duplicate unlocked poll does not reset acquisition")
    pollingApp.process(.sleep, now: 19)
    try check(pollingApp.ticker == nil && pollingTimer?.isValid == false, "sleep invalidates session ticker")
    try check(pollingApp.statusSymbolName == "shield", "sleeping monitoring uses plain shield")
    pollingApp.shutdown()

    let resumeRadio = FakeRadio(), resumeScreen = FakeScreen()
    let resumeApp = AppDelegate(lockAdapter: resumeScreen, radio: resumeRadio, store: store)
    resumeApp.process(.bluetoothChanged(.available), now: 0)
    resumeApp.process(.sessionChanged(.unlocked), now: 0)
    resumeApp.process(.start(primary: watch), now: 0)
    resumeScreen.current = .locked
    resumeApp.perform(.resume)
    try check(!resumeApp.engine.isActive && !resumeRadio.isConnected, "resume rechecks newly locked session")
    resumeApp.process(.sessionChanged(.unlocked), now: 0)
    resumeScreen.current = .unknown
    resumeApp.perform(.resume)
    try check(!resumeApp.engine.isActive && !resumeRadio.isConnected, "resume rechecks newly unknown session")
    resumeScreen.current = .unlocked
    resumeApp.perform(.resume)
    try check(resumeApp.engine.isActive && resumeRadio.isConnected && resumeScreen.calls == 0, "resume rechecks newly unlocked session without locking")
    resumeApp.shutdown()
    let radio = FakeRadio(), lock = FakeScreen()
    let app = AppDelegate(lockAdapter: lock, radio: radio, store: store)
    defer { app.shutdown() }
    app.process(.bluetoothChanged(.available), now: 0)
    app.process(.sessionChanged(.unlocked), now: 0)
    app.process(.start(primary: watch), now: 0)
    radio.onMeasurement?(UUID(), -40, app.engine.generation)
    try check(app.engine.lastMeasurementAt == nil, "secondary presence")
    app.beginCalibration(now: 1)
    try check(app.calibration.isRunning, "calibration started")
    app.process(.sleep, now: 2)
    try check(!app.calibration.isRunning && !app.engine.isActive, "sleep cancels calibration without restart")
    app.process(.pause(minutes: 15), now: 3)
    try check(app.statusSymbolName == "shield", "paused monitoring uses plain shield")
    lock.current = .locked
    app.process(.sessionChanged(.locked), now: 4)
    app.process(.wake, now: 5)
    let starts = radio.effects.filter { if case .startRadio = $0 { return true }; return false }.count
    app.tick(now: 903)
    try check(radio.effects.filter { if case .startRadio = $0 { return true }; return false }.count == starts, "locked pause expiry")
    var invalid = app.configuration
    invalid.devices[0].settings.threshold = -200
    do { try app.saveConfiguration(invalid, now: 904); throw SelfCheckError.failed("invalid applied") }
    catch is ConfigurationError {}
    try check(app.configuration.devices[0].settings.threshold == -75, "invalid applied to coordinator")
    lock.current = .unlocked
    app.process(.sessionChanged(.unlocked), now: 904)
    app.process(.resume, now: 904)
    lock.unavailable = true
    var stoppedBeforeLock = false
    lock.onRequest = { stoppedBeforeLock = !radio.isConnected && !radio.isScanning }
    app.process(.bluetoothChanged(.unavailable), now: 905)
    try check(lock.calls == 1 && app.lastConfirmedLock == nil && app.lockError != nil, "failed lock reported as success")
    app.tick(now: 1000)
    try check(lock.calls == 1 && !app.engine.isActive, "failed lock retry")
    try check(app.statusSymbolName == "shield", "faulted monitoring uses plain shield")
    try check(stoppedBeforeLock, "radio stop must precede lock request")
    lock.unavailable = false
    app.process(.bluetoothChanged(.available), now: 1001)
    app.process(.resume, now: 1002)
    app.tick(now: 1017)
    try check(lock.calls == 2 && app.lastConfirmedLock == nil, "return zero alone is not confirmation")
    app.tick(now: 1020)
    try check(app.lockError != nil && !app.engine.isActive, "unconfirmed lock suspends coordinator")
    app.tick(now: 2000)
    try check(lock.calls == 2, "unconfirmed lock must not retry")
    let ownedTimer = app.ticker
    app.shutdown()
    try check(ownedTimer == nil || ownedTimer?.isValid == false, "timer invalidated")
    try check(app.ticker == nil && !radio.isConnected && !radio.isScanning, "owned cleanup")
    try check(loginItemText(status: .requiresApproval, error: nil).contains("разрешение"), "login approval")
    try check(loginItemText(status: .enabled, error: "failure").contains("failure"), "login error")
    try check(loginItemText(status: .notRegistered, error: nil).contains("выключен"), "login unregistered")
    try check(loginItemText(status: .notFound, error: nil).contains("не найдено"), "login missing")
    print("PASS: session compatibility, explicit lock confirmation, discovery/resume refresh, owned session polling, storage preservation, fake coordinator, calibration/session/pause, lock failure, timer cleanup, login status. No real Bluetooth/UI/lock invoked.")
}
