# WatchLock: technical specification

**English** · [Русский](2026-10-12-watchlock-design.ru.md)

Date: October 12, 2026. Status: design and written specification approved by the user in chat. The plan and Native execution were approved; implementation and actual checks are documented in [docs/VERIFICATION.md](../../VERIFICATION.md).

## Goal and scope

A personal menu bar app automatically locks the Mac when the primary BLE device, especially an Apple Watch, moves away. The app only locks the screen; macOS retains all unlocking. The UI is Russian, target OS is macOS 14+, and the first build targets Apple Silicon.

Base: [ts1/BLEUnlock, tag 1.12.2](https://github.com/ts1/BLEUnlock/tree/1.12.2), commit `c33a132f9b65ecd8fd55954a5e097a77b86c8a92`. GitHub confirmed that the tag matches the commit. Initially, the working directory contained only an empty Git repository. No local AGENTS.md existed; parent and user-provided instructions were considered.

A targeted fork of the existing AppKit/CoreBluetooth foundation was chosen rather than a SwiftUI rewrite. Useful menu construction, RSSI collection, and event-handling patterns are retained; unsafe or incompatible parts are replaced. No third-party dependencies, cloud, analytics, or runtime network communication are added. Publishing, pushing, installing into Applications, changing system settings, and notarization were outside the authorized actions.

## Upstream research findings

- BLE.swift starts general scanning automatically, connects to discovered devices to read their model, mixes transport with presence logic, and does not check RSSI read errors. Starting monitoring incorrectly establishes presence without a fresh measurement.
- AppDelegate.swift requests and stores a password in Keychain, simulates a keyboard, automatically unlocks, runs user scripts, controls media, and requests Accessibility. A lock call may fail yet its notification still reports success.
- LEDeviceInfo.swift reads internal Bluetooth SQLite databases; BLE.swift also reads a system plist. Neither is needed to store CoreBluetooth UUIDs.
- checkUpdate.swift makes a GitHub network request. lowlevel.c controls the display but does not perform a real lock.
- Launcher uses the old login-item model. The Xcode project links private login/MediaRemote frameworks and someone else's developer team, has a build script that mutates Info.plist, and targets macOS 10.13.
- The upstream README and Info.plist name Takeshi Sone and MIT. The selected tree has no separate LICENSE. For upstream images used there, the README also names Apache 2.0 and Google LLC.

## Components and affected areas

1. **Pure core:** device/settings models, state machine, scanning/connection deadline policy, and calibration calculations. It does not import CoreBluetooth/AppKit. It receives measurements and monotonic time explicitly and returns state and required actions.
2. **BLE.swift:** sole owner of CBCentralManager, the active CBPeripheral, and radio operations. All operations and callbacks run serially on the main queue. The transport supplies only validated primary-device measurements to the core.
3. **ScreenLockAdapter:** sole location of private API use and undocumented screen-state indicators. It distinguishes confirmed locking, failure, and inability to confirm.
4. **AppDelegate.swift and a small settings window:** menus, configuration persistence, state display, sleep/session coordination, launch at login, and calibration. The UI is created programmatically so a Command Line Tools build does not depend on XIB compilation.
5. **Project, build, tests, and docs:** Xcode targets/settings, Info.plist, entitlements, Foundation-only tests with fake time, a local build without external dependencies, README, license, and fork provenance.

Implementations and callers for password/Keychain, keyboard events, unlocking, scripts, MediaRemote, update checks, Bluetooth database reads, display control, and the screensaver-based lock alternative are removed. Related menu items, localization strings, bridging header, and build references are removed. The old Launcher is replaced by SMAppService.mainApp; the foreign developer team and automation entitlement are not retained.

The fork bundle identifier is `local.shatravkada.WatchLock`. Old BLEUnlock settings and Keychain are not read, migrated, or deleted. The README describes manual removal of its old password item if the user previously installed BLEUnlock.

## Saved devices

Configuration is stored locally through Codable and UserDefaults: a list of unique CoreBluetooth UUIDs, user names, per-device settings, the primary UUID, and the monitoring-enabled flag. The primary UUID must have a corresponding list entry.

- Adding is possible only from explicit scanning; a repeated UUID does not create a duplicate. An empty name is replaced by an available advertisement name or UUID.
- Only the primary device determines presence and initiates connection. A secondary iPhone does not affect deadlines or state, even when nearby.
- Changing the primary clears measurements, calibration, and old actions, closes the old connection, and grants one fresh signal-acquisition period of up to 15 seconds.
- Removing the primary disables automatic monitoring. No other device becomes primary automatically.
- Corrupt or invalid configuration is not silently overwritten: an error is displayed and automatic locking is not started from invalid data.
- A UUID and saved-device association are heuristic, not cryptographic authentication. Whether a watch is being worn is not detected.

Device defaults: −75 dBm threshold, 5 dB hysteresis, 5-second weak-signal delay, and 15-second fresh-signal timeout. The user configures threshold, delay, and timeout; input is validated before saving. UI ranges are −100…−30 dBm, 1…60 seconds, and 5…300 seconds. Hysteresis is fixed and does not add another setting.

## Discovery, connection, and resources

- General discovery starts on button press and stops after 20 seconds or on “Остановить” (Stop). Advertisement name/UUID and RSSI are shown. Scanning does not connect to read manufacturer, model, or characteristics.
- Only one scan can exist at a time. User discovery temporarily replaces the recovery window, not starts a parallel scan. After it ends, the previous recovery policy continues without resetting the no-signal deadline.
- A saved CBPeripheral and retrievePeripherals(withIdentifiers:) are tried first for the primary device. Connection does not establish “near” status.
- On connection, general automatic scanning stops; RSSI is requested roughly every 2 seconds. No new request is sent while the previous one is pending; missing callbacks are accounted for by the general freshness deadline.
- After disconnection, one bounded connection attempt to the known peripheral lasts 5 seconds. On failure, scanning opens for 5 seconds and closes for 25 seconds. Retries are constrained by the same sequence, without rapid loops.
- withServices:nil scanning is general: CoreBluetooth does not accept a peripheral UUID as a scan filter. During automatic recovery, unrelated devices are not saved and do not affect monitoring; only the saved primary UUID may be connected.
- Primary-device advertisement RSSI may be displayed but does not refresh presence during monitoring: only a successful connected-primary RSSI read confirms it. Recovery cannot masquerade as a stable connection.
- After confirmed locking, sleep, loss of active session, or user pause, scanning, RSSI reads, and connection attempts stop and the connection is canceled. On app termination, observers and all timers are removed.
- One owner schedules timers/deadlines, not a timer per discovered device. In inactive mode, only deadlines required to end a pause or confirm an already requested lock remain.
- Late callbacks from an old primary or previous monitoring run do not restart scanning, refresh presence, or change state. Every mode switch invalidates prior scheduled actions.

The 5/25-second windows are for reconnecting, not continuous passive monitoring. With a 15-second timeout, connection loss may cause locking before the next window; that is the expected conservative response. The timeout does not automatically increase. An Apple Watch that cannot maintain a stable connection must not be called supported based only on advertisements; the UI shows the lack of confirmed signal.

## State machine and locking

Observable states: **near**, **far**, **no signal**, **Bluetooth unavailable**, **monitoring suspended**. Connection and scanning are displayed separately, not substituted for presence.

A measurement is accepted only from the current primary, without a CoreBluetooth error, with RSSI −127…−1 dBm. Values 0, 127, and data from a previous monitoring run are not fresh signal. The average uses the last five accepted measurements; measurements expired by the timeout are excluded from smoothing.

- Monitoring is off before first configuration. First launch and initial Bluetooth permission denial do not initiate locking.
- Enabling requires a selected primary and available Bluetooth. Startup with saved enabled state but unavailable Bluetooth shows suspension and error, without an automatic lock loop; the user must resume monitoring.
- Starting active monitoring begins in “no signal” with one acquisition deadline of up to 15 seconds. Connection start and retries do not change that deadline.
- After an accepted signal, smoothed RSSI below the threshold starts the weak-signal delay. “Near” returns at threshold + 5 dB or higher; intermediate values retain the previous hysteresis side. For the first measurement, a value at or above threshold counts as near. A short dip that recovers before the delay expires does not lock the Mac.
- Expiration of the weak-signal delay requests a lock with reason “Основное устройство далеко” (Primary device is far). No accepted signal beyond the configured timeout requests a lock with reason “Нет свежего сигнала основного устройства” (No fresh primary-device signal).
- Switching Bluetooth off, revoking permission, or losing the controller after active monitoring starts immediately requests locking with a separate understandable reason. Initial unavailability before activation remains a setup error.
- After sleep/active-session resume/confirmed unlock, old measurements are cleared. One period of up to 15 seconds is granted; repeated connection callbacks and duplicate wake events do not extend it. Once fresh signal arrives, the normal weak/no-signal deadlines apply.
- A 15-, 30-, or 60-minute pause stops radio operations and locking. When it expires in an available active session, monitoring resumes with a new 15-second acquisition period. Sleep/locking do not cancel the pause deadline; if it expires during sleep, monitoring begins after return to an active unlocked session.
- A given cause produces at most one lock request until completion. After failure, automatic retries remain disabled until the user explicitly resumes; cause, error, and attempt time are separate from the last confirmed lock.

All deadlines use monotonic time. Calendar time is used only to display history, never for decisions.

## Real locking and macOS events

The researched public APIs did not provide immediate local locking under the constraints. MDM locking requires device management; simulating a keyboard shortcut requires extra privileges and violates the request. Display sleep and screensaver are not used as substitutes for locking.

ScreenLockAdapter dynamically looks up SACLockScreenImmediate in the system login.framework. The signature comes from the selected upstream (`int(void)`) but is not presented as a guaranteed public contract. A missing framework/symbol or nonzero result is an explicit error. The private framework is not an external network dependency.

A zero return code means only an accepted attempt, not proven success. The adapter waits up to 3 seconds for actual locked-screen confirmation. The undocumented CGSSessionScreenIsLocked indicator from CGSessionCopyCurrentDictionary is isolated there too. An unknown/missing value is not treated as successful locking. Distributed screenIsLocked/screenIsUnlocked notifications trigger a state recheck; they are not proof by themselves.

Compatibility clarification approved after a read-only probe on macOS 26.6.2: if the current session dictionary exists, the private lock flag is absent, and standard on-console and login-done indicators both equal 1, monitoring may consider the session active. This **does not** confirm successful locking: explicit private flag `1` is still required. A malformed present flag, nil dictionary, and incomplete/inactive session remain unknown. Session state is reread before manual scanning.

NSWorkspace reports system sleep/wake and session activity changes; display sleep and session switching are not declared locking/unlocking. At startup, session change, and wake, the available lock-state indicator is checked. If session state cannot be determined, automatic monitoring is suspended with a visible error rather than resumed on an unconfirmed event.

After confirmed locking, the watch connection stops. The app does not wake the display, enter a password, or unlock the Mac. This reduces interference with built-in Auto Unlock, but compatibility must be checked with real watches.

The private function, state indicator, and notifications may change in macOS. Successful compilation and symbol presence alone do not confirm locking works. A manual test of the real login screen on the target system is required.

## Interface and calibration

Menu: current status, settings, manual lock, 15/30/60-minute pause, resume, quit. The window shows saved/primary devices, add/remove/scan/stop buttons, current raw and smoothed RSSI, accepted-measurement age, connection/scanning state, parameters, launch at login, last confirmed lock, and current error.

Launch at login uses SMAppService.mainApp.register/unregister; errors and requiresApproval are displayed, and the switch does not claim success before the system confirms status. Required consent happens in macOS settings, without a root helper.

Calibration works only with a connected primary and temporarily disables automatic locking while keeping RSSI monitoring. It collects 20 successful fresh measurements “за столом” (at desk) and 20 “на желаемом расстоянии” (at the desired distance). The UI shows progress, allows canceling, and limits each stage to 90 seconds. Primary change, connection/permission loss, sleep, locking, or user pause cancel calibration; the previous threshold remains unchanged.

The 20th percentile is calculated for near measurements and the 80th for far ones. If separation is under 10 dB, “Надёжная граница не найдена” (No reliable boundary found) is displayed and no threshold suggested: 5 dB margin on each side is needed for hysteresis. Otherwise their midpoint is proposed. If that threshold falls outside the permitted range, calibration reports an error without changing settings. Percentiles use linear interpolation at position `(n − 1) × p` in the sorted array. The new threshold applies only after an explicit button press. Completing/canceling calibration resumes previously enabled monitoring with a new acquisition period if no other suspension reason exists.

RSSI is not converted into meters. A warning explains the effects of arm, body, interference, and Mac placement, and that wearing the watch is not verified. UI elements retain labels, keyboard navigation, and accessible names.

## Verification and acceptance criteria

Pure-core tests use fake measurements and controlled time, without real Bluetooth or sleep:

- short dip, sustained weak signal, hysteresis, and return;
- no fresh signal, invalid RSSI, readRSSI error, and stalled request;
- Bluetooth off/permission revoked after activation and initial denial;
- sleep/wake, stale-measurement reset, duplicate events, and nonextending grace period;
- primary change/removal, late callbacks, and secondary iPhone effect;
- pause, pause expiry during sleep, calibration, and cancellation;
- parameter bounds and invalid stored configuration;
- no parallel scans, 20- and 5/25-second windows, bounded connection;
- stop radio and clean timers on stop/lock/termination;
- zero return without confirmed lock, adapter error, and no retry loop;
- separated/overlapping calibration ranges and explicit threshold application.

Scanning policy is tested with a fake transport; lock confirmation with a fake adapter. Static source/build-content checks must confirm removal of forbidden functions, entitlements, and network callers, not merely hiding them in the UI.

Real-Mac checks are separate and marked “not tested” until actually performed: Apple Watch visibility/stable connection, real locking, native Auto Unlock, Bluetooth mouse/keyboard, permissions, sleep/wake, and absence of unnecessary radio operations. The user must know about the lock test beforehand; it is not secretly run in automated tests.

The available arm64 Mac has macOS 26.6.2, Swift 6.4, and Command Line Tools, but no full Xcode. Swift compilation, pure-core tests, and local .app packaging are possible; that alone did not establish that the full app would build. xcodebuild and macOS 14 execution remain separate unverified items until the needed environment is available.

The deliverable should include sources, an Xcode project/build commands, Foundation-only tests, a local .app if the build succeeds, README with installation/calibration/permissions/limitations, full MIT text retaining attribution/upstream credits, and applicable Apache 2.0 notices for any retained images. The upstream commit is recorded in docs; the fork is not published without separate permission.

Without Developer ID, only an explicitly identified local ad-hoc signature is acceptable. Verification of it is not notarization. If signing fails, the build is called unsigned. Gatekeeper is not disabled globally; no claim of a notarized build is made without actual Apple confirmation.

## Basis and remaining risks

- [CoreBluetooth: retrievePeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveperipherals%28withidentifiers%3A%29): retrieving a known peripheral does not guarantee a connection.
- [CoreBluetooth: scanForPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals%28withservices%3Aoptions%3A%29): filters service UUIDs, not peripherals.
- [CoreBluetooth: readRSSI](https://developer.apple.com/documentation/corebluetooth/cbperipheral/readrssi%28%29): reads a connected device's RSSI.
- [Apple: scanning best practices](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForInteractingWithARemotePeripheralDevice/BestPracticesForInteractingWithARemotePeripheralDevice.html): stop unnecessary scanning and avoid redundant repeated advertisements.
- [SMAppService.mainApp](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp): native login item for macOS 13+.
- [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace): sleep/wake and session activity are not equivalent to lock state.
- [Apple: Auto Unlock](https://support.apple.com/en-ie/102442): native unlock has its own requirements and remains macOS's responsibility.
- Private locking mechanisms have no confirmed public contract; real-OS testing is mandatory.
- A CoreBluetooth UUID does not guarantee immutable identity or stable Apple Watch visibility. Verify with a particular watch without reading internal Bluetooth databases.
- RSSI remains heuristic, allows false locks, and is not protection against radio attacks or proof of identity.

## Specification self-check

Checked alignment with user requirements, change boundaries, distinction between locking and display sleep, secondary-device behavior, the 25-second scanning pause versus the 15-second timeout, initial Bluetooth unavailability, no hidden retries, and hardware-check criteria. Proposed defaults and calibration algorithm are design choices, not measurements on the user's watch. Unimplemented features and unperformed checks are not declared complete.
