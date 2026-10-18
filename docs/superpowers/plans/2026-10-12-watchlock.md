# WatchLock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Собрать персональный macOS-форк BLEUnlock, который блокирует Mac при уходе с основным BLE-устройством, не получает пароль и не разблокирует экран.

**Architecture:** Сохраняется подходящая AppKit/CoreBluetooth-основа. Чистое Foundation-ядро принимает события и монотонное время, выдаёт действия и тестируется без оборудования. Bluetooth, закрытый адаптер блокировки и UI исполняются последовательно на главной очереди; у всех сроков один владелец.

**Tech Stack:** Swift, Foundation, AppKit, CoreBluetooth, ServiceManagement, CoreGraphics, XCTest; стандартные macOS-инструменты сборки и Python 3 только для локального аудита.

**Spec:** `/Users/shatravkada/Documents/ChatGPT/MacLocker/docs/superpowers/specs/2026-10-12-watchlock-design.md`.

## Global Constraints

- Название WatchLock; bundle identifier `local.shatravkada.WatchLock`; macOS 14+, первая сборка arm64.
- Основа BLEUnlock 1.12.2, commit `c33a132f9b65ecd8fd55954a5e097a77b86c8a92`; MIT, авторство Takeshi Sone и применимые upstream credits сохраняются.
- Только блокировка: никакого пароля/Keychain, клавиатурных событий, автоматической разблокировки, скриптов, MediaRemote, сетевой проверки обновлений или внутренних Bluetooth-баз.
- Никаких сторонних/сетевых зависимостей времени выполнения, Accessibility, Full Disk Access или root. Сон дисплея и заставка не подменяют блокировку.
- Только основное устройство влияет на присутствие; настройки каждого устройства сохраняются отдельно. Автоматический мониторинг первоначально выключен.
- Значения: порог −75 dBm, гистерезис 5 dB, задержка 5 с, свежесть 15 с, RSSI каждые 2 с, поиск 20 с, восстановление 5 с / пауза 25 с, подтверждение блокировки 3 с.
- Диапазоны настроек: порог −100…−30 dBm, задержка 1…60 с, свежесть 5…300 с. Паузы только 15/30/60 минут; период после пробуждения до 15 с не продлевается повторными событиями.
- Калибровка: два этапа по 20 принятых измерений, максимум 90 с на этап; перцентили 20/80, разделение минимум 10 dB, применение порога только явно.
- Один писатель в текущем checkout. Не публиковать, не push, не устанавливать в Applications, не менять системные настройки и не запускать внешние workflows.
- Реальные блокировки не выполняются из автоматических тестов. Аппаратную совместимость, подпись и нотарификацию нельзя объявлять проверенными без соответствующего результата.

## Review Focus

1. Повреждённое/старое хранилище: не стирать данные, не активировать блокировку из некорректной конфигурации — тесты Task 1.
2. Просроченный callback после A → B → A или паузы: не восстановить прежние измерения и соединения — тесты Tasks 2–3.
3. Сон одновременно с паузой/калибровкой и повторные события wake/unlock: не снять паузу и не продлить grace period — тесты Tasks 2, 5.
4. Возврат 0 без доказанного экрана входа, отсутствующий/необычный private flag: ошибка, не успех и не цикл повторов — тесты Task 4.
5. Неуспешное сохранение/регистрация login item или отмена UI: не показывать применённые настройки и не удалять устройство — тесты Tasks 1, 5.

---

## Карта файлов

Все пути ниже относительны к `/Users/shatravkada/Documents/ChatGPT/MacLocker`.

| Файл | Назначение |
| --- | --- |
| `Package.swift` | Локальная библиотека WatchLockCore и XCTest; без dependencies |
| `WatchLock/Core/Configuration.swift` | Codable-конфигурация, валидация, операции со списком устройств |
| `WatchLock/Core/MonitoringEngine.swift` | Присутствие, свежесть, пауза, события сеанса и одиночный запрос блокировки |
| `WatchLock/Core/RadioPolicy.swift` | Сроки поиска/подключения/RSSI, поколения и отмена действий |
| `WatchLock/Core/LockVerification.swift` | Проверка результата и срока подтверждения без системного lock-вызова |
| `WatchLock/Core/Calibration.swift` | Сбор измерений, сроки этапов, предложение порога |
| `WatchLock/BLE.swift` | Изменённый upstream-транспорт CoreBluetooth |
| `WatchLock/ScreenLockAdapter.swift` | Динамический private API и чтение состояния экрана |
| `WatchLock/ConfigurationStore.swift` | Сохранение валидного snapshot в отдельном UserDefaults-домене |
| `WatchLock/AppDelegate.swift`, `WatchLock/main.swift` | Меню, координация компонентов, жизненный цикл и запуск без XIB |
| `WatchLock/SettingsWindowController.swift` | Русские настройки, список устройств, диагностика и калибровка |
| `WatchLock/Info.plist`, `WatchLock/WatchLock.entitlements` | Metadata, Bluetooth usage description, минимальные полномочия |
| `WatchLock.xcodeproj/project.pbxproj`, shared scheme | Проект Xcode, arm64/macOS 14, без старого Launcher и private linkage |
| `Tests/WatchLockCoreTests/*Tests.swift` | Детерминированные проверки конфигурации, состояний, радио и калибровки |
| `scripts/build-local.sh`, `scripts/verify-safety.py` | Локальный .app и аудит запрещённых функций с self-check |
| `LICENSE`, `NOTICE`, `README.md`, `docs/UPSTREAM.md`, `docs/VERIFICATION.md` | Лицензии, происхождение, установка и фактический статус проверок |

Приложение и Swift Package используют одни и те же файлы Core, без второй реализации алгоритмов. В Xcode они входят в app target; Package.swift компилирует их как WatchLockCore для тестов. Настройки компиляции app: Swift language mode 5, deployment target 14.0; новый Swift toolchain не требует переписывать upstream на Swift 6 strict concurrency.

## Task 1: Происхождение форка и конфигурация устройств

**Files:** Package.swift; WatchLock/Core/Configuration.swift; Tests/WatchLockCoreTests/ConfigurationTests.swift; LICENSE; NOTICE; docs/UPSTREAM.md; .gitignore; импортированное upstream-дерево.

**Interfaces:** `DeviceSettings: Codable, Equatable` с `threshold: Double`, `weakSignalDelay: TimeInterval`, `noSignalTimeout: TimeInterval`, default initializer и `validate() throws`. `SavedDevice: Codable, Equatable` с `id: UUID`, `name: String`, `settings: DeviceSettings`. `Configuration: Codable, Equatable` с `version: Int` (текущая версия 1), `devices: [SavedDevice]`, `primaryID: UUID?`, `monitoringEnabled: Bool`; `validate() throws`, `static decode(_ data: Data) throws -> Configuration`, `encoded() throws -> Data`, mutating `add(_:) throws`, `update(_:) throws`, `selectPrimary(_:) throws`, `remove(_:)`. Ошибки — `ConfigurationError: Error`, не force unwrap.

- [x] **Step 1: Импортировать ровно базовый commit, не собирая и не запуская upstream.** Создать `codex/watchlock`; fetch указанного тега из публичного upstream, проверить `rev-parse` против полного SHA, затем merge с существующим документационным коммитом через `--allow-unrelated-histories`. Проверить upstream AGENTS.md и лицензии ещё раз. Переименовать BLEUnlock/ и BLEUnlock.xcodeproj в WatchLock/ и WatchLock.xcodeproj; сразу не объявлять проект собираемым — build references завершает Task 6. Не переносить чужую developer team или старый bundle identifier в конечный проект.
- [x] **Step 2: Создать локальный Package.swift и падающие ConfigurationTests.** Assertions: defaults равны −75/5/15; дубли UUID/неизвестный primary/NaN/параметры вне диапазона отклоняются; remove(primary) делает `primaryID == nil && monitoringEnabled == false`; round-trip сохраняет все устройства и настройки; decode повреждённого JSON бросает ошибку. Добавление пустого имени использует UUID, но не создаёт криптографическое доверие.
- [x] **Step 3: Запустить `swift test --filter ConfigurationTests`.** До реализации ожидается compile failure отсутствующего типа или failed assertion, не инфраструктурная ошибка; сохранить результат.
- [x] **Step 4: Реализовать указанные модели и методы.** Для неизвестной версии формата конфигурации использовать явную ошибку; не исправлять разрушительно. Добавить полный MIT, авторство и NOTICE с применимыми уведомлениями для сохранённых upstream-изображений; зафиксировать источник и SHA.
- [x] **Step 5: Повторить `swift test --filter ConfigurationTests`.** Все проверки проходят, dependencies Package.swift пусты. Коммит только файлов этой задачи: `feat: add validated trusted device configuration`.

## Task 2: Тестируемая машина мониторинга

**Files:** WatchLock/Core/MonitoringEngine.swift; Tests/WatchLockCoreTests/MonitoringEngineTests.swift.

**Interfaces:** `MonitoringState` = nearby/far/noSignal/bluetoothUnavailable/suspended. `BluetoothAvailability` = available/unavailable/unauthorized. `ScreenState` = locked/unlocked/unknown. `LockReason` = weakSignal/noSignal/bluetoothUnavailable/permissionRevoked/manual. `LockOutcome` = confirmed/failed(String). `MonitoringEffect` = startRadio(UUID, UInt64)/stopRadio/requestLock(LockReason), Equatable. `MonitoringEvent` = start(primary: SavedDevice)/sample(id: UUID, rssi: Int, generation: UInt64)/bluetoothChanged(BluetoothAvailability)/sessionChanged(ScreenState)/sleep/wake/pause(minutes: Int)/resume/calibrationChanged(Bool)/lockCompleted(LockOutcome)/tick/stop. `MonitoringEngine` имеет default init, readonly `state`, `generation`, `lastMeasurementAt`, `rawRSSI`, `smoothedRSSI`; `mutating handle(_ event: MonitoringEvent, now: TimeInterval) -> [MonitoringEffect]`.

- [x] **Step 1: Написать падающие MonitoringEngineTests с явным временем.** Fixture watch использует фиксированный UUID и DeviceSettings defaults; до start engine получает bluetoothChanged(.available) и sessionChanged(.unlocked). Основные assertions:

```swift
_ = engine.handle(.start(primary: watch), now: 0)
XCTAssertEqual(engine.state, .noSignal)
XCTAssertEqual(engine.handle(.tick, now: 15), [.requestLock(.noSignal)])
XCTAssertEqual(engine.handle(.tick, now: 16), [])
```

Также: −60@0, −95@2, −55@4 не блокируют @8; −90@0/2/4 блокируют @5; 0/127/ошибочный UUID/старое generation не обновляют свежесть. Порог −75 и восстановление −70 закрепляются assertions. Вторичный iPhone −40 не переносит срок основных часов @15.
- [x] **Step 2: Запустить `swift test --filter MonitoringEngineTests`, убедиться в RED.** Затем добавить cases: Bluetooth off/unauthorized после активации → один requestLock; initial refusal → ни одного; sleep → stopRadio; wake@100 и повтор wake@110 → дедлайн 115; старые samples очищены. A → B → A инвалидирует callbacks A из первого поколения. Пауза@0 на 15 минут сохраняется через сон; завершение паузы во сне не запускает радио. Unknown screen → suspension, не «разблокировано».
- [x] **Step 3: Реализовать reducer без таймеров и системных вызовов.** Последние пять валидных, ещё свежих samples; фиксированный гистерезис; точные монотонные дедлайны; idempotent wake/resume для уже активного запуска. Первоначальное отсутствие сигнала получает 15 секунд независимо от повторов подключения. Lock failure устанавливает fault suspension до явного resume, confirmed очищает радиооперации. Calibration suppresses lock, но не останавливает RSSI.
- [x] **Step 4: Запустить `swift test --filter MonitoringEngineTests`, затем весь `swift test`.** PASS всех перечисленных сценариев, без `sleep`, реального Bluetooth и экранной блокировки. Коммит: `feat: implement deterministic monitoring state machine`.

## Task 3: Радиополитика и CoreBluetooth-транспорт

**Files:** WatchLock/Core/RadioPolicy.swift; WatchLock/BLE.swift; Tests/WatchLockCoreTests/RadioPolicyTests.swift; удалить WatchLock/LEDeviceInfo.swift и WatchLock/appleDeviceNames.swift после переноса безопасной основы.

**Interfaces:** `RadioPolicy` имеет readonly `generation`, `isScanning`, `nextDeadline`, default init и `mutating handle(_ event: RadioEvent, now: TimeInterval) -> [RadioAction]`. `RadioEvent` = monitor(id: UUID, generation: UInt64)/startDiscovery/stopDiscovery/discovered(id: UUID, generation: UInt64)/connected(id: UUID, generation: UInt64)/disconnected(id: UUID, generation: UInt64)/rssiCompleted(id: UUID, generation: UInt64)/tick/stop. `RadioAction` = startScan(discovery: Bool)/stopScan/connect(UUID, UInt64)/disconnect(UUID)/readRSSI(UUID, UInt64), Equatable. Протокол `BLEControlling` объявляет readonly `isScanning: Bool`, `isConnected: Bool`, `nextDeadline: TimeInterval?`, методы `apply(_ effect: MonitoringEffect, now: TimeInterval)`, `startDiscovery(now: TimeInterval)`, `stopDiscovery(now: TimeInterval)`, `tick(now: TimeInterval)`, `stop()` и get/set callbacks `onMeasurement: ((UUID, Int, UInt64) -> Void)?`, `onAvailability: ((BluetoothAvailability) -> Void)?`, `onConnectionChanged: ((Bool) -> Void)?`, `onDiscovery: ((UUID, String?, Int) -> Void)?`. `BLE` реализует протокол и применяет политику только на main queue; подставная реализация не создаёт CBCentralManager.

- [x] **Step 1: Написать падающие RadioPolicyTests.** Assertions: discovery@0 выдаёт один startScan, повтор@1 не создаёт второй и не меняет конец@20; stop@3 закрывает scan; известный connect@0 истекает@5, scan работает@5…10, следующая попытка не раньше@35; connected закрывает автоматический scan; readRSSI каждые 2 секунды, но не повторяется до rssiCompleted. Чужой UUID не порождает connect. startDiscovery во время recovery заменяет его, а не дублирует.
- [x] **Step 2: Запустить `swift test --filter RadioPolicyTests` и получить RED.** Дополнительные assertions: stop идемпотентен; nextDeadline после полного stop равен nil; поздний didConnect после stop отменяется, а не возобновляет polling; ошибки и callbacks A → B → A не оживляют прежний режим.
- [x] **Step 3: Реализовать RadioPolicy и изменить upstream BLE.swift.** Сначала сохранённый peripheral/retrievePeripherals, затем ограниченные connect и поиск 5/25. Только очередь nil/main. В discovery показывать advertisement name/UUID/RSSI; не вызывать discoverServices/readValue для модели. Отделить поколение запуска и ожидающий RSSI-request: старый delegate/request не принимается при повторном выборе того же UUID. Ошибка readRSSI завершает запрос, но не передаёт sample в MonitoringEngine; advertisement не подменяет connected readRSSI. Никакого общего scan при рабочем соединении, кроме явно запрошенного пользователем discovery.
- [x] **Step 4: Запустить RadioPolicyTests и весь `swift test`.** Подставный транспорт записывает точные start/stop/connect/readRSSI actions, подтверждает порядок отмены и отсутствие ресурсов после stop. Проверка реального CoreBluetooth остаётся отдельной, не заменяется этим тестом. Коммит: `feat: bound Bluetooth discovery and reconnection`.

## Task 4: Адаптер настоящей блокировки

**Files:** WatchLock/Core/LockVerification.swift; WatchLock/ScreenLockAdapter.swift; Tests/WatchLockCoreTests/LockVerificationTests.swift; удалить lowlevel.c/h, MediaRemote.h и bridging header; убрать framework references из будущего app target.

**Interfaces:** `LockVerification` имеет `init(returnCode: Int32, now: TimeInterval)` и `mutating observe(_ state: ScreenState, now: TimeInterval) -> LockOutcome?`; терминальный результат выдаётся один раз. Протокол `ScreenLocking` объявляет `screenState() -> ScreenState` и `requestLock() throws -> Int32`. `ScreenLockAdapter` реализует этот протокол и `static parseLockFlag(_ value: Any?) -> ScreenState`; Any ограничен границей системного CFDictionary. `ScreenLockError: Error` включает unavailableFramework/unavailableSymbol. Runtime-проверка состояния экрана остаётся в адаптере; reducer знает только ScreenState.

- [x] **Step 1: Написать падающие LockVerificationTests.** Точный смысл:

```swift
var attempt = LockVerification(returnCode: 0, now: 0)
XCTAssertNil(attempt.observe(.unlocked, now: 2))
XCTAssertEqual(attempt.observe(.locked, now: 2.5), .confirmed)
XCTAssertNil(attempt.observe(.locked, now: 3))
```

Другие assertions: unlocked/unknown до конца 3 секунд → failed, ненулевой code → failed даже без дальнейших событий; никаких автоматических retries. Отсутствующий private flag, 2, строка и неверный тип дают unknown, только Boolean/числовые 0/1 допускаются.
- [x] **Step 2: Запустить `swift test --filter LockVerificationTests`, получить RED.** Затем реализовать deadline reducer и parser private flag в адаптере; parser покрыть отдельным assert-based self-check, который не вызывает requestLock и не создаёт CBCentralManager.
- [x] **Step 3: Реализовать динамическую загрузку системного login.framework и символа SACLockScreenImmediate.** Использовать upstream ABI `@convention(c) () -> Int32`, проверять dlopen/dlsym до вызова, не подставлять отсутствующий символ. Не линковать private framework статически. Блокировка/ключ CGSSessionScreenIsLocked/private notifications изолированы и документированы. Никакой заставки, display sleep или CGEvent fallback.
- [x] **Step 4: Запустить LockVerificationTests и весь `swift test`.** Проверить отсутствующий symbol через подставный adapter: displayed failure и stopRadio, lastConfirmedLock не меняется. Реальный lock-вызов пока не исполнять. Коммит: `feat: verify screen locking through isolated adapter`.

## Task 5: Калибровка, хранение и русский интерфейс

**Files:** WatchLock/Core/Calibration.swift; WatchLock/ConfigurationStore.swift; WatchLock/AppDelegate.swift; WatchLock/SettingsWindowController.swift; WatchLock/main.swift; Tests/WatchLockCoreTests/CalibrationTests.swift и ConfigurationTests.swift; удалить checkUpdate.swift, старый Launcher, неиспользуемые XIB/локализации и запрещённые реализации AppDelegate.

**Interfaces:** `CalibrationStage` = idle/desk/away/ready/failed(String); `Calibration` имеет default init, readonly stage/count/proposedThreshold и `mutating startDesk(now: TimeInterval)`, `startAway(now: TimeInterval)`, `add(rssi: Int, now: TimeInterval)`, `tick(now: TimeInterval)`, `cancel()`. `static suggestThreshold(near: [Int], far: [Int]) throws -> Double` использует точные перцентили из spec. `ConfigurationStore.init(defaults: UserDefaults)`; `load() throws -> Configuration`, `save(_ configuration: Configuration) throws`. `AppDelegate.init(lockAdapter: any ScreenLocking, radio: any BLEControlling, store: ConfigurationStore)` позволяет подставить lock и radio для self-check; delegate владеет engine, radio, calibration и единым Timer. UI и наблюдатели создаются только в applicationDidFinishLaunching, не в initializer. SettingsWindowController получает typed snapshot и actions, не обращается к Bluetooth напрямую.

- [x] **Step 1: Написать падающие CalibrationTests.** Двадцать −60 и двадцать −90 → threshold −75; 19 samples → предложение отсутствует; near −70/far −75 → ошибка; −120/−100 → ошибка диапазона, не clamp; stage истекает ровно@90; cancel сохраняет прежний применённый порог. Проверить линейную интерполяцию percentile на неоднородной выборке, недопустимые RSSI не увеличивают count.
- [x] **Step 2: Запустить `swift test --filter CalibrationTests`, получить RED; реализовать Calibration.** Порог только предлагается, не записывается автоматически. При смене основного, disconnect, Bluetooth error, sleep, lock и пользовательской pause координация отменяет сбор и восстанавливает прежний режим только при отсутствии иной suspension.
- [x] **Step 3: Реализовать ConfigurationStore, покрыть его assert-based self-check на отдельном временном UserDefaults suite.** Failed validation оставляет прежний Data без изменения; corrupt Data остаётся в хранилище после failed load. Удалять только временный тестовый suite. Реальный домен BLEUnlock/Keychain никогда не открывать. Проверки относятся к storage API, не обещают транзакционность UserDefaults или принудительный durable flush на диск.
- [x] **Step 4: Изменить AppDelegate и создать программный UI/main.** Сохранить полезный upstream-подход NSStatusBar/NSMenu; убрать все prohibited callers, password strings, Accessibility, script/media/update hooks и старый launch helper. Menu icon — штатный SF Symbol, без новой графики. UI: список и основной, add/remove/select, scan start/stop, raw/mean/age/connection/scan status, параметры, enable/resume/pause, lock reason/error/time и calibration progress/apply/cancel. Native подписи и keyboard access. Confirmation отмены удаления не меняет конфигурацию. Login toggle использует фактический SMAppService.status и ошибки register/unregister, не оптимистический success.
- [x] **Step 5: Подключить единственный ticker к policy deadlines, engine.tick, calibration.tick и LockVerification.observe.** Во время активных сроков interval 1 секунда; RSSI-запросы остаются раз в 2 секунды. При requestLock сначала stop radio, затем однократный вызов adapter. Уничтожать ticker при отсутствии сроков; при stop/terminate отменять radio, pending requests и observers. Session/private notifications только инициируют screenState-перепроверку; display wake не считается unlock. На wake сначала определяется состояние экрана, затем обрабатываются события engine. Startup с unavailable Bluetooth не активирует lock; после активного мониторинга unavailable инициирует одну попытку. Попытка и confirmed lock сохраняются отдельно. Не вызывать соединение/блокировку из UI обновления.
- [x] **Step 6: Запустить `swift test` и assert-based self-checks.** Координацию проверять с FakeRadio и FakeScreenLock, не вызывая applicationDidFinishLaunching/NSApplication или реальный manager: calibration cancel + sleep не startRadio; pause expiry при locked screen не startRadio; неверные параметры/failed store не применены; вторичный iPhone не меняет engine; stop/terminate делают owned Timer nil/invalid. Представление login item проверять подставными SMAppService.Status/error без register/unregister. Перед инициализацией NSApplication/CBCentralManager предусмотрен `--self-check`, исполняющий только эти проверки и private-flag parser. Коммит: `feat: add Russian controls and calibrated monitoring`.

## Task 6: Собираемый проект и локальный .app

**Files:** WatchLock.xcodeproj/project.pbxproj и shared scheme; WatchLock/Info.plist; WatchLock/WatchLock.entitlements; scripts/build-local.sh; .gitignore; README.md.

**Interfaces:** `scripts/build-local.sh` без аргументов создаёт только `build/WatchLock.app`, завершается ненулевым code при ошибке компиляции/упаковки/подписи. Swift sources Core и app компилируются в один executable через `xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0`; SDK берётся через `xcrun --sdk macosx --show-sdk-path`. Build не запускает приложение и не выполняет lock. Generated outputs исключены из Git.

- [x] **Step 1: Добавить проект/схему и plist, обновив upstream build settings.** Target WatchLock, macOS 14.0, arm64, новый bundle identifier; удалить Launcher, source-mutating build number script, private linkage/MediaRemote, developer team и provisioning references. Metadata сохраняет авторство/MIT; русский NSBluetoothAlwaysUsageDescription; UI стартует без NSMainNibFile. Entitlements не содержат automation, camera, microphone, root-helper или сетевых разрешений.
- [x] **Step 2: Создать минимальный build-local.sh с `set -euo pipefail`.** Использовать фиксированные source dirs, безопасные кавычки и только собственный build directory; не удалять пользовательские данные. Компиляция, app bundle, копирование plist/лицензионных файлов, ad-hoc codesign с hardened runtime; при отказе подписи не объявлять build signed. У Xcode и скрипта должен быть одинаковый список исходников и metadata.
- [x] **Step 3: Выполнить `bash -n scripts/build-local.sh`, `plutil -lint WatchLock/Info.plist WatchLock/WatchLock.entitlements WatchLock.xcodeproj/project.pbxproj`, затем `./scripts/build-local.sh`.** Синтаксическая проверка не заменяет сборку. Script assertions: executable существует/исполняемый, plist содержит правильный bundle identifier/минимальную ОС, `file` показывает arm64. Запустить созданный executable только с `--self-check`: exit 0 и явный отчёт без UI, Bluetooth, сетевых запросов и реального lock.
- [x] **Step 4: Проверить `codesign --verify --strict --verbose=2 build/WatchLock.app` и `codesign -dv --verbose=4 build/WatchLock.app`.** Записать фактический ad-hoc статус. Нотарификация не выполнялась; Gatekeeper не менять. При появлении полного Xcode отдельно выполнить `xcodebuild -project WatchLock.xcodeproj -scheme WatchLock -configuration Debug -derivedDataPath build/xcode CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build`. Без Xcode этот пункт остаётся NOT RUN, не PASS.
- [x] **Step 5: Запустить весь `swift test`; сверить Xcode Sources с build script.** Коммит: `build: package local arm64 WatchLock application`.

## Task 7: Аудит результата и передача

**Files:** scripts/verify-safety.py; README.md; docs/VERIFICATION.md; NOTICE; конечное дерево app/project и итоговый Git diff.

**Interfaces:** `python3 scripts/verify-safety.py` проверяет app sources, plist/entitlements, PBX build references и при наличии собранный binary; exit 0 означает прохождение конкретно перечисленных статических проверок. `--self-test` запускает assert-based проверки самого аудитора на фиктивных строках/fixture, не читая чужие проекты.

- [x] **Step 1: Написать падающий self-test аудитора.** `SecItemCopyMatching`, keyboard CGEvent/AXIsProcessTrusted, URLSession, NSAppleScript/Process execution, MRMediaRemote, SQLite3 и paths внутренних Bluetooth-баз должны обнаруживаться; упоминания ограничений в README не считаются runtime caller. SACLockScreenImmediate/private lock-state literals разрешены только в ScreenLockAdapter. Source regex не выдаётся за доказательство отсутствия любой возможной сети.
- [x] **Step 2: Реализовать auditor стандартной библиотекой Python и выполнить `python3 scripts/verify-safety.py --self-test`, затем `python3 scripts/verify-safety.py`.** Проверить также прямые undefined symbols app executable через `nm -u`, состав app bundle и отсутствие ненужных entitlements/старого Launcher. Все запрещённые runtime implementations удалены из конечных tracked sources, не только не включены в build.
- [x] **Step 3: Дополнить README и VERIFICATION.** Команды Swift/Xcode/local build, запуск .app, первичная настройка, калибровка, разрешение Bluetooth, login item approval, ручная очистка старого BLEUnlock Keychain-элемента, ограничения UUID/RSSI/private API и scanner duty cycle. Для каждой проверки указать PASS/FAIL/NOT RUN с командой/результатом; отделить static/core/self-check/build от GUI и оборудования.
- [x] **Step 4: Выполнить финальные `swift test`, local build, executable `--self-check`, safety audit, codesign verification и `git diff --check`.** README не обещает стабильное Apple Watch соединение, нахождение часов на руке, UUID-фильтр peripheral, метры или нотарификацию. При ошибке не заменять проверку утверждением «должно работать».
- [x] **Step 5: Перед аппаратным тестом явно предупредить о блокировке.** Ручной чек-лист: обнаружение основных Apple Watch, 2-секундный RSSI без фонового scan, уход и настоящее требование аутентификации, возврат/штатный Auto Unlock, вторичный iPhone на столе, мышь/клавиатура, Bluetooth off, permission revoke, pause, sleep/wake. Без доступных часов/GUI/версии ОС соответствующие пункты остаются NOT RUN; автоматически lock не запускать.
- [x] **Step 6: Коммит `docs: record WatchLock validation and limitations`; независимое ревью всего изменения.** Один reviewer `gpt-6-sol`, reasoning high, fresh context, read-only, без вложенных агентов; проверить spec, safety, late callbacks и cleanup. Исправления выполняет тот же писатель; после двух неудачных попыток остановиться и показать доказательства. Финальный ответ: источник/путь .app, проверено/не проверено, подпись/нотарификация и материальные риски. Ничего не push/publish.

## Самопроверка и исполнение

Spec покрыта Tasks 1–7; все состояния/эффекты/общие типы задаются в Tasks 1–2 и используются с одинаковыми именами. Все пять Review Focus имеют проверки у владельца кода. RED→GREEN фиксируется отдельно от проблем toolchain. В плане нет выполняемых продуктовых файлов: code snippets — требования к будущим тестам, не заявленная реализация.

Read-only проверка в текущем терминальном контексте вернула nil из CGSessionCopyCurrentDictionary (`sessionAvailable=false`). Это не результат запуска GUI-приложения и не доказательство отсутствия поддержки блокировки в ОС. Подтверждение системного состояния нужно отдельно проверить из настоящего GUI-сеанса; CLI self-check проверяет parser/fakes, не объявляет текущий экран разблокированным.

Рекомендуемый метод — **Native**: основной агент реализует задачи последовательно как единственный писатель, затем отдельный агент проверяет итог. Компоненты тесно связаны интерфейсами; семь свежих исполнителей и семь отдельных контекстов ревью увеличат накладные расходы без ускорения в этом небольшом персональном приложении. По правилам процесса пользователь сначала проверяет этот план и подтверждает метод; до этого импорт upstream и реализация не начинаются.

## Итог исполнения

Native-задачи 1–7 выполнены; одно независимое ревью выявило четыре Important дефекта, исправленных с RED→GREEN регрессиями (27 тестов). Фактические команды, ограничения и NOT RUN указаны в docs/VERIFICATION.md. Галочки означают выполнение шага/фиксацию ограничения, не аппаратный PASS. Xcode build, интерактивный GUI и hardware check-list остаются NOT RUN. Ветка codex/watchlock сохранена локально без merge/push.
