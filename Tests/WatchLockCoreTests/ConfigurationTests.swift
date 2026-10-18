import Foundation
import Testing
@testable import WatchLockCore

struct ConfigurationTests {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Test func testDefaultsAndRoundTrip() throws {
        let settings = DeviceSettings()
        XCTAssertEqual(settings.threshold, -75)
        XCTAssertEqual(settings.weakSignalDelay, 5)
        XCTAssertEqual(settings.noSignalTimeout, 15)
        var config = Configuration()
        XCTAssertFalse(config.monitoringEnabled)
        try config.add(SavedDevice(id: id, name: " ", settings: settings))
        XCTAssertEqual(config.devices[0].name, id.uuidString)
        try config.selectPrimary(id)
        config.monitoringEnabled = true
        XCTAssertEqual(try Configuration.decode(config.encoded()), config)
        config.remove(id)
        XCTAssertNil(config.primaryID)
        XCTAssertFalse(config.monitoringEnabled)
    }
    @Test func testInvalidInputsAreRejectedWithoutMutation() throws {
        var config = Configuration()
        let device = SavedDevice(id: id, name: "Watch")
        try config.add(device)
        XCTAssertThrowsError(try config.add(device))
        XCTAssertThrowsError(try config.selectPrimary(UUID()))
        let before = config
        XCTAssertThrowsError(try config.update(SavedDevice(id: id, name: "bad", settings: DeviceSettings(threshold: .nan))))
        XCTAssertEqual(config, before)
        for settings in [DeviceSettings(threshold: -101), DeviceSettings(threshold: -29), DeviceSettings(weakSignalDelay: 0), DeviceSettings(weakSignalDelay: 61), DeviceSettings(noSignalTimeout: 4), DeviceSettings(noSignalTimeout: 301)] {
            XCTAssertThrowsError(try settings.validate())
        }
        config.version = 2
        XCTAssertThrowsError(try config.encoded())
        XCTAssertThrowsError(try Configuration.decode(Data("not JSON".utf8)))
    }
    @Test func testDecodedDuplicateAndUnknownPrimary() throws {
        let device = SavedDevice(id: id, name: "Watch")
        var config = Configuration(devices: [device, device])
        XCTAssertThrowsError(try config.validate())
        config.devices = [device]
        config.primaryID = UUID()
        XCTAssertThrowsError(try config.validate())
    }
}

func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T) { #expect(actual == expected) }
func XCTAssertFalse(_ value: Bool) { #expect(!value) }
func XCTAssertTrue(_ value: Bool) { #expect(value) }
func XCTAssertNil<T>(_ value: T?) { #expect(value == nil) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T) { #expect(throws: (any Error).self) { _ = try expression() } }
