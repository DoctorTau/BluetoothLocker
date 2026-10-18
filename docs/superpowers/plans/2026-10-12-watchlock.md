# WatchLock Implementation Plan

**English** · [Русский](2026-10-12-watchlock.ru.md)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal macOS fork of BLEUnlock that locks the Mac when the primary BLE device moves away, never obtains a password, and never unlocks the screen.

**Architecture:** Retain the suitable AppKit/CoreBluetooth foundation. A pure Foundation core takes events and monotonic time, emits actions, and is tested without hardware. Bluetooth, the private lock adapter, and UI execute serially on the main queue; one owner manages all deadlines.

**Tech Stack:** Swift, Foundation, AppKit, CoreBluetooth, ServiceManagement, CoreGraphics, XCTest; standard macOS build tools and Python 3 only for local auditing.

**Spec:** [WatchLock technical specification](../specs/2026-10-12-watchlock-design.md).

## Global Constraints

- Name WatchLock; bundle identifier `local.shatravkada.WatchLock`; macOS 14+, first build arm64.
- Base BLEUnlock 1.12.2, commit `c33a132f9b65ecd8fd55954a5e097a77b86c8a92`; retain MIT, Takeshi Sone attribution, and applicable upstream credits.
- Lock only: no password/Keychain, keyboard events, automatic unlocking, scripts, MediaRemote, network update checks, or internal Bluetooth databases.
- No third-party/runtime network dependencies, Accessibility, Full Disk Access, or root. Display sleep and screensaver do not substitute for locking.
- Only the primary device affects presence; per-device settings are saved separately. Automatic monitoring is initially off.
- Values: −75 dBm threshold, 5 dB hysteresis, 5 s delay, 15 s freshness, RSSI every 2 s, 20 s discovery, 5 s recovery / 25 s pause, 3 s lock confirmation.
- Setting ranges: threshold −100…−30 dBm, delay 1…60 s, freshness 5…300 s. Pauses only 15/30/60 minutes; the up-to-15 s post-wake period is not extended by repeated events.
- Calibration: two stages of 20 accepted measurements, at most 90 s per stage; 20th/80th percentiles, minimum 10 dB separation, threshold applied only explicitly.
- One writer in the current checkout. Do not publish, push, install into Applications, change system settings, or run external workflows.
- Automated tests do not perform real locks. Do not claim hardware compatibility, signing, or notarization verified without corresponding results.

## Review Focus

1. Corrupt/old storage: do not erase data or activate locking from invalid configuration — Task 1 tests.
2. Stale callback after A → B → A or pause: do not restore old measurements/connections — Tasks 2–3 tests.
3. Sleep during pause/calibration and duplicate wake/unlock events: do not cancel a pause or extend grace — Tasks 2, 5 tests.
4. Return 0 without a proven login screen, missing/unusual private flag: error, not success or a retry loop — Task 4 tests.
5. Failed save/login-item registration or canceled UI action: do not display unapplied settings or delete a device — Tasks 1, 5 tests.

---

## File map

All paths below are relative to `/Users/shatravkada/Documents/ChatGPT/MacLocker`.

| File | Purpose |
| --- | --- |
| `Package.swift` | Local WatchLockCore library and XCTest; no dependencies |
| `WatchLock/Core/Configuration.swift` | Codable configuration, validation, device-list operations |
| `WatchLock/Core/MonitoringEngine.swift` | Presence, freshness, pause, session events, single lock request |
| `WatchLock/Core/RadioPolicy.swift` | Scan/connection/RSSI deadlines, generations, cancellation |
| `WatchLock/Core/LockVerification.swift` | Result/confirmation deadline check without a system lock call |
| `WatchLock/Core/Calibration.swift` | Sample collection, stage deadlines, threshold suggestion |
| `WatchLock/BLE.swift` | Modified upstream CoreBluetooth transport |
| `WatchLock/ScreenLockAdapter.swift` | Dynamic private API and screen-state reading |
| `WatchLock/ConfigurationStore.swift` | Persist valid snapshots in a separate UserDefaults domain |
| `WatchLock/AppDelegate.swift`, `WatchLock/main.swift` | Menu, component coordination, lifecycle, XIB-free launch |
| `WatchLock/SettingsWindowController.swift` | Russian settings, device list, diagnostics, calibration |
| `WatchLock/Info.plist`, `WatchLock/WatchLock.entitlements` | Metadata, Bluetooth usage description, minimal privileges |
| `WatchLock.xcodeproj/project.pbxproj`, shared scheme | Xcode project, arm64/macOS 14, no old Launcher/private linkage |
| `Tests/WatchLockCoreTests/*Tests.swift` | Deterministic configuration/state/radio/calibration checks |
| `scripts/build-local.sh`, `scripts/verify-safety.py` | Local .app and self-checking forbidden-feature audit |
| `LICENSE`, `NOTICE`, `README.md`, `docs/UPSTREAM.md`, `docs/VERIFICATION.md` | License, provenance, installation, actual verification status |

The app and Swift Package use the same Core files, with no second implementation of the algorithms. Xcode puts them in the app target; Package.swift builds them as WatchLockCore for tests. App compilation uses Swift language mode 5 and deployment target 14.0; a newer Swift toolchain does not require rewriting upstream for Swift 6 strict concurrency.

## Task 1: Fork provenance and device configuration

**Files:** Package.swift; WatchLock/Core/Configuration.swift; Tests/WatchLockCoreTests/ConfigurationTests.swift; LICENSE; NOTICE; docs/UPSTREAM.md; .gitignore; imported upstream tree.

**Interfaces:** `DeviceSettings: Codable, Equatable` with `threshold: Double`, `weakSignalDelay: TimeInterval`, `noSignalTimeout: TimeInterval`, default initializer, and `validate() throws`. `SavedDevice: Codable, Equatable` with `id: UUID`, `name: String`, `settings: DeviceSettings`. `Configuration: Codable, Equatable` with `version: Int` (current version 1), `devices: [SavedDevice]`, `primaryID: UUID?`, `monitoringEnabled: Bool`; `validate() throws`, `static decode(_ data: Data) throws -> Configuration`, `encoded() throws -> Data`, mutating `add(_:) throws`, `update(_:) throws`, `selectPrimary(_:) throws`, `remove(_:)`. Errors are `ConfigurationError: Error`, without force unwrap.

- [x] **Step 1: Import exactly the base commit without building or running upstream.** Create `codex/watchlock`; fetch the specified tag from public upstream, check `rev-parse` against the full SHA, then merge it with the existing docs commit using `--allow-unrelated-histories`. Recheck upstream AGENTS.md and licenses. Rename BLEUnlock/ and BLEUnlock.xcodeproj to WatchLock/ and WatchLock.xcodeproj; do not immediately call the project buildable — Task 6 completes build references. Do not carry someone else's developer team or old bundle identifier into the final project.
- [x] **Step 2: Create local Package.swift and failing ConfigurationTests.** Assertions: defaults are −75/5/15; duplicate UUID/unknown primary/NaN/out-of-range settings rejected; remove(primary) makes `primaryID == nil && monitoringEnabled == false`; round trip retains all devices/settings; decoding corrupt JSON throws. An empty added name uses UUID but does not create cryptographic trust.
- [x] **Step 3: Run `swift test --filter ConfigurationTests`.** Before implementation, expect a missing-type compilation error or failed assertion, not an infrastructure error; record the result.
- [x] **Step 4: Implement the specified models and methods.** Use an explicit error for an unknown configuration format version; do not destructively repair it. Add full MIT, attribution, and NOTICE with applicable notices for retained upstream images; record source and SHA.
- [x] **Step 5: Rerun `swift test --filter ConfigurationTests`.** All checks pass and Package.swift dependencies are empty. Commit only this task's files: `feat: add validated trusted device configuration`.

## Task 2: Testable monitoring state machine

**Files:** WatchLock/Core/MonitoringEngine.swift; Tests/WatchLockCoreTests/MonitoringEngineTests.swift.

**Interfaces:** `MonitoringState` = nearby/far/noSignal/bluetoothUnavailable/suspended. `BluetoothAvailability` = available/unavailable/unauthorized. `ScreenState` = locked/unlocked/unknown. `LockReason` = weakSignal/noSignal/bluetoothUnavailable/permissionRevoked/manual. `LockOutcome` = confirmed/failed(String). `MonitoringEffect` = startRadio(UUID, UInt64)/stopRadio/requestLock(LockReason), Equatable. `MonitoringEvent` = start(primary: SavedDevice)/sample(id: UUID, rssi: Int, generation: UInt64)/bluetoothChanged(BluetoothAvailability)/sessionChanged(ScreenState)/sleep/wake/pause(minutes: Int)/resume/calibrationChanged(Bool)/lockCompleted(LockOutcome)/tick/stop. `MonitoringEngine` has a default initializer, read-only `state`, `generation`, `lastMeasurementAt`, `rawRSSI`, `smoothedRSSI`; `mutating handle(_ event: MonitoringEvent, now: TimeInterval) -> [MonitoringEffect]`.

- [x] **Step 1: Write failing MonitoringEngineTests with explicit time.** The watch fixture uses a fixed UUID and default DeviceSettings; before start, the engine receives bluetoothChanged(.available) and sessionChanged(.unlocked). Main assertions:

```swift
_ = engine.handle(.start(primary: watch), now: 0)
XCTAssertEqual(engine.state, .noSignal)
XCTAssertEqual(engine.handle(.tick, now: 15), [.requestLock(.noSignal)])
XCTAssertEqual(engine.handle(.tick, now: 16), [])
```

Also: −60@0, −95@2, −55@4 do not lock at @8; −90@0/2/4 lock at @5; 0/127/wrong UUID/old generation do not update freshness. Assert −75 threshold and −70 recovery. A secondary iPhone at −40 does not shift the primary watch's @15 deadline.
- [x] **Step 2: Run `swift test --filter MonitoringEngineTests` and confirm RED.** Add cases: Bluetooth off/unauthorized after activation → one requestLock; initial refusal → none; sleep → stopRadio; wake@100 and repeat wake@110 → deadline 115; old samples cleared. A → B → A invalidates callbacks from A's first generation. A 15-minute pause at @0 survives sleep; pause expiry during sleep does not start radio. Unknown screen → suspension, not “unlocked.”
- [x] **Step 3: Implement reducer without timers or system calls.** Last five valid, still-fresh samples; fixed hysteresis; exact monotonic deadlines; idempotent wake/resume for an already active run. Initial no-signal period gets 15 seconds regardless of connection retries. Lock failure sets fault suspension until explicit resume; confirmed lock clears radio operations. Calibration suppresses locking but does not stop RSSI.
- [x] **Step 4: Run `swift test --filter MonitoringEngineTests`, then full `swift test`.** PASS for all scenarios above, without `sleep`, real Bluetooth, or screen locking. Commit: `feat: implement deterministic monitoring state machine`.

## Task 3: Radio policy and CoreBluetooth transport

**Files:** WatchLock/Core/RadioPolicy.swift; WatchLock/BLE.swift; Tests/WatchLockCoreTests/RadioPolicyTests.swift; remove WatchLock/LEDeviceInfo.swift and WatchLock/appleDeviceNames.swift after retaining safe foundation.

**Interfaces:** `RadioPolicy` has read-only `generation`, `isScanning`, `nextDeadline`, default initializer, and `mutating handle(_ event: RadioEvent, now: TimeInterval) -> [RadioAction]`. `RadioEvent` = monitor(id: UUID, generation: UInt64)/startDiscovery/stopDiscovery/discovered(id: UUID, generation: UInt64)/connected(id: UUID, generation: UInt64)/disconnected(id: UUID, generation: UInt64)/rssiCompleted(id: UUID, generation: UInt64)/tick/stop. `RadioAction` = startScan(discovery: Bool)/stopScan/connect(UUID, UInt64)/disconnect(UUID)/readRSSI(UUID, UInt64), Equatable. `BLEControlling` declares read-only `isScanning: Bool`, `isConnected: Bool`, `nextDeadline: TimeInterval?`; methods `apply(_ effect: MonitoringEffect, now: TimeInterval)`, `startDiscovery(now: TimeInterval)`, `stopDiscovery(now: TimeInterval)`, `tick(now: TimeInterval)`, `stop()`; and get/set callbacks `onMeasurement: ((UUID, Int, UInt64) -> Void)?`, `onAvailability: ((BluetoothAvailability) -> Void)?`, `onConnectionChanged: ((Bool) -> Void)?`, `onDiscovery: ((UUID, String?, Int) -> Void)?`. `BLE` implements the protocol and applies policy only on the main queue; the fake does not create CBCentralManager.

- [x] **Step 1: Write failing RadioPolicyTests.** Assertions: discovery@0 emits one startScan; repeat@1 neither starts another nor moves end@20; stop@3 closes scan; known connect@0 expires@5, scan runs@5…10, next attempt not before@35; connected closes automatic scan; readRSSI every 2 seconds but no repeat before rssiCompleted. Other UUID does not cause connect. startDiscovery during recovery replaces, not duplicates, its scan.
- [x] **Step 2: Run `swift test --filter RadioPolicyTests` and get RED.** Additional assertions: stop is idempotent; nextDeadline after full stop is nil; late didConnect after stop is canceled instead of restoring polling; errors and A → B → A callbacks do not revive the old mode.
- [x] **Step 3: Implement RadioPolicy and modify upstream BLE.swift.** Try saved peripheral/retrievePeripherals first, then bounded connects and 5/25 scanning. Use only nil/main queue. During discovery show advertisement name/UUID/RSSI; do not call discoverServices/readValue for a model. Separate run generation and the pending RSSI request: reject old delegate/request after reselecting the same UUID. A readRSSI error ends the request but sends no sample to MonitoringEngine; an advertisement cannot replace a connected readRSSI. No general scan during a working connection, except user-requested explicit discovery.
- [x] **Step 4: Run RadioPolicyTests and full `swift test`.** Fake transport records exact start/stop/connect/readRSSI actions and checks cancellation order/no resources after stop. Real CoreBluetooth testing remains separate and is not replaced by this test. Commit: `feat: bound Bluetooth discovery and reconnection`.

## Task 4: Real-lock adapter

**Files:** WatchLock/Core/LockVerification.swift; WatchLock/ScreenLockAdapter.swift; Tests/WatchLockCoreTests/LockVerificationTests.swift; remove lowlevel.c/h, MediaRemote.h, and bridging header; remove framework references from the future app target.

**Interfaces:** `LockVerification` has `init(returnCode: Int32, now: TimeInterval)` and `mutating observe(_ state: ScreenState, now: TimeInterval) -> LockOutcome?`; it emits one terminal result. `ScreenLocking` declares `screenState() -> ScreenState` and `requestLock() throws -> Int32`. `ScreenLockAdapter` implements it and `static parseLockFlag(_ value: Any?) -> ScreenState`; Any is limited to the system CFDictionary boundary. `ScreenLockError: Error` includes unavailableFramework/unavailableSymbol. Runtime screen-state checks remain in the adapter; the reducer knows only ScreenState.

- [x] **Step 1: Write failing LockVerificationTests.** Exact intended behavior:

```swift
var attempt = LockVerification(returnCode: 0, now: 0)
XCTAssertNil(attempt.observe(.unlocked, now: 2))
XCTAssertEqual(attempt.observe(.locked, now: 2.5), .confirmed)
XCTAssertNil(attempt.observe(.locked, now: 3))
```

Other assertions: unlocked/unknown through the end of 3 seconds → failed; nonzero code → failed without further events; no automatic retries. Missing private flag, 2, string, and wrong type yield unknown; only Boolean/numeric 0/1 are accepted.
- [x] **Step 2: Run `swift test --filter LockVerificationTests` and get RED.** Then implement deadline reducer and private-flag parser in the adapter; cover parser with a separate assert-based self-check that does not call requestLock or create CBCentralManager.
- [x] **Step 3: Implement dynamic loading of system login.framework and SACLockScreenImmediate.** Use upstream ABI `@convention(c) () -> Int32`, check dlopen/dlsym before calling, and never substitute a missing symbol. Do not link the private framework statically. Isolate and document locking/CGSSessionScreenIsLocked/private notifications. No screensaver, display sleep, or CGEvent fallback.
- [x] **Step 4: Run LockVerificationTests and full `swift test`.** Test missing symbol through a fake adapter: visible failure and stopRadio, with lastConfirmedLock unchanged. Do not execute a real lock call yet. Commit: `feat: verify screen locking through isolated adapter`.

## Task 5: Calibration, storage, and Russian UI

**Files:** WatchLock/Core/Calibration.swift; WatchLock/ConfigurationStore.swift; WatchLock/AppDelegate.swift; WatchLock/SettingsWindowController.swift; WatchLock/main.swift; Tests/WatchLockCoreTests/CalibrationTests.swift and ConfigurationTests.swift; remove checkUpdate.swift, old Launcher, unused XIB/localizations, and forbidden AppDelegate implementations.

**Interfaces:** `CalibrationStage` = idle/desk/away/ready/failed(String); `Calibration` has default initializer, read-only stage/count/proposedThreshold, and `mutating startDesk(now: TimeInterval)`, `startAway(now: TimeInterval)`, `add(rssi: Int, now: TimeInterval)`, `tick(now: TimeInterval)`, `cancel()`. `static suggestThreshold(near: [Int], far: [Int]) throws -> Double` uses exact spec percentiles. `ConfigurationStore.init(defaults: UserDefaults)`; `load() throws -> Configuration`, `save(_ configuration: Configuration) throws`. `AppDelegate.init(lockAdapter: any ScreenLocking, radio: any BLEControlling, store: ConfigurationStore)` allows fake lock/radio in self-check; the delegate owns engine, radio, calibration, and a single Timer. UI and observers are created only in applicationDidFinishLaunching, not the initializer. SettingsWindowController receives typed snapshot/actions and does not access Bluetooth directly.

- [x] **Step 1: Write failing CalibrationTests.** Twenty −60 and twenty −90 → threshold −75; 19 samples → no suggestion; near −70/far −75 → error; −120/−100 → range error, not clamp; stage expires exactly@90; cancel retains previous applied threshold. Check linear percentile interpolation on heterogeneous samples and that invalid RSSI does not increase count.
- [x] **Step 2: Run `swift test --filter CalibrationTests`, get RED, then implement Calibration.** Threshold is suggested, not saved automatically. On primary change, disconnect, Bluetooth error, sleep, lock, or user pause, coordination cancels collection and restores the prior mode only when no other suspension exists.
- [x] **Step 3: Implement ConfigurationStore and cover it with an assert-based self-check using a separate temporary UserDefaults suite.** Failed validation leaves prior Data unchanged; corrupt Data remains in storage after failed load. Delete only the temporary test suite. Never open the real BLEUnlock/Keychain domain. These checks concern the storage API; they do not promise UserDefaults transactions or a forced durable disk flush.
- [x] **Step 4: Modify AppDelegate and create programmatic UI/main.** Keep useful upstream NSStatusBar/NSMenu patterns; remove prohibited callers, password strings, Accessibility, script/media/update hooks, and old launch helper. The menu icon is a standard SF Symbol with no new art. UI includes list/primary, add/remove/select, scan start/stop, raw/mean/age/connection/scan status, settings, enable/resume/pause, lock reason/error/time, calibration progress/apply/cancel. Native labels and keyboard access. Canceling a removal confirmation does not change configuration. Login toggle uses actual SMAppService.status and register/unregister errors, not optimistic success.
- [x] **Step 5: Connect the sole ticker to policy deadlines, engine.tick, calibration.tick, and LockVerification.observe.** Active deadlines use a 1-second interval; RSSI requests remain every 2 seconds. On requestLock, stop radio first, then invoke adapter once. Remove ticker when no deadlines remain; on stop/terminate cancel radio, pending requests, and observers. Session/private notifications only trigger a screenState recheck; display wake is not unlock. On wake determine screen state before handling engine events. Startup with unavailable Bluetooth does not activate locking; unavailability after active monitoring triggers one attempt. Attempt and confirmed lock are persisted separately. Do not initiate connection/locking from UI updates.
- [x] **Step 6: Run `swift test` and assert-based self-checks.** Test coordination with FakeRadio and FakeScreenLock without calling applicationDidFinishLaunching/NSApplication or a real manager: calibration cancel + sleep does not startRadio; pause expiry with locked screen does not startRadio; invalid settings/failed store are not applied; secondary iPhone does not change engine; stop/terminate make owned Timer nil/invalid. Test login-item presentation with fake SMAppService.Status/error without register/unregister. Handle `--self-check` before initializing NSApplication/CBCentralManager, running only these checks and private-flag parser. Commit: `feat: add Russian controls and calibrated monitoring`.

## Task 6: Buildable project and local .app

**Files:** WatchLock.xcodeproj/project.pbxproj and shared scheme; WatchLock/Info.plist; WatchLock/WatchLock.entitlements; scripts/build-local.sh; .gitignore; README.md.

**Interfaces:** `scripts/build-local.sh` without arguments creates only `build/WatchLock.app` and exits nonzero on compilation/packaging/signing failure. Core and app Swift sources compile into one executable with `xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0`; SDK comes from `xcrun --sdk macosx --show-sdk-path`. Build neither launches the app nor locks. Generated outputs are excluded from Git.

- [x] **Step 1: Add project/scheme and plist, updating upstream build settings.** Target WatchLock, macOS 14.0, arm64, new bundle identifier; remove Launcher, source-mutating build-number script, private linkage/MediaRemote, developer team, and provisioning references. Metadata retains attribution/MIT; Russian NSBluetoothAlwaysUsageDescription; UI starts without NSMainNibFile. Entitlements contain no automation, camera, microphone, root-helper, or network permissions.
- [x] **Step 2: Create minimal build-local.sh with `set -euo pipefail`.** Use fixed source directories, safe quoting, and only the project's own build directory; do not delete user data. Compile, package app bundle, copy plist/license files, and ad-hoc codesign with hardened runtime; do not call the build signed if signing fails. Xcode and script must share source list and metadata.
- [x] **Step 3: Run `bash -n scripts/build-local.sh`, `plutil -lint WatchLock/Info.plist WatchLock/WatchLock.entitlements WatchLock.xcodeproj/project.pbxproj`, then `./scripts/build-local.sh`.** Syntax checks do not replace a build. Script assertions: executable exists/is executable, plist has correct bundle identifier/minimum OS, `file` reports arm64. Run the executable only with `--self-check`: exit 0 and explicit report without UI, Bluetooth, network requests, or real lock.
- [x] **Step 4: Check `codesign --verify --strict --verbose=2 build/WatchLock.app` and `codesign -dv --verbose=4 build/WatchLock.app`.** Record actual ad-hoc status. Notarization was not performed; do not change Gatekeeper. When full Xcode becomes available, separately run `xcodebuild -project WatchLock.xcodeproj -scheme WatchLock -configuration Debug -derivedDataPath build/xcode CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build`. Without Xcode, this remains NOT RUN, not PASS.
- [x] **Step 5: Run full `swift test`; compare Xcode Sources with the build script.** Commit: `build: package local arm64 WatchLock application`.

## Task 7: Final audit and handoff

**Files:** scripts/verify-safety.py; README.md; docs/VERIFICATION.md; NOTICE; final app/project tree and Git diff.

**Interfaces:** `python3 scripts/verify-safety.py` checks app sources, plist/entitlements, PBX build references, and the built binary if present; exit 0 means only the listed static checks passed. `--self-test` runs assert-based checks of the auditor against fake strings/fixtures without reading other projects.

- [x] **Step 1: Write a failing auditor self-test.** Detect `SecItemCopyMatching`, keyboard CGEvent/AXIsProcessTrusted, URLSession, NSAppleScript/Process execution, MRMediaRemote, SQLite3, and internal Bluetooth-database paths; limitations mentioned in README are not runtime callers. Allow SACLockScreenImmediate/private lock-state literals only in ScreenLockAdapter. Do not present source regex as proof that every possible network path is absent.
- [x] **Step 2: Implement the auditor with Python standard library and run `python3 scripts/verify-safety.py --self-test`, then `python3 scripts/verify-safety.py`.** Also check direct undefined app executable symbols through `nm -u`, bundle contents, and absence of unnecessary entitlements/old Launcher. All forbidden runtime implementations are removed from final tracked sources, not merely excluded from the build.
- [x] **Step 3: Complete README and VERIFICATION.** Include Swift/Xcode/local build commands, .app launch, initial setup, calibration, Bluetooth permission, login-item approval, manual deletion of old BLEUnlock Keychain item, UUID/RSSI/private-API limits, and scanner duty cycle. Give PASS/FAIL/NOT RUN with command/result for each check; separate static/core/self-check/build from GUI and hardware.
- [x] **Step 4: Run final `swift test`, local build, executable `--self-check`, safety audit, codesign verification, and `git diff --check`.** README must not promise stable Apple Watch connection, proof of wearing the watch, peripheral-UUID scan filtering, meters, or notarization. On error, do not replace verification with “should work.”
- [x] **Step 5: Explicitly warn about locking before hardware tests.** Manual checklist: discover primary Apple Watch, 2-second RSSI without background scan, move away and require real authentication, return/native Auto Unlock, secondary iPhone left on desk, mouse/keyboard, Bluetooth off, permission revoked, pause, sleep/wake. Without available watch/GUI/OS version, corresponding items remain NOT RUN; do not lock automatically.
- [x] **Step 6: Commit `docs: record WatchLock validation and limitations`; independently review the full change.** One gpt-6-sol reviewer, high reasoning, fresh/read-only context, no nested agents; check spec, safety, late callbacks, and cleanup. Same writer performs fixes; stop after two failed attempts and show evidence. Final answer: source/.app path, verified/unverified, signing/notarization, and material risks. Do not push/publish.

## Self-check and execution

The spec covers Tasks 1–7; all states/effects/shared types are defined in Tasks 1–2 and used consistently. Each of the five Review Focus areas has checks owned by the code owner. RED→GREEN is recorded separately from toolchain problems. The plan contains no executable product files: code snippets are requirements for future tests, not a claimed implementation.

A read-only check in the current terminal context got nil from CGSessionCopyCurrentDictionary (`sessionAvailable=false`). This is not a GUI-app result or proof the OS lacks locking support. System-state confirmation must be checked separately from a real GUI session; CLI self-check tests parser/fakes and does not claim the current screen is unlocked.

Recommended method was **Native**: main agent implements tasks sequentially as sole writer, then a separate agent reviews the result. Components are tightly coupled by interfaces; seven fresh implementers and seven separate review contexts would add overhead without speeding this small personal app. The process required the user to review this plan and approve the method before upstream import/implementation.

## Execution outcome

Native Tasks 1–7 were completed; one independent review found four Important defects, fixed with RED→GREEN regressions (27 tests). Actual commands, limitations, and NOT RUN items are in [docs/VERIFICATION.md](../../VERIFICATION.md). Checkmarks mean step completion/recorded limitation, not hardware PASS. Xcode build, interactive GUI, and hardware checklist remain NOT RUN. Branch codex/watchlock was kept locally without merge/push.
