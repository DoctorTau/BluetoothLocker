import Foundation

enum ConfigurationStoreError: Error, LocalizedError {
    case corruptStorage
    var errorDescription: String? { "Настройки повреждены. Они не перезаписаны; мониторинг выключен. Сохраните исходные данные перед ручным сбросом домена WatchLock." }
}
final class ConfigurationStore {
    static let key = "WatchLock.configuration.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }
    func load() throws -> Configuration {
        guard let value = defaults.object(forKey: Self.key) else { return Configuration() }
        guard let data = value as? Data else { throw ConfigurationStoreError.corruptStorage }
        return try Configuration.decode(data)
    }
    func save(_ configuration: Configuration) throws { defaults.set(try configuration.encoded(), forKey: Self.key) }
}
