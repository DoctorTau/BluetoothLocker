# Проверки WatchLock

Дата: 2026-10-12. Среда: macOS 26.6.2 (25G83), arm64, Swift 6.4,
Command Line Tools (`/Library/Developer/CommandLineTools`), **без полного Xcode**.
Цель binary: arm64-apple-macos14.0. Нет проверки исполнения на macOS 14.

## Автоматические результаты

| Статус | Проверка | Доказательство |
| --- | --- | --- |
| PASS | Основа форка | fetched `upstream-1.12.2` → `c33a132f9b65ecd8fd55954a5e097a77b86c8a92`; Git-история сохранена, upstream app не запускался |
| PASS | RED → GREEN ядра | Configuration/MonitoringEngine/RadioPolicy/LockVerification/Calibration: отсутствующие types до реализации → 27 deterministic tests в 5 suites |
| PASS | Full core suite | `./scripts/test-core.sh`; Swift Testing, 29 tests, без sleep/реального радио/lock |
| PASS | Координатор и storage | app executable `--self-check`: временный suite, неудачная validation/load сохраняет raw Data; corrupt coordinator не перезаписывает данные; основной/вторичный UUID, sleep/calibration/pause, fake lock failure, radio-stop-before-lock, timer cleanup; ручной поиск/«Возобновить» перечитывают сеанс; единственный owned ticker остаётся после confirmed lock и замечает fake unlock без notification |
| PASS | Private-state parser | `--self-check`: Boolean/0/1; отсутствующий flag в полном активном сеансе → unlocked, но не подтверждает lock; некорректный присутствующий flag, nil-словарь, inactive/incomplete session → unknown; явный `1` подтверждает lock |
| PASS | Login presentation | `--self-check`: fake statuses enabled/notRegistered/requiresApproval/notFound/error, без регистрации в macOS |
| PASS | Metadata/shell syntax | `bash -n scripts/build-local.sh`; `plutil -lint` Info.plist, entitlements, project.pbxproj |
| PASS | Локальный .app | `./scripts/build-local.sh`; executable существует, bundle id/14.0/arm64 assertions; не запускает приложение |
| PASS | Подпись | `codesign --verify --strict --verbose=2 build/WatchLock.app`: valid on disk / satisfies Designated Requirement; `codesign -dv`: adhoc,runtime, TeamIdentifier not set |
| PASS | Аудитор | `python3 scripts/verify-safety.py --self-test` сначала RED на запрещённом fixture, затем PASS; реальный audit PASS |
| PASS | Ограниченный static/binary audit | app sources, direct undefined `nm -u` symbols, отсутствие старых функций/Launcher/XIB/private linkage, пустые signed entitlements, bundle contents, Xcode/CLI source parity |
| PASS | Diff whitespace | `git diff --check` |
| NOT RUN | `xcodebuild` | требует полный Xcode; plist parse/source parity **не** заменяют Xcode build |
| PARTIAL | GUI layout / keyboard / VoiceOver | Пользователь показал скриншоты установленной предыдущей сборки: сначала поиск заблокирован при «неизвестном» сеансе, затем после блокировки и возврата UI оставался locked/suspended. Новая сборка в GUI не проверялась; keyboard/VoiceOver не проверены. Компиляция UI не считается rendered inspection |
| PARTIAL | Реальная блокировка | Пользователь сообщил о разблокировке и показал предыдущую сборку с confirmed weakSignal attempt. Это не собственный аппаратный тест; в автоматических проверках `SACLockScreenImmediate` не вызывается, новая сборка в реальном lock/unlock не проверена |
| NOT RUN | Apple Watch / мышь / клавиатура | реальный CBCentralManager не создавался тестами; реальная совместимость/потребление радио неизвестны |
| NOT RUN | Native Auto Unlock | не проверен; приложение не реализует unlock и не меняет системные настройки |
| PARTIAL | Bluetooth TCC / Login Item approval | Пользователь включил автозапуск в установленной предыдущей сборке; системный статус/повторный вход не проверены. Автотесты не вызывают реальные TCC/SMAppService.register |
| NOT RUN | Developer ID / нотарификация / Gatekeeper acceptance | учётная запись не использована; только local ad-hoc; codesign verify не означает нотарификацию |

Ранняя read-only CLI-проба CGSessionCopyCurrentDictionary **в sandbox** дала
`sessionAvailable=false`. Отдельная read-only проба **без sandbox** на том же Mac
вернула словарь: private `CGSSessionScreenIsLocked` отсутствует, on-console=1,
login-done=1. Ни одна из проб не является проверкой GUI-приложения. Пользовательский
скриншот предыдущей сборки показал «неизвестный» сеанс и заблокированный поиск;
исправленная сборка в `/Applications` не установлена и её GUI-поведение не проверено.

После согласования изменения добавлена регрессия: self-check со старым адаптером
завершился ошибкой `active session without private flag`; после исправления self-check,
27 core tests, сборка, аудит и codesign прошли. Независимая read-only CLI-проба,
скомпилированная с исправленным `ScreenLockAdapter.swift`, дала
`sessionAvailable=true`, `lockFlagPresent=false`, `parsedState=unlocked`,
`adapterState=unlocked`. Она не создаёт GUI/Bluetooth и не вызывает блокировку;
это проверка адаптера на текущих данных macOS, **не** аппаратный тест приложения.
Хеш executable установленной предыдущей копии до/после работ совпал — она не заменялась.

## Дополнение 2026-10-13: опрос после блокировки

Пользователь сообщил и показал скриншот: мониторинг включён, основные Watch выбраны,
попытка weakSignal отмечена как подтверждённая, но после штатного возврата UI
оставался locked/suspended. Это пользовательское свидетельство, **не** собственная
проверка реального lock/unlock. Read-only проба системного источника сеанса
после возврата дала словарь без private flag, но on-console=1/login-done=1 и
`adapterState=unlocked`. Ранее `MonitoringEngine.needsTick` становился false после
confirmed lock, из-за чего `AppDelegate.refresh` удалял единственный таймер. Если
private unlock notification отсутствовал или пришёл до реальной смены состояния,
следующей перепроверки не происходило. Действия «Возобновить» и открытие настроек
также опирались на кешированное состояние.

Регрессии добавлены **до** исправления: `./scripts/test-core.sh` завершился с 5
ошибками ожиданий в 2 новых тестах (enabled locked/unknown, confirmed lock/fault
требуют polling); после успешной сборки `--self-check` завершился с
`confirmed lock retains session ticker`. Затем изменены только lifecycle existing
ticker и свежая проверка сеанса перед Resume/Settings. После изменения — **29/29**
core tests, build и self-check PASS; fake confirmed lock сохраняет тот же таймер,
locked poll не запускает радио/повторный lock, fake unlock без notification создаёт
новую эпоху без старых измерений, дубли unlocked poll не продлевают acquisition,
сон удаляет таймер, fault не очищается автоматически. GUI-приложение, реальный
Bluetooth и блокировка не запускались; установленная `/Applications` копия не
заменялась. Аппаратная проверка новой сборки остаётся **NOT RUN**.

## Ручной аппаратный чек-лист

**Сначала сохраните работу: следующий тест действительно может заблокировать Mac.**
Убедитесь, что знаете штатный способ аутентификации. Не включайте BLEUnlock одновременно.
Пункты ниже пока **NOT RUN**, отмечать PASS только после реального наблюдения:

- [ ] Открыть .app; все строки/кнопки видимы, Tab/VoiceOver, отмена удаления без изменений.
- [ ] Разрешить Bluetooth без Accessibility/FDA/root; до выбора/включения нет блокировки.
- [ ] Поиск прекращается@20 с / stop; объявления не вызывают массовые соединения.
- [ ] Основные Apple Watch обнаруживаются и действительно дают connected RSSI каждые ~2 с.
- [ ] При подключении automatic general scan остановлен; recovery: known first, 5/25 duty cycle.
- [ ] Калибровка даёт 20+20 samples / 90 с, плохое разделение выдаёт ошибку, apply только явно.
- [ ] Уход требует настоящей аутентификации macOS (не просто display sleep / screensaver).
- [ ] Вернуться; штатный пароль/Touch ID/Apple Watch Auto Unlock работают без вмешательства app.
- [ ] После штатной разблокировки сеанс обновляется и мониторинг возобновляется без ручного «Возобновить», с новыми измерениями.
- [ ] Оставить вторичный iPhone на столе — он не препятствует блокировке от ухода с Watch.
- [ ] Bluetooth мышь/клавиатура работают во время поиска, RSSI и recovery.
- [ ] Bluetooth off / permission revoke после active → одна попытка с причиной, не loop.
- [ ] Startup refusal / unknown lock state → suspension/error, не loop.
- [ ] Сон/wake clears stale samples, не продлевает grace дубликатами; locked state не запускает radio.
- [ ] Пауза 15/30/60 переживает сон/lock; expiry при locked не запускает radio.
- [ ] Смена A → B → A, late callbacks, quit: нет старого присутствия/owned timers/scans.
- [ ] Login item фактически enabled/approval/error после изменения; стабильный путь .app.
- [ ] Повторить на целевой версии macOS 14+; private API/flag могут отсутствовать.

## Материальные риски

Private ABI/state flags не гарантируются Apple; GUI/API и Apple Watch ещё не проверены.
RSSI/UUID не являются аутентификацией, точными метрами или признаком ношения часов.
Положение тела/помехи могут давать ложные блокировки, а отсутствие стабильного BLE
соединения — постоянные noSignal. При ошибке lock приложение остановит автоматику
до явного resume и **не обещает защищённый экран**. Для гарантий используйте штатные
правила блокировки macOS, независимо от WatchLock.

## Процесс

Локальная ветка `codex/watchlock`. Ничего не push/publish/deploy; пользователь сам
поместил предыдущую сборку в `/Applications`, а новый `build/WatchLock.app` туда не
копировался. Полный MIT/NOTICE сохранены; внешние изображения удалены. Независимое
финальное ревью выполнено gpt-6-sol (high, fresh/read-only), без вложенных агентов.
Reviewer повторил 19 исходных тестов/self-check/audit; критических уязвимостей не выявил,
но нашёл четыре Important дефекта. Они исправлены одним test-backed проходом:

1. Startup unavailable теперь требует явного resume; pending initial state не считается
   отказом. UI/координатор не включают режим при недоступном Bluetooth и не записывают его.
2. Каждая активация получает фиксированные 15 с на первое измерение независимо от
   noSignalTimeout; fresh RSSI завершает acquisition grace, включая wake.
3. Established-link loss делает один known retry; ранняя failure → scan, последующая
   scan-target failure / быстрый повторный обрыв → cooldown25, без бесконечного spin.
4. Recovery объявления не передаются в UI; publish только в explicit discovery mode.

Новые 8 core regression tests сначала RED (28 issues в 26 тестах; отдельный RED на
отсутствующий discovery-mode accessor), затем **27/27 PASS**. Self-check дополнен
отказом включения без Bluetooth без изменения storage и zero-return-but-unconfirmed
coordinator failure без автоматического retry. Финальные build/self-check/audit/codesign
повторены после исправлений. Повторное независимое ревью не запускалось.
