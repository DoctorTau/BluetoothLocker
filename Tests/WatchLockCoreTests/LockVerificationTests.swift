import Testing
@testable import WatchLockCore
struct LockVerificationTests {
    @Test func testConfirmedOnlyFromLockedStateOnce() {
        var v = LockVerification(returnCode: 0, now: 0)
        #expect(v.observe(.unlocked, now: 2) == nil)
        #expect(v.observe(.locked, now: 2.5) == .confirmed)
        #expect(v.observe(.locked, now: 3) == nil)
    }
    @Test func testTimeoutAndNonzeroCode() {
        var v = LockVerification(returnCode: 0, now: 0)
        #expect(v.observe(.unknown, now: 2) == nil)
        guard case .failed = v.observe(.unknown, now: 3) else { Issue.record("Unknown screen must fail at deadline"); return }
        #expect(v.observe(.locked, now: 4) == nil)
        v = LockVerification(returnCode: 9, now: 0)
        guard case .failed = v.observe(.locked, now: 0) else { Issue.record("Nonzero code cannot be success"); return }
        v = LockVerification(returnCode: 0, now: 0)
        guard case .failed = v.observe(.unlocked, now: 3) else { Issue.record("Unlocked screen must fail at deadline"); return }
    }
}
