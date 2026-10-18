import Foundation
import Testing
@testable import WatchLockCore
struct CalibrationTests {
    @Test func testTwoStagesAndExplicitProposal() throws {
        var c = Calibration()
        c.startDesk(now: 0)
        for i in 0..<19 { c.add(rssi: -60, now: Double(i)) }
        #expect(c.count == 19); #expect(c.proposedThreshold == nil)
        c.add(rssi: 127, now: 20); #expect(c.count == 19)
        c.add(rssi: -60, now: 21)
        c.startAway(now: 22)
        for i in 0..<20 { c.add(rssi: -90, now: 23 + Double(i)) }
        #expect(c.stage == .ready); #expect(c.proposedThreshold == -75)
        c.cancel(); #expect(c.stage == .idle); #expect(c.proposedThreshold == nil)
        #expect(try Calibration.suggestThreshold(near: Array(repeating: -60, count: 20), far: Array(repeating: -90, count: 20)) == -75)
    }
    @Test func testTimeoutAndBadSeparation() {
        var c = Calibration(); c.startDesk(now: 0); c.tick(now: 89)
        #expect(c.stage == .desk)
        c.add(rssi: -60, now: 90)
        guard case .failed = c.stage else { Issue.record("Stage must expire at 90s"); return }
        XCTAssertThrowsError(try Calibration.suggestThreshold(near: Array(repeating: -70, count: 20), far: Array(repeating: -75, count: 20)))
        XCTAssertThrowsError(try Calibration.suggestThreshold(near: Array(repeating: -100, count: 20), far: Array(repeating: -120, count: 20)))
        XCTAssertThrowsError(try Calibration.suggestThreshold(near: Array(repeating: -60, count: 19), far: Array(repeating: -90, count: 20)))
    }
    @Test func testLinearPercentile() throws {
        // Near p20 = -71.2; far p80 = -92.8; midpoint = -82 exactly.
        #expect(abs(try Calibration.suggestThreshold(near: Array(-75 ... -56), far: Array(-108 ... -89)) + 82) < 0.000001)
    }
}
