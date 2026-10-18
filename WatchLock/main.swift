import AppKit

if CommandLine.arguments.contains("--self-check") {
    do { try runSelfChecks(); exit(0) }
    catch { fputs("Self-check failed: \(error)\n", stderr); exit(1) }
}
let application = NSApplication.shared
let delegate = AppDelegate(lockAdapter: ScreenLockAdapter(), radio: BLE(), store: ConfigurationStore(defaults: .standard))
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
