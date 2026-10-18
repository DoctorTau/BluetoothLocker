import Foundation

enum CalibrationStage: Equatable { case idle, desk, away, ready, failed(String) }
enum CalibrationError: Error, LocalizedError {
    case notEnoughSamples, poorSeparation, outsideRange
    var errorDescription: String? {
        switch self {
        case .notEnoughSamples: return "Нужно 20 измерений на каждом этапе."
        case .poorSeparation: return "Сигналы слишком похожи: разница должна быть не меньше 10 dB."
        case .outsideRange: return "Предложенный порог вне диапазона −100…−30 dBm."
        }
    }
}
struct Calibration {
    private(set) var stage: CalibrationStage = .idle
    private(set) var count = 0
    private(set) var proposedThreshold: Double?
    private(set) var deadline: TimeInterval?
    private var near: [Int] = []
    private var far: [Int] = []
    var isRunning: Bool { stage == .desk || stage == .away }
    var canStartAway: Bool { stage == .desk && near.count == 20 }
    mutating func startDesk(now: TimeInterval) { cancel(); stage = .desk; deadline = now + 90 }
    mutating func startAway(now: TimeInterval) {
        guard canStartAway else { return }
        stage = .away; count = 0; deadline = now + 90
    }
    mutating func add(rssi: Int, now: TimeInterval) {
        tick(now: now)
        guard deadline != nil, isRunning, (-127 ... -1).contains(rssi), count < 20 else { return }
        if stage == .desk { near.append(rssi) } else { far.append(rssi) }
        count += 1
        if count == 20 {
            deadline = nil
            if stage == .away {
                do { proposedThreshold = try Self.suggestThreshold(near: near, far: far); stage = .ready }
                catch { stage = .failed(error.localizedDescription) }
            }
        }
    }
    mutating func tick(now: TimeInterval) {
        if let deadline, now >= deadline { self.deadline = nil; stage = .failed("За 90 секунд не получено 20 измерений. Проверьте подключение.") }
    }
    mutating func cancel() { self = Self() }
    static func suggestThreshold(near: [Int], far: [Int]) throws -> Double {
        guard near.count >= 20, far.count >= 20 else { throw CalibrationError.notEnoughSamples }
        guard (near + far).allSatisfy({ (-127 ... -1).contains($0) }) else { throw CalibrationError.outsideRange }
        let lowNear = percentile(near, fraction: 0.2), highFar = percentile(far, fraction: 0.8)
        guard lowNear - highFar >= 10 else { throw CalibrationError.poorSeparation }
        let proposed = (lowNear + highFar) / 2
        guard (-100 ... -30).contains(proposed) else { throw CalibrationError.outsideRange }
        return proposed
    }
    private static func percentile(_ values: [Int], fraction: Double) -> Double {
        let sorted = values.sorted()
        let index = Double(sorted.count - 1) * fraction
        let low = Int(index), high = min(low + 1, sorted.count - 1)
        return Double(sorted[low]) + (Double(sorted[high]) - Double(sorted[low])) * (index - Double(low))
    }
}
