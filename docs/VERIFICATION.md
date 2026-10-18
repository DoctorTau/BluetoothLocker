# WatchLock verification

**English** · [Русский](VERIFICATION.ru.md)

Date: 2026-10-12. Environment: macOS 26.6.2 (25G83), arm64, Swift 6.4, Command Line Tools (`/Library/Developer/CommandLineTools`), **without full Xcode**. Binary target: arm64-apple-macos14.0. Execution on macOS 14 was not tested.

## Automated results

| Status | Check | Evidence |
| --- | --- | --- |
| PASS | Fork basis | fetched `upstream-1.12.2` → `c33a132f9b65ecd8fd55954a5e097a77b86c8a92`; history was retained during the initial import; the upstream app was not run. Public `master` starts from root snapshot commit `a68877c` and does not include upstream Git history; the complete upstream history exists only in local `codex/watchlock-history` |
| PASS | Core RED → GREEN | Configuration/MonitoringEngine/RadioPolicy/LockVerification/Calibration: missing types before implementation → 27 deterministic tests in 5 suites |
| PASS | Full core suite | `./scripts/test-core.sh`; Swift Testing, 29 tests, without sleep/real radio/locking |
| PASS | Coordinator and storage | app executable `--self-check`: temporary suite; failed validation/load preserves raw Data; a corrupt coordinator does not overwrite data; primary/secondary UUID, sleep/calibration/pause, fake lock failure, radio-stop-before-lock, timer cleanup; manual scan/“Возобновить” (Resume) reread session state; the single owned ticker remains after confirmed lock and notices fake unlock without a notification |
| PASS | Private-state parser | `--self-check`: Boolean/0/1; missing flag in a complete active session → unlocked, but does not confirm lock; malformed present flag, nil dictionary, inactive/incomplete session → unknown; explicit `1` confirms lock |
| PASS | Login presentation | `--self-check`: fake statuses enabled/notRegistered/requiresApproval/notFound/error, with no macOS registration |
| PASS | Metadata/shell syntax | `bash -n scripts/build-local.sh`; `plutil -lint` Info.plist, entitlements, project.pbxproj |
| PASS | Local .app | `./scripts/build-local.sh`; executable exists, bundle ID/14.0/arm64 assertions; does not launch the app |
| PASS | Signing | `codesign --verify --strict --verbose=2 build/WatchLock.app`: valid on disk / satisfies Designated Requirement; `codesign -dv`: adhoc,runtime, TeamIdentifier not set |
| PASS | Auditor | `python3 scripts/verify-safety.py --self-test` first RED on a prohibited fixture, then PASS; real audit PASS |
| PASS | Limited static/binary audit | app sources, direct undefined `nm -u` symbols, absence of old functions/Launcher/XIB/private linkage, empty signed entitlements, bundle contents, Xcode/CLI source parity |
| PASS | Diff whitespace | `git diff --check` |
| NOT RUN | `xcodebuild` | requires full Xcode; plist parsing/source parity **do not** replace an Xcode build |
| PARTIAL | GUI layout / keyboard / VoiceOver | The user showed screenshots of an installed previous build: at first, scanning was blocked in an “неизвестном” (unknown) session; then after locking and returning, the UI remained locked/suspended. The new build was not checked in the GUI; keyboard/VoiceOver were not checked. UI compilation is not rendered inspection |
| PARTIAL | Real lock | The user reported unlocking and showed a previous build with a confirmed weakSignal attempt. This is not our own hardware test; automated checks do not call `SACLockScreenImmediate`; the new build was not checked with real lock/unlock |
| NOT RUN | Apple Watch / mouse / keyboard | tests did not create a real CBCentralManager; real compatibility/radio consumption are unknown |
| NOT RUN | Native Auto Unlock | not checked; the app does not implement unlock or change system settings |
| PARTIAL | Bluetooth TCC / Login Item approval | The user enabled launch at login in the installed previous build; system status/subsequent login were not checked. Automated tests do not call real TCC/SMAppService.register |
| NOT RUN | Developer ID / notarization / Gatekeeper acceptance | account not used; only local ad-hoc; codesign verification does not mean notarization |

An early read-only CLI probe of CGSessionCopyCurrentDictionary **inside a sandbox** returned `sessionAvailable=false`. A separate read-only probe **outside the sandbox** on the same Mac returned a dictionary: private `CGSSessionScreenIsLocked` was absent, on-console=1, login-done=1. Neither probe tested the GUI app. A user screenshot of the previous build showed an “неизвестный” (unknown) session and blocked scanning; the corrected build was not installed in `/Applications`, and its GUI behavior was not tested.

After the change was agreed, a regression was added: self-check with the old adapter failed with `active session without private flag`; after the fix, self-check, 27 core tests, build, audit, and codesign passed. An independent read-only CLI probe compiled with the corrected `ScreenLockAdapter.swift` returned `sessionAvailable=true`, `lockFlagPresent=false`, `parsedState=unlocked`, `adapterState=unlocked`. It creates no GUI/Bluetooth and does not invoke locking; it checks the adapter against current macOS data, **not** app hardware behavior. The executable hash of the previously installed copy matched before and after work; it was not replaced.

## 2026-10-13 addendum: polling after locking

The user reported and showed a screenshot: monitoring enabled, primary Watch selected, weakSignal attempt marked confirmed, yet after normal return the UI remained locked/suspended. This is user evidence, **not** our own verification of real lock/unlock. A read-only probe of the system session source after returning produced a dictionary without the private flag but with on-console=1/login-done=1 and `adapterState=unlocked`. Previously `MonitoringEngine.needsTick` became false after confirmed lock, causing `AppDelegate.refresh` to remove the sole timer. If a private unlock notification was absent or arrived before the real state transition, no later recheck occurred. “Возобновить” (Resume) and opening settings also relied on cached state.

Regressions were added **before** the fix: `./scripts/test-core.sh` failed with 5 expectation errors in 2 new tests (enabled locked/unknown and confirmed lock/fault require polling); after a successful build, `--self-check` failed with `confirmed lock retains session ticker`. Then only the existing ticker lifecycle and a fresh session check before Resume/Settings were changed. Afterward, **29/29** core tests, build, and self-check PASS; fake confirmed lock retains the same timer, locked polling starts neither radio nor another lock, fake unlock without notification starts a new epoch without stale measurements, duplicate unlocked polls do not extend acquisition, sleep removes the timer, and a fault is not cleared automatically. The GUI app, real Bluetooth, and locking were not run; the installed `/Applications` copy was not replaced. Hardware verification of the new build remains **NOT RUN**.

## Manual hardware checklist

**Save your work first: the next test can really lock the Mac.** Make sure you know a normal way to authenticate. Do not run BLEUnlock simultaneously. Items below are still **NOT RUN**; mark PASS only after direct observation:

- [ ] Open .app; all text/buttons visible, Tab/VoiceOver, cancel removal without changes.
- [ ] Allow Bluetooth without Accessibility/FDA/root; no lock before selection/enabling.
- [ ] Scanning stops at 20 s / stop; advertisements do not trigger mass connections.
- [ ] Primary Apple Watch is found and really provides connected RSSI about every 2 s.
- [ ] Automatic general scan stops on connection; recovery: known first, 5/25 duty cycle.
- [ ] Calibration gathers 20+20 samples / 90 s; poor separation reports an error; apply only explicitly.
- [ ] Moving away requires real macOS authentication (not just display sleep / screensaver).
- [ ] Return; normal password/Touch ID/Apple Watch Auto Unlock work without app interference.
- [ ] After normal unlock, session updates and monitoring resumes without manual “Возобновить” (Resume), with new measurements.
- [ ] Leave a secondary iPhone on the desk — it does not prevent locking when the Watch moves away.
- [ ] Bluetooth mouse/keyboard work during scanning, RSSI, and recovery.
- [ ] Bluetooth off / permission revoked after active → one attempt with a reason, not a loop.
- [ ] Startup refusal / unknown lock state → suspension/error, not a loop.
- [ ] Sleep/wake clears stale samples and does not extend grace through duplicates; locked state does not start radio.
- [ ] A 15/30/60-minute pause survives sleep/lock; expiry while locked does not start radio.
- [ ] A → B → A change, late callbacks, quit: no stale presence/owned timers/scans.
- [ ] Login item actually shows enabled/approval/error after changes; stable .app path.
- [ ] Repeat on target macOS 14+; private API/flag may be absent.

## Material risks

Private ABI/state flags are not guaranteed by Apple; GUI/API and Apple Watch remain unverified. RSSI/UUID are not authentication, precise meters, or proof that the watch is worn. Body position/interference may cause false locks; an unstable BLE connection may produce persistent noSignal. On a lock error the app stops automation until explicit Resume and **does not promise a secured screen**. For guarantees, use native macOS lock policies independently of WatchLock.

## Process

At the time of this verification, work was on local branch `codex/watchlock` and nothing had been pushed/published/deployed; the user placed a previous build in `/Applications`, while the new `build/WatchLock.app` was not copied there. Full MIT/NOTICE retained; external images removed. Independent final review by gpt-6-sol (high, fresh/read-only), without nested agents. The reviewer reran 19 original tests/self-check/audit; no critical vulnerabilities were found, but four Important defects were identified. They were fixed in one test-backed pass:

1. Startup unavailability now requires explicit Resume; a pending initial state does not count as a refusal. UI/coordinator do not enable the mode or write it when Bluetooth is unavailable.
2. Every activation gets a fixed 15 s for the first measurement regardless of noSignalTimeout; fresh RSSI ends acquisition grace, including after wake.
3. Established-link loss makes one known retry; early failure → scan; subsequent scan-target failure / rapid repeat drop → cooldown25, without endless spin.
4. Recovery advertisements are not passed to the UI; publish only in explicit discovery mode.

Eight new core regression tests were first RED (28 issues in 26 tests; separate RED for the missing discovery-mode accessor), then **27/27 PASS**. Self-check additionally covered refusal to enable without Bluetooth without changing storage and zero-return-but-unconfirmed coordinator failure without automatic retry. Final build/self-check/audit/codesign were repeated after fixes. A second independent review was not run.
