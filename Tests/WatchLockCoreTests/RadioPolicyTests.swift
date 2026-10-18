import Foundation
import Testing
@testable import WatchLockCore

struct RadioPolicyTests {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    @Test func testDiscoveryBoundAndStop() {
        var p = RadioPolicy()
        #expect(p.handle(.startDiscovery, now: 0) == [.startScan(discovery: true)])
        #expect(p.handle(.startDiscovery, now: 1).isEmpty)
        #expect(p.nextDeadline == 20)
        #expect(p.handle(.tick, now: 20) == [.stopScan])
        #expect(p.nextDeadline == nil)
        _ = p.handle(.startDiscovery, now: 21)
        #expect(p.handle(.stopDiscovery, now: 22) == [.stopScan])
        #expect(p.handle(.stop, now: 23).isEmpty)
    }
    @Test func testRecoveryDutyCycleAndForeignDevice() {
        var p = RadioPolicy()
        #expect(p.handle(.monitor(id: id, generation: 1), now: 0) == [.connect(id, 1)])
        #expect(p.handle(.tick, now: 5) == [.disconnect(id), .startScan(discovery: false)])
        #expect(p.handle(.discovered(id: UUID(), generation: 1), now: 6).isEmpty)
        #expect(p.handle(.tick, now: 10) == [.stopScan])
        #expect(p.nextDeadline == 35)
        #expect(p.handle(.tick, now: 34).isEmpty)
        #expect(p.handle(.tick, now: 35) == [.connect(id, 1)])
    }
    @Test func testConnectedPollingAndCancellation() {
        var p = RadioPolicy()
        _ = p.handle(.monitor(id: id, generation: 1), now: 0)
        _ = p.handle(.tick, now: 5)
        #expect(p.handle(.discovered(id: id, generation: 1), now: 6) == [.stopScan, .connect(id, 1)])
        #expect(p.handle(.connected(id: id, generation: 1), now: 7) == [.readRSSI(id, 1)])
        #expect(p.handle(.tick, now: 9).isEmpty)
        _ = p.handle(.rssiCompleted(id: id, generation: 1), now: 9)
        #expect(p.handle(.tick, now: 9) == [.readRSSI(id, 1)])
        #expect(p.handle(.stop, now: 10) == [.disconnect(id)])
        #expect(p.nextDeadline == nil)
        #expect(p.handle(.connected(id: id, generation: 1), now: 11) == [.disconnect(id)])
        #expect(p.handle(.stop, now: 12).isEmpty)
    }
    @Test func testReplacementAndLateGenerations() {
        var p = RadioPolicy()
        _ = p.handle(.monitor(id: id, generation: 1), now: 0)
        _ = p.handle(.tick, now: 5)
        #expect(p.handle(.startDiscovery, now: 6) == [.stopScan, .startScan(discovery: true)])
        #expect(p.nextDeadline == 26)
        _ = p.handle(.monitor(id: UUID(), generation: 2), now: 7)
        _ = p.handle(.monitor(id: id, generation: 3), now: 8)
        #expect(p.handle(.connected(id: id, generation: 1), now: 9) == [.disconnect(id)])
        #expect(p.handle(.rssiCompleted(id: id, generation: 1), now: 10).isEmpty)
    }
    @Test func testEarlyConnectionFailureStartsScanNotLongWait() {
        var p = RadioPolicy()
        _ = p.handle(.monitor(id: id, generation: 1), now: 0)
        #expect(p.handle(.disconnected(id: id, generation: 1), now: 1) == [.startScan(discovery: false)])
        #expect(p.nextDeadline == 6)
        #expect(p.handle(.tick, now: 6) == [.stopScan])
        #expect(p.nextDeadline == 31)
    }
    @Test func testLinkLossRetriesKnownOnceBeforeScan() {
        var p = RadioPolicy()
        _ = p.handle(.monitor(id: id, generation: 1), now: 0)
        _ = p.handle(.connected(id: id, generation: 1), now: 1)
        #expect(p.handle(.disconnected(id: id, generation: 1), now: 2) == [.connect(id, 1)])
        #expect(p.handle(.disconnected(id: id, generation: 1), now: 3) == [.startScan(discovery: false)])
        #expect(p.handle(.discovered(id: id, generation: 1), now: 4) == [.stopScan, .connect(id, 1)])
        #expect(p.handle(.disconnected(id: id, generation: 1), now: 5).isEmpty)
        #expect(p.nextDeadline == 30)
        #expect(p.handle(.tick, now: 29).isEmpty)
        #expect(p.handle(.tick, now: 30) == [.connect(id, 1)])
    }
    @Test func testImmediateRecoveredLinkLossCannotSpin() {
        var p = RadioPolicy()
        _ = p.handle(.monitor(id: id, generation: 1), now: 0)
        _ = p.handle(.connected(id: id, generation: 1), now: 1)
        _ = p.handle(.disconnected(id: id, generation: 1), now: 2)
        _ = p.handle(.connected(id: id, generation: 1), now: 3)
        #expect(p.handle(.disconnected(id: id, generation: 1), now: 4).isEmpty)
        #expect(p.nextDeadline == 29)
        #expect(p.handle(.tick, now: 28).isEmpty)
    }

    @Test func testOnlyExplicitSearchPublishesDiscoveryMode() {
        var p = RadioPolicy()
        _ = p.handle(.monitor(id: id, generation: 1), now: 0)
        _ = p.handle(.tick, now: 5)
        #expect(p.isScanning)
        #expect(!p.isDiscovering)
        _ = p.handle(.startDiscovery, now: 6)
        #expect(p.isDiscovering)
        _ = p.handle(.stopDiscovery, now: 7)
        #expect(!p.isDiscovering)
    }

}
