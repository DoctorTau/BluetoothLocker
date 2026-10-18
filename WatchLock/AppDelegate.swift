import AppKit
import ServiceManagement
import Darwin

func monotonicNow() -> TimeInterval {
    var scale = mach_timebase_info_data_t()
    mach_timebase_info(&scale)
    return Double(mach_continuous_time()) * Double(scale.numer) / Double(scale.denom) / 1_000_000_000
}

func loginItemText(status: SMAppService.Status, error: String?) -> String {
    let text: String
    switch status {
    case .enabled: text = "Запуск при входе: включён"
    case .requiresApproval: text = "Запуск при входе: требуется разрешение в Системных настройках"
    case .notRegistered: text = "Запуск при входе: выключен"
    case .notFound: text = "Запуск при входе: приложение не найдено"
    @unknown default: text = "Запуск при входе: неизвестный статус"
    }
    return error.map { text + " · " + $0 } ?? text
}

enum CoordinatorError: Error, LocalizedError {
    case bluetoothUnavailable
    var errorDescription: String? { "Включение мониторинга требует доступного Bluetooth." }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let lockAdapter: any ScreenLocking
    private let radio: any BLEControlling
    private let store: ConfigurationStore
    private var storageWritable = true
    private(set) var configuration = Configuration()
    private(set) var engine = MonitoringEngine()
    private(set) var calibration = Calibration()
    private(set) var ticker: Timer?
    private(set) var lastConfirmedLock: Date?
    private var lastAttempt: Date?
    private var lastReason: LockReason?
    private(set) var lockError: String?
    private var message: String?
    private var loginError: String?
    private var verification: LockVerification?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var discovered: [UUID: DiscoveryDevice] = [:]
    private var statusItem: NSStatusItem?
    private var settings: SettingsWindowController?
    private var statusMenu: NSMenuItem?
    private var enableMenu: NSMenuItem?
    private var screen: ScreenState = .unknown
    private var stopped = false

    var statusSymbolName: String { engine.isActive ? "lock.shield" : "shield" }

    init(lockAdapter: any ScreenLocking, radio: any BLEControlling, store: ConfigurationStore) {
        self.lockAdapter = lockAdapter; self.radio = radio; self.store = store
        super.init()
        do { configuration = try store.load() }
        catch { storageWritable = false; message = "Не удалось прочитать настройки: \(error.localizedDescription)" }
        radio.onMeasurement = { [weak self] id, rssi, epoch in
            guard let self, self.engine.isActive, self.configuration.primaryID == id, self.engine.generation == epoch else { return }
            let now = monotonicNow()
            let running = self.calibration.isRunning
            self.calibration.add(rssi: rssi, now: now)
            if running && !self.calibration.isRunning { self.process(.calibrationChanged(false), now: now) }
            self.process(.sample(id: id, rssi: rssi, generation: epoch), now: now)
        }
        radio.onAvailability = { [weak self] value in self?.process(.bluetoothChanged(value), now: monotonicNow()) }
        radio.onConnectionChanged = { [weak self] connected in
            guard let self else { return }
            if !connected { self.cancelCalibration(now: monotonicNow()) }
            self.refresh()
        }
        radio.onDiscovery = { [weak self] id, name, rssi in
            guard let self, self.radio.isScanning else { return }
            let device = DiscoveryDevice(id: id, name: name ?? id.uuidString, rssi: rssi)
            guard self.discovered[id] != device else { return }
            self.discovered[id] = device
            self.refresh()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu(); menu.autoenablesItems = false
        statusMenu = menu.addItem(withTitle: "WatchLock", action: nil, keyEquivalent: "")
        statusMenu?.isEnabled = false
        enableMenu = menu.addItem(withTitle: "Включить мониторинг", action: #selector(toggleMonitoring), keyEquivalent: "")
        menu.addItem(withTitle: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Возобновить / снять ошибку", action: #selector(resumeMonitoring), keyEquivalent: "")
        let pauses = NSMenu()
        for minutes in [15, 30, 60] {
            let item = pauses.addItem(withTitle: "\(minutes) минут", action: #selector(pauseMonitoring(_:)), keyEquivalent: "")
            item.tag = minutes; item.target = self
        }
        let pauseItem = menu.addItem(withTitle: "Пауза", action: nil, keyEquivalent: "")
        pauseItem.submenu = pauses
        menu.addItem(.separator())
        menu.addItem(withTitle: "Заблокировать Mac…", action: #selector(manualLock), keyEquivalent: "")
        menu.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items where item.action != nil { item.target = self }
        statusItem?.menu = menu
        settings = SettingsWindowController { [weak self] action in self?.perform(action) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.process(.sleep, now: monotonicNow()) }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            guard let self else { return }
            self.checkSession(now: monotonicNow())
            self.process(.wake, now: monotonicNow())
        }
        for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { [weak self] in self?.checkSession(now: monotonicNow()) }
        }
        for name in ScreenLockAdapter.notifications {
            observe(DistributedNotificationCenter.default(), name) { [weak self] in self?.checkSession(now: monotonicNow()) }
        }
        checkSession(now: monotonicNow())
        if configuration.monitoringEnabled, let primary = configuration.primary { process(.start(primary: primary), now: monotonicNow()) }
        refresh()
        if configuration.devices.isEmpty || message != nil { showSettings() }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ callback: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in callback() }
        observations.append((center, token))
    }
    func process(_ event: MonitoringEvent, now: TimeInterval) {
        guard !stopped else { return }
        switch event {
        case .sleep, .pause, .stop:
            cancelCalibration(now: now); radio.stop()
        case .sessionChanged(let value):
            screen = value
            if value != .unlocked { cancelCalibration(now: now); radio.stop() }
        case .bluetoothChanged(let value):
            if value != .available { cancelCalibration(now: now) }
        default: break
        }
        execute(engine.handle(event, now: now), now: now)
        refresh()
    }
    private func execute(_ effects: [MonitoringEffect], now: TimeInterval) {
        for effect in effects {
            switch effect {
            case .requestLock(let reason): attemptLock(reason: reason, now: now)
            case .startRadio: radio.apply(effect, now: now)
            case .stopRadio: radio.stop()
            }
        }
    }
    private func attemptLock(reason: LockReason, now: TimeInterval) {
        guard verification == nil else { return }
        radio.stop(); cancelCalibration(now: now)
        lastAttempt = Date(); lastReason = reason; lockError = nil
        do {
            verification = LockVerification(returnCode: try lockAdapter.requestLock(), now: now)
            verifyLock(now: now)
        } catch {
            lockError = error.localizedDescription
            execute(engine.handle(.lockCompleted(.failed(error.localizedDescription)), now: now), now: now)
        }
    }
    private func verifyLock(now: TimeInterval) {
        guard var attempt = verification else { return }
        let outcome = attempt.observe(lockAdapter.screenState(), now: now)
        verification = outcome == nil ? attempt : nil
        if let outcome {
            if outcome == .confirmed { lastConfirmedLock = Date(); lockError = nil }
            if case .failed(let message) = outcome { lockError = message }
            execute(engine.handle(.lockCompleted(outcome), now: now), now: now)
        }
    }
    private func checkSession(now: TimeInterval) { process(.sessionChanged(lockAdapter.screenState()), now: now); verifyLock(now: now); refresh() }
    func tick(now: TimeInterval) {
        guard !stopped else { return }
        checkSession(now: now)
        radio.tick(now: now)
        let wasRunning = calibration.isRunning
        calibration.tick(now: now)
        if wasRunning && !calibration.isRunning { process(.calibrationChanged(false), now: now) }
        process(.tick, now: now)
        verifyLock(now: now)
        refresh()
    }
    func saveConfiguration(_ proposed: Configuration, now: TimeInterval) throws {
        guard storageWritable else { throw ConfigurationStoreError.corruptStorage }
        try proposed.validate()
        if proposed.monitoringEnabled && !configuration.monitoringEnabled && !engine.isBluetoothAvailable { throw CoordinatorError.bluetoothUnavailable }
        try store.save(proposed)
        if proposed.primary != configuration.primary || !proposed.monitoringEnabled { cancelCalibration(now: now) }
        configuration = proposed
        if proposed.monitoringEnabled, let primary = proposed.primary { process(.start(primary: primary), now: now) }
        else { process(.stop, now: now) }
    }
    func beginCalibration(now: TimeInterval) {
        guard engine.isActive, radio.isConnected else { message = "Калибровка требует включённого мониторинга и подключения к основному устройству."; refresh(); return }
        calibration.startDesk(now: now)
        process(.calibrationChanged(true), now: now)
    }
    private func cancelCalibration(now: TimeInterval) {
        guard calibration.stage != .idle else { return }
        calibration.cancel()
        execute(engine.handle(.calibrationChanged(false), now: now), now: now)
    }
    private func refresh() {
        let monitoringStatus = engine.isActive ? "Мониторинг активен" : "Мониторинг неактивен"
        statusItem?.button?.image = NSImage(systemSymbolName: statusSymbolName, accessibilityDescription: "WatchLock: \(monitoringStatus)")
        statusItem?.button?.toolTip = "\(monitoringStatus) · \(engine.state.russian)"
        let needsTicker = !stopped && (engine.needsTick || radio.nextDeadline != nil || calibration.deadline != nil || verification != nil)
        if needsTicker && ticker == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick(now: monotonicNow()) }
            timer.tolerance = 0.1; ticker = timer; RunLoop.main.add(timer, forMode: .common)
        } else if !needsTicker { ticker?.invalidate(); ticker = nil }
        statusMenu?.title = "\(engine.state.russian) · \(configuration.primary?.name ?? "основное не выбрано")"
        enableMenu?.title = configuration.monitoringEnabled ? "Выключить мониторинг" : "Включить мониторинг"
        enableMenu?.state = configuration.monitoringEnabled ? .on : .off
        enableMenu?.isEnabled = configuration.monitoringEnabled || (configuration.primary != nil && engine.isBluetoothAvailable)
        guard let settings else { return }
        let age = engine.lastMeasurementAt.map { max(0, monotonicNow() - $0) }
        var history = "Блокировок пока нет."
        if let lastAttempt, let lastReason { history = "Попытка: \(lastReason.russian), \(lastAttempt.formatted(date: .omitted, time: .standard))." }
        if let lastConfirmedLock { history += " Подтверждена: \(lastConfirmedLock.formatted(date: .omitted, time: .standard))." }
        settings.render(SettingsSnapshot(configuration: configuration, engine: engine, calibration: calibration,
            discovered: discovered.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            connected: radio.isConnected, scanning: radio.isScanning, age: age, screen: screen,
            message: [message, lockError, engine.fault == lockError ? nil : engine.fault].compactMap { $0 }.joined(separator: "\n"), history: history,
            loginText: loginItemText(status: SMAppService.mainApp.status, error: loginError)))
    }
    func perform(_ action: SettingsAction) {
        let now = monotonicNow()
        do {
            var proposed = configuration
            if storageWritable { message = nil }
            switch action {
            case .add(let device): try proposed.add(SavedDevice(id: device.id, name: device.name)); try saveConfiguration(proposed, now: now)
            case .remove(let id): proposed.remove(id); try saveConfiguration(proposed, now: now)
            case .makePrimary(let id): try proposed.selectPrimary(id); try saveConfiguration(proposed, now: now)
            case .save(let device): try proposed.update(device); try saveConfiguration(proposed, now: now)
            case .enable(let enabled): proposed.monitoringEnabled = enabled; try saveConfiguration(proposed, now: now)
            case .startDiscovery:
                checkSession(now: now)
                guard screen == .unlocked else { message = "Поиск доступен только в подтверждённом активном сеансе."; refresh(); return }
                discovered.removeAll(); radio.startDiscovery(now: now)
            case .stopDiscovery: radio.stopDiscovery(now: now)
            case .pause(let minutes): process(.pause(minutes: minutes), now: now)
            case .resume: checkSession(now: now); process(.resume, now: now)
            case .calibrateDesk: beginCalibration(now: now)
            case .calibrateAway: calibration.startAway(now: now)
            case .cancelCalibration: cancelCalibration(now: now)
            case .applyCalibration:
                guard let threshold = calibration.proposedThreshold, var device = proposed.primary else { return }
                device.settings.threshold = threshold
                try proposed.update(device); try saveConfiguration(proposed, now: now)
                cancelCalibration(now: now)
            case .toggleLogin:
                do {
                    if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval { try SMAppService.mainApp.unregister() }
                    else { try SMAppService.mainApp.register() }
                    loginError = nil
                } catch { loginError = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
        refresh()
    }
    @objc private func toggleMonitoring() { perform(.enable(!configuration.monitoringEnabled)) }
    @objc private func resumeMonitoring() { perform(.resume) }
    @objc private func pauseMonitoring(_ sender: NSMenuItem) { perform(.pause(sender.tag)) }
    @objc private func showSettings() { checkSession(now: monotonicNow()); settings?.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func manualLock() {
        let alert = NSAlert(); alert.messageText = "Заблокировать Mac сейчас?"
        alert.informativeText = "Понадобится штатная аутентификация macOS. WatchLock не разблокирует экран."
        alert.addButton(withTitle: "Заблокировать"); alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn {
            process(.sessionChanged(.unknown), now: monotonicNow())
            attemptLock(reason: .manual, now: monotonicNow()); refresh()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { shutdown() }
    func shutdown() {
        stopped = true; ticker?.invalidate(); ticker = nil; verification = nil
        calibration.cancel(); radio.stop()
        radio.onMeasurement = nil; radio.onAvailability = nil; radio.onConnectionChanged = nil; radio.onDiscovery = nil
        for (center, token) in observations { center.removeObserver(token) }
        observations.removeAll()
    }
}

extension MonitoringState {
    var russian: String {
        switch self {
        case .nearby: return "Рядом"
        case .far: return "Слабый сигнал"
        case .noSignal: return "Нет свежего сигнала"
        case .bluetoothUnavailable: return "Bluetooth недоступен"
        case .suspended: return "Приостановлено"
        }
    }
}
extension LockReason {
    var russian: String {
        switch self {
        case .weakSignal: return "слабый сигнал"
        case .noSignal: return "потеря сигнала"
        case .bluetoothUnavailable: return "Bluetooth выключен"
        case .permissionRevoked: return "разрешение Bluetooth отозвано"
        case .manual: return "вручную"
        }
    }
}
