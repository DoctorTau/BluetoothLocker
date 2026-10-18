import Foundation

struct LockVerification {
    let deadline: TimeInterval
    private let returnCode: Int32
    private var finished = false
    init(returnCode: Int32, now: TimeInterval) { self.returnCode = returnCode; deadline = now + 3 }
    mutating func observe(_ state: ScreenState, now: TimeInterval) -> LockOutcome? {
        guard !finished else { return nil }
        let outcome: LockOutcome?
        if returnCode != 0 { outcome = .failed("Системная блокировка вернула код \(returnCode).") }
        else if now > deadline { outcome = .failed("Подтверждение блокировки не получено за 3 секунды.") }
        else if state == .locked { outcome = .confirmed }
        else if now >= deadline { outcome = .failed("Состояние экрана входа не подтверждено за 3 секунды.") }
        else { outcome = nil }
        if outcome != nil { finished = true }
        return outcome
    }
}
