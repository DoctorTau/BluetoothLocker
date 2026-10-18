import Foundation

enum ConfigurationError: Error, LocalizedError {
    case invalidSettings, duplicateDevice, unknownDevice, unsupportedVersion, missingPrimary
    var errorDescription: String? {
        switch self {
        case .invalidSettings: return "Порог: −100…−30 dBm, задержка: 1…60 с, потеря сигнала: 5…300 с."
        case .duplicateDevice: return "Устройство уже сохранено."
        case .unknownDevice: return "Устройство не найдено."
        case .unsupportedVersion: return "Неизвестная версия настроек; исходные данные сохранены."
        case .missingPrimary: return "Сначала выберите основное устройство."
        }
    }
}

struct DeviceSettings: Codable, Equatable {
    var threshold: Double = -75
    var weakSignalDelay: TimeInterval = 5
    var noSignalTimeout: TimeInterval = 15
    func validate() throws {
        guard threshold.isFinite, (-100 ... -30).contains(threshold),
              weakSignalDelay.isFinite, (1 ... 60).contains(weakSignalDelay),
              noSignalTimeout.isFinite, (5 ... 300).contains(noSignalTimeout) else {
            throw ConfigurationError.invalidSettings
        }
    }
}

struct SavedDevice: Codable, Equatable {
    var id: UUID
    var name: String
    var settings = DeviceSettings()
    var normalized: SavedDevice {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = id.uuidString }
        return copy
    }
}

struct Configuration: Codable, Equatable {
    var version = 1
    var devices: [SavedDevice] = []
    var primaryID: UUID?
    var monitoringEnabled = false
    var primary: SavedDevice? { devices.first { $0.id == primaryID } }

    func validate() throws {
        guard version == 1 else { throw ConfigurationError.unsupportedVersion }
        guard Set(devices.map(\.id)).count == devices.count else { throw ConfigurationError.duplicateDevice }
        for device in devices { try device.settings.validate() }
        if let primaryID, !devices.contains(where: { $0.id == primaryID }) { throw ConfigurationError.unknownDevice }
        if monitoringEnabled && primaryID == nil { throw ConfigurationError.missingPrimary }
    }
    static func decode(_ data: Data) throws -> Configuration {
        var config = try JSONDecoder().decode(Self.self, from: data)
        try config.validate()
        config.devices = config.devices.map(\.normalized)
        return config
    }
    func encoded() throws -> Data { try validate(); return try JSONEncoder().encode(self) }
    mutating func add(_ device: SavedDevice) throws {
        guard !devices.contains(where: { $0.id == device.id }) else { throw ConfigurationError.duplicateDevice }
        try device.settings.validate()
        devices.append(device.normalized)
    }
    mutating func update(_ device: SavedDevice) throws {
        guard let index = devices.firstIndex(where: { $0.id == device.id }) else { throw ConfigurationError.unknownDevice }
        try device.settings.validate()
        devices[index] = device.normalized
    }
    mutating func selectPrimary(_ id: UUID) throws {
        guard devices.contains(where: { $0.id == id }) else { throw ConfigurationError.unknownDevice }
        primaryID = id
    }
    mutating func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        if primaryID == id { primaryID = nil; monitoringEnabled = false }
    }
}
