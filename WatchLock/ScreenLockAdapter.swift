import Foundation
import CoreGraphics
import Darwin

protocol ScreenLocking {
    func screenState() -> ScreenState
    func requestLock() throws -> Int32
}

enum ScreenLockError: Error, LocalizedError {
    case unavailableFramework, unavailableSymbol
    var errorDescription: String? {
        switch self {
        case .unavailableFramework: return "Системный адаптер блокировки недоступен. Мониторинг приостановлен."
        case .unavailableSymbol: return "Функция блокировки не поддерживается этой версией macOS."
        }
    }
}

final class ScreenLockAdapter: ScreenLocking {
    // Private API inherited from BLEUnlock; unsupported by Apple and isolated here.
    static let notifications = ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"].map { Notification.Name($0) }
    static let lockFlagKey = "CGSSessionScreenIsLocked"
    private var handle: UnsafeMutableRawPointer?
    deinit { if let handle { dlclose(handle) } }
    func screenState() -> ScreenState {
        Self.parseSession(CGSessionCopyCurrentDictionary() as? [String: Any])
    }
    static func parseSession(_ session: [String: Any]?) -> ScreenState {
        guard let session else { return .unknown }
        // macOS can omit the flag in an active session; absence never confirms a lock.
        if let flag = session[lockFlagKey] {
            let state = parseLockFlag(flag)
            if state != .unlocked { return state }
        }
        guard let onConsole = session[kCGSessionOnConsoleKey as String] as? NSNumber,
              let loginDone = session[kCGSessionLoginDoneKey as String] as? NSNumber,
              onConsole.doubleValue == 1, loginDone.doubleValue == 1 else { return .unknown }
        return .unlocked
    }
    static func parseLockFlag(_ value: Any?) -> ScreenState {
        guard let number = value as? NSNumber else { return .unknown }
        switch number.doubleValue {
        case 0: return .unlocked
        case 1: return .locked
        default: return .unknown
        }
    }
    func requestLock() throws -> Int32 {
        if handle == nil { handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW | RTLD_LOCAL) }
        guard let handle else { throw ScreenLockError.unavailableFramework }
        guard let symbol = dlsym(handle, "SACLockScreenImmediate") else { throw ScreenLockError.unavailableSymbol }
        typealias LockFunction = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: LockFunction.self)()
    }
}
