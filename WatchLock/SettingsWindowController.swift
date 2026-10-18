import AppKit

struct DiscoveryDevice: Equatable { let id: UUID; let name: String; let rssi: Int }
struct SettingsSnapshot {
    let configuration: Configuration
    let engine: MonitoringEngine
    let calibration: Calibration
    let discovered: [DiscoveryDevice]
    let connected: Bool
    let scanning: Bool
    let age: TimeInterval?
    let screen: ScreenState
    let message: String
    let history: String
    let loginText: String
}
enum SettingsAction {
    case add(DiscoveryDevice), remove(UUID), makePrimary(UUID), save(SavedDevice), enable(Bool)
    case startDiscovery, stopDiscovery, pause(Int), resume, calibrateDesk, calibrateAway, cancelCalibration, applyCalibration, toggleLogin
}

final class SettingsWindowController: NSWindowController {
    private let action: (SettingsAction) -> Void
    private var snapshot: SettingsSnapshot?
    private var editing: SavedDevice?
    private let devices = NSPopUpButton()
    private let discoveries = NSPopUpButton()
    private let name = NSTextField()
    private let threshold = NSTextField()
    private let weakDelay = NSTextField()
    private let noSignal = NSTextField()
    private let enabled = NSButton(checkboxWithTitle: "Мониторинг основного устройства", target: nil, action: nil)
    private let diagnostic = NSTextField(wrappingLabelWithString: "")
    private let warning = NSTextField(wrappingLabelWithString: "")
    private let history = NSTextField(wrappingLabelWithString: "")
    private let calibrationInfo = NSTextField(wrappingLabelWithString: "")
    private let loginInfo = NSTextField(wrappingLabelWithString: "")
    private var scanButton: NSButton!
    private var awayButton: NSButton!
    private var applyButton: NSButton!
    private var deskButton: NSButton!
    private var deviceButtons: [NSButton] = []
    private var addButton: NSButton!

    init(action: @escaping (SettingsAction) -> Void) {
        self.action = action
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 690), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WatchLock — настройки"; window.center(); window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }
    required init?(coder: NSCoder) { nil }
    private func label(_ text: String) -> NSTextField { NSTextField(labelWithString: text) }
    private func button(_ title: String, _ selector: Selector) -> NSButton { NSButton(title: title, target: self, action: selector) }
    private func row(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
        return row
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)])
        let intro = NSTextField(wrappingLabelWithString: "Только блокировка. Штатная разблокировка macOS / Apple Watch остаётся без изменений. RSSI не доказывает расстояние, личность или ношение часов.")
        intro.textColor = .secondaryLabelColor; stack.addArrangedSubview(intro)
        devices.target = self; devices.action = #selector(selectedDevice)
        devices.widthAnchor.constraint(equalToConstant: 400).isActive = true
        devices.setAccessibilityLabel("Сохранённое устройство")
        let primary = button("Сделать основным", #selector(makePrimary))
        let remove = button("Удалить…", #selector(removeDevice))
        deviceButtons = [primary, remove]
        stack.addArrangedSubview(row(label("Устройства:"), devices))
        stack.addArrangedSubview(row(primary, remove))
        discoveries.widthAnchor.constraint(equalToConstant: 420).isActive = true
        discoveries.setAccessibilityLabel("Найденное BLE-устройство")
        scanButton = button("Поиск 20 с", #selector(toggleScan))
        addButton = button("Добавить", #selector(addDevice))
        stack.addArrangedSubview(row(discoveries, scanButton, addButton))
        name.widthAnchor.constraint(equalToConstant: 350).isActive = true
        name.setAccessibilityLabel("Имя устройства")
        for (field, title) in [(threshold, "Порог dBm"), (weakDelay, "Задержка слабого сигнала в секундах"), (noSignal, "Тайм-аут потери сигнала в секундах")] {
            field.widthAnchor.constraint(equalToConstant: 75).isActive = true; field.setAccessibilityLabel(title)
        }
        let save = button("Сохранить", #selector(saveDevice)); deviceButtons.append(save)
        stack.addArrangedSubview(row(label("Имя:"), name, save))
        stack.addArrangedSubview(row(label("Порог dBm:"), threshold, label("Задержка с:"), weakDelay, label("Потеря с:"), noSignal))
        enabled.target = self; enabled.action = #selector(toggleEnabled)
        stack.addArrangedSubview(row(enabled, button("Возобновить", #selector(resume))))
        let pauses = [15, 30, 60].map { minutes -> NSButton in
            let b = button("Пауза \(minutes) мин", #selector(pause(_:))); b.tag = minutes; return b
        }
        stack.addArrangedSubview(NSStackView(views: pauses))
        diagnostic.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(diagnostic)
        deskButton = button("1. За столом", #selector(startDesk))
        awayButton = button("2. Вдали", #selector(startAway))
        applyButton = button("Применить порог", #selector(applyCalibration))
        stack.addArrangedSubview(row(label("Калибровка:"), deskButton, awayButton, applyButton, button("Отмена", #selector(cancelCalibration))))
        stack.addArrangedSubview(calibrationInfo)
        stack.addArrangedSubview(history)
        stack.addArrangedSubview(row(button("Переключить запуск при входе", #selector(toggleLogin))))
        stack.addArrangedSubview(loginInfo)
        warning.textColor = .systemRed; stack.addArrangedSubview(warning)
        let footer = NSTextField(wrappingLabelWithString: "Основное устройство — единственный источник присутствия. iPhone на столе не предотвращает блокировку. Возможны ложные блокировки. Адаптер блокировки использует закрытый API macOS. BLEUnlock © 2019–2022 Takeshi Sone · MIT.")
        footer.textColor = .secondaryLabelColor; footer.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(footer)
        for view in [intro, diagnostic, calibrationInfo, history, loginInfo, warning, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    func render(_ snapshot: SettingsSnapshot) {
        self.snapshot = snapshot
        let previousID = selectedID()
        devices.removeAllItems()
        for device in snapshot.configuration.devices {
            devices.addItem(withTitle: (device.id == snapshot.configuration.primaryID ? "★ " : "") + device.name + " · " + device.id.uuidString.prefix(8))
            devices.lastItem?.representedObject = device.id
        }
        if let id = previousID ?? snapshot.configuration.primaryID, let index = snapshot.configuration.devices.firstIndex(where: { $0.id == id }) { devices.selectItem(at: index) }
        loadSelected()
        let discoveryID = discoveries.selectedItem?.representedObject as? UUID
        discoveries.removeAllItems()
        for found in snapshot.discovered {
            discoveries.addItem(withTitle: "\(found.name) · \(found.rssi) dBm · \(found.id.uuidString.prefix(8))")
            discoveries.lastItem?.representedObject = found.id
        }
        if let id = discoveryID, let index = snapshot.discovered.firstIndex(where: { $0.id == id }) { discoveries.selectItem(at: index) }
        addButton.isEnabled = !snapshot.discovered.isEmpty
        scanButton.title = snapshot.scanning ? "Остановить поиск" : "Поиск 20 с"
        enabled.state = snapshot.configuration.monitoringEnabled ? .on : .off
        enabled.isEnabled = snapshot.configuration.primary != nil && (snapshot.engine.isBluetoothAvailable || snapshot.configuration.monitoringEnabled)
        let session = snapshot.screen == .unknown ? "неизвестен — мониторинг остановлен" : snapshot.screen == .locked ? "заблокирован" : "активен"
        diagnostic.stringValue = "Сеанс: \(session)\n\(snapshot.engine.state.russian) · соединение: \(snapshot.connected ? "да" : "нет") · scan: \(snapshot.scanning ? "да" : "нет")\nRSSI: \(snapshot.engine.rawRSSI.map(String.init) ?? "—") · среднее: \(snapshot.engine.smoothedRSSI.map { String(format: "%.1f", $0) } ?? "—") dBm · возраст: \(snapshot.age.map { String(format: "%.0f с", $0) } ?? "—")\nUUID: \(snapshot.configuration.primaryID?.uuidString ?? "—")\(snapshot.engine.pauseUntil != nil ? " · пауза активна" : "")"
        deskButton.isEnabled = snapshot.engine.isActive && snapshot.connected
        awayButton.isEnabled = snapshot.calibration.canStartAway
        applyButton.isEnabled = snapshot.calibration.proposedThreshold != nil
        switch snapshot.calibration.stage {
        case .idle: calibrationInfo.stringValue = "По 20 измерений за 90 с: сначала за столом, затем там, где Mac должен блокироваться."
        case .desk: calibrationInfo.stringValue = "За столом: \(snapshot.calibration.count)/20. \(snapshot.calibration.canStartAway ? "Отойдите и начните этап 2." : "Оставайтесь на рабочем месте.")"
        case .away: calibrationInfo.stringValue = "Вдали: \(snapshot.calibration.count)/20. Автоблокировка временно подавлена."
        case .ready: calibrationInfo.stringValue = "Предложен порог \(snapshot.calibration.proposedThreshold.map { String(format: "%.1f", $0) } ?? "—") dBm. Настройки ещё не изменены."
        case .failed(let reason): calibrationInfo.stringValue = "Калибровка: \(reason)"
        }
        history.stringValue = snapshot.history; loginInfo.stringValue = snapshot.loginText
        warning.stringValue = snapshot.message
    }
    private func selectedID() -> UUID? { devices.selectedItem?.representedObject as? UUID }
    private func loadSelected() {
        let device = snapshot?.configuration.devices.first { $0.id == selectedID() }
        for button in deviceButtons { button.isEnabled = device != nil }
        for field in [name, threshold, weakDelay, noSignal] { field.isEnabled = device != nil }
        guard device != editing else { return }
        editing = device
        name.stringValue = device?.name ?? ""
        threshold.stringValue = device.map { String($0.settings.threshold) } ?? ""
        weakDelay.stringValue = device.map { String($0.settings.weakSignalDelay) } ?? ""
        noSignal.stringValue = device.map { String($0.settings.noSignalTimeout) } ?? ""
    }
    @objc private func selectedDevice() { editing = nil; loadSelected() }
    @objc private func makePrimary() { if let id = selectedID() { action(.makePrimary(id)) } }
    @objc private func removeDevice() {
        guard let device = editing else { return }
        let alert = NSAlert(); alert.messageText = "Удалить \(device.name)?"
        alert.informativeText = "Удаление основного устройства выключит мониторинг."
        alert.addButton(withTitle: "Удалить"); alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn { action(.remove(device.id)) }
    }
    @objc private func addDevice() {
        guard let id = discoveries.selectedItem?.representedObject as? UUID, let found = snapshot?.discovered.first(where: { $0.id == id }) else { return }
        action(.add(found))
    }
    @objc private func saveDevice() {
        guard var device = editing else { return }
        guard let t = Double(threshold.stringValue), let w = Double(weakDelay.stringValue), let n = Double(noSignal.stringValue) else { warning.stringValue = "Введите числовые значения (дробная часть через точку)."; return }
        device.name = name.stringValue; device.settings = DeviceSettings(threshold: t, weakSignalDelay: w, noSignalTimeout: n)
        action(.save(device))
    }
    @objc private func toggleEnabled() { action(.enable(enabled.state == .on)) }
    @objc private func toggleScan() { action(snapshot?.scanning == true ? .stopDiscovery : .startDiscovery) }
    @objc private func pause(_ sender: NSButton) { action(.pause(sender.tag)) }
    @objc private func resume() { action(.resume) }
    @objc private func startDesk() { action(.calibrateDesk) }
    @objc private func startAway() { action(.calibrateAway) }
    @objc private func cancelCalibration() { action(.cancelCalibration) }
    @objc private func applyCalibration() { action(.applyCalibration) }
    @objc private func toggleLogin() { action(.toggleLogin) }
}
