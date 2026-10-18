# WatchLock — BluetoothLocker

**English** · [Русский](README.ru.md)

A macOS menu bar utility that automatically **locks, but never unlocks** your Mac when your primary Bluetooth LE device moves away or stops responding.

## At a glance

- **How it works:** connects to a selected BLE device through CoreBluetooth, measures RSSI, and locks the screen after a sustained weak signal or lack of fresh measurements. Thresholds and delays are configurable; calibration and pause are available.
- **Permissions:** Bluetooth access. Optional launch at login through macOS Login Items. Accessibility, Full Disk Access, administrator password, and root are not required.
- **Data:** device UUIDs, names, and settings are stored locally in UserDefaults; this is not encrypted secret storage. No analytics, cloud, or network updates. The app does not ask for your Mac password or use Keychain.
- **Security:** RSSI does not prove the owner's identity or presence; interference can cause false locks, while signal spoofing or relaying can prevent a lock. This is a convenience feature, not a replacement for manual locking or macOS security settings.
- **Limitations:** locking uses a private macOS API that may change. Reliability with Apple Watch and compatibility with built-in Auto Unlock need manual verification. The local build is ad-hoc signed, without Developer ID or notarization.
- **License:** [MIT](LICENSE), allowing use, modification, and distribution while retaining notices; provenance and attribution are in [NOTICE](NOTICE).

## About the project

A personal **lock-only** fork of [BLEUnlock 1.12.2](https://github.com/ts1/BLEUnlock/tree/1.12.2), commit `c33a132f9b65ecd8fd55954a5e097a77b86c8a92`. MIT, © 2019–2022 Takeshi Sone. macOS **14+**; the first build targets **Apple Silicon / arm64**. AppKit menus and settings are in Russian.

**Built, but not yet verified with actual Apple Watches.** Results and the manual checklist are in [docs/VERIFICATION.md](docs/VERIFICATION.md). This is not guaranteed protection: RSSI does not authenticate the owner and may cause false locks.

## What changed

- Removed passwords, Keychain, keyboard simulation, unlocking, Accessibility, user scripts, media control, network updates, the old Launcher, internal Bluetooth databases, and MAC addresses. The old upstream CI was also removed.
- Supports multiple saved CoreBluetooth UUIDs with names/settings. **Only the primary device** affects locking: an iPhone left on the desk will not keep the Mac unlocked.
- Pure state, radio-deadline, and calibration core; a single timer owner.
- Real locking through an isolated private adapter; return code 0 **is not considered success** until the screen state is confirmed within 3 seconds.
- No runtime network dependencies, analytics, cloud, third-party packages, Accessibility, Full Disk Access, or root helper. The app does not unlock the Mac.

## Build

Requires macOS, Command Line Tools / Xcode with `swiftc` and `codesign`; tests require a modern Swift with standard Swift Testing. Verified environment: CLT Swift 6.4, macOS 26.6.2, arm64. The app itself compiles in Swift language mode 5 with deployment target 14.0.

```sh
git clone https://github.com/DoctorTau/BluetoothLocker.git
cd BluetoothLocker
./scripts/test-core.sh
./scripts/build-local.sh
./build/WatchLock.app/Contents/MacOS/WatchLock --self-check
python3 scripts/verify-safety.py --self-test
python3 scripts/verify-safety.py
codesign --verify --strict --verbose=2 build/WatchLock.app
```

`test-core.sh` runs `swift test` with local writable caches and without XCTest (not present in the installed CLT), explicitly loading standard Testing macros when needed. Tests do not use actual Bluetooth or screen locking. `--self-check` is handled **before NSApplication/CBCentralManager** and uses a separate temporary UserDefaults suite. Do not run the executable without the flag for automated checks.

With **full Xcode** installed:

```sh
xcodebuild -project WatchLock.xcodeproj -scheme WatchLock -configuration Debug \
  -derivedDataPath build/xcode CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

This route was **NOT RUN** in the current environment. Plist/project syntax and Xcode/CLI source-list parity were checked, but not the Xcode build itself. The project contains no third-party developer team, provisioning, private-framework linkage, or source-mutating build script.

## Run and install locally

The built artifact is `build/WatchLock.app` in the repository. The script only builds it: it **does not launch or install the app or lock the Mac**.

1. Quit BLEUnlock first so the old app cannot affect the test.
2. Open the local `.app` in Finder (or run `open build/WatchLock.app`). A shield symbol appears in the menu bar, without a normal Dock window. A lock on the shield means monitoring is active; a shield without a lock means inactive.
3. Allow Bluetooth through the standard macOS prompt. An initial denial does not start a lock loop. Do not grant additional permissions.
4. After verifying it, you may manually copy the app into `/Applications` or `~/Applications`. For launch at login, use a stable location and then the switch in WatchLock settings. The actual status/error is shown; `requiresApproval` needs your consent in macOS Login Items settings.

**Signing: local ad-hoc plus hardened runtime, without Developer ID. Not notarized.** A successful codesign check does not imply Gatekeeper approval. If macOS blocks launch, use only the system-provided per-file override for a trusted local file. Do not disable Gatekeeper globally. Developer ID and notarization require your own account and were not performed here.

## Initial setup

1. Monitoring is **off by default**. Click “Поиск 20 с” (Scan for 20 s), select an advertisement, and click “Добавить” (Add). Scanning has a stop button; it does not connect to read a device model.
2. Name the device and click “Сделать основным” (Make primary). Adding a device does not automatically make it primary. Removing the primary turns monitoring off; canceling removal changes nothing.
3. **Save your work before enabling it: the Mac may lock after only 15 seconds** if the watch supplies no fresh connected RSSI. A watch might not advertise or support a stable connection through these APIs; appearing in the list does not prove suitability.
4. Enable monitoring and verify a connection and fresh measurements. Do not run multiple WatchLock instances at once. If the session is shown as “неизвестен” (unknown), radio and automatic monitoring are stopped; this must not be bypassed by assuming it is unlocked.

Settings are stored only in the separate UserDefaults domain `local.shatravkada.WatchLock`. BLEUnlock settings/secrets are neither read nor migrated. Corrupt data is not erased: an error is shown, automatic monitoring is disabled, and writes are blocked until manual recovery. Save the original data before a manual reset. `UserDefaults` does not promise transactions or a synchronous durable disk flush.

If BLEUnlock previously stored a password, WatchLock **neither reads nor deletes it**. If needed, manually open Keychain Access, find the BLEUnlock item, verify its ownership, and delete only that item. Do not delete the whole Keychain.

## Algorithm and radio

- Defaults: threshold **−75 dBm**, weak signal **5 s**, no fresh signal **15 s**. Ranges: −100…−30 dBm, 1…60 s, 5…300 s. Invalid or nonnumeric values are not applied.
- Average of the five most recent still-fresh RSSI measurements; returning from “far” requires threshold + **5 dB**. Starting a connection or receiving an advertisement does not count as fresh presence.
- RSSI is requested only from a connected peripheral, about every **2 s**, with one request in flight. An error does not refresh the signal; a stalled request is limited to 5 s.
- After disconnection, one immediate known-UUID / `retrievePeripherals` attempt lasting up to **5 s**; then general scanning for **5 s**, followed by a **25 s** pause. The API's scan filter takes a **service UUID**, not a peripheral UUID, so a nil scan is used and unrelated advertisements are ignored locally. Early known-connect failure opens scanning; failed scan-target connection or a rapidly dropped recovered connection gets a 25-second cooldown, without spinning. General scanning stops automatically on connection. Explicit user scanning can temporarily run while connected; scans never run in parallel. Unrelated device advertisements enter the UI only during explicit scanning, not recovery.
- Each new connection attempt has a separate central identity; generation and delegate identity guard against late callbacks after A → B → A / stop.
- Losing Bluetooth or permission after active monitoring triggers one lock attempt with a reason. Initial unavailability is a visible error, not a lock loop: turn Bluetooth on and explicitly click “Возобновить” (Resume). An availability change alone is insufficient. Before the controller's first response, startup waits for state and does not treat this as a refusal.
- Sleep and confirmed locking stop the radio. Resume happens only in a confirmed unlocked active session. Wake clears old data and gives **15 s** for the first measurement; repeated events do not extend the deadline. The same period applies on enable, primary-device change, unlock, resume, and completion of pause/calibration. After the first accepted RSSI, normal configured deadlines apply immediately.
- A **15/30/60 min** pause persists through sleep/lock. Deadlines use monotonic `mach_continuous_time`, which includes sleep; calendar time is used only for history.
- A lock error or missing confirmation stops automatic retries until explicit “Возобновить” (Resume). History distinguishes an attempt from the most recent confirmed lock.

## Calibration

Connect the primary device and enable monitoring. During both calibration stages, RSSI/freshness-based locking is temporarily suppressed (loss of Bluetooth/permission still initiates a lock). Collect **20** measurements at the desk, move to where you want locking to happen, then click “2. Вдали” (2. Away): another **20**, with up to **90 s** per stage.

The 20th percentile “at desk” and 80th percentile “away” are compared using linear interpolation. A difference below **10 dB** means no reliable boundary was found. Otherwise the midpoint is suggested; a threshold outside the allowed range is rejected, not clamped. It is applied **only by pressing the button**. Cancel, primary-device/settings changes, disconnect, Bluetooth error, sleep, lock, or pause stop collection without changing the previously applied threshold.

Arm position, body, walls, and interference affect RSSI. It is **not a precise distance in meters**, watch-wearing detection, or cryptographic authentication. A UUID may change and cached retrieval may return an empty list; Apple Watch reliability needs hardware verification.

## Private API and limitations

`ScreenLockAdapter.swift` is the sole location of `SACLockScreenImmediate`, dynamic `login.framework` loading, the private lock flag, and notification names. The `int(void)` ABI comes from the selected upstream and is not guaranteed by Apple. Missing symbol/nonzero return is an error. A zero return without confirmed locked state within **3 s** is also an error. There is no screensaver, display-sleep, or keyboard-event fallback.

`CGSessionCopyCurrentDictionary` must return a dictionary. Explicit private lock flag `1` confirms locking; explicit `0` allows monitoring only with on-console=1 and login-done=1. If the private flag is **absent**, both indicators in an active session also allow monitoring, but **do not confirm successful locking**. A malformed present flag, incomplete/inactive session, or nil dictionary remains **unknown**. An early terminal probe in a sandbox returned nil; a separate read-only unsandboxed probe on this Mac returned a dictionary with both indicators `1`, but no private flag. Neither probe was a **GUI app test**. Manual scanning rereads the session before starting rather than relying on stale startup state.

While monitoring is enabled and the Mac is awake, the existing timer rereads session state once per second, including after confirmed locking. This detects a later unlock without a private notification; radio does not start while locked or unknown. “Возобновить” (Resume) and opening settings also reread the session before using its state. This poll does not clear a lock fault: explicit Resume is still required after one.

Private APIs/flags may change in any macOS release. Compatibility with 14+ and built-in Apple Watch Auto Unlock **has not been verified by a real test**.

Official API limitations: [scanForPeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals(withservices:options:)), [retrievePeripherals](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveperipherals(withidentifiers:)), [readRSSI](https://developer.apple.com/documentation/corebluetooth/cbperipheral/readrssi()), [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice).

The static auditor checks the listed source/symbol/metadata rules; it **does not prove the absence of every possible network path or correct hardware behavior**. The build script does not install the app in Applications or change macOS permissions or settings.
