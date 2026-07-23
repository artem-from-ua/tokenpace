---
status: accepted
date: 2026-07-22
---

# ADR-0020: Вікно Troubleshoot і діагностичний канал через чистий пайплайн

## Контекст

Досі єдиний спосіб діагностувати проблеми з опитуванням usage API — читати `log stream` у терміналі.
Popup показує лише агреговані дані (health, «Updated N хв тому»), а сира відповідь API після
декодування відкидається: `UsageClient.fetch` логувала body і повертала тільки `UsageSnapshot`; body
HTTP-помилок обрізалося до 500 символів (`maxBodyLength`), а body для 429 і decode-помилок не
зберігалося взагалі. Метадані auth-токена (коли прочитаний, коли протухає) ніде не фіксувалися:
`TokenProviding.currentAccessToken` повертав лише `String`, а `expiresAt` з Keychain відкидався
одразу після перевірки validity.

Додаємо прихований діагностичний вхід: у дропдауні статус-айтема пункт **Settings…** видно завжди, а
**Troubleshoot…** — окремий пункт **під ним**, прихований за замовчуванням і показаний лише поки
затиснута **⌥ Option**. Він відкриває велике resizable-вікно з трьома секціями — **Update interval**
(поточна каденція як тривалість + час наступного оновлення + кнопка примусового refresh), метадані
токена (час читання, час протухання) і сира остання відповідь usage API (претіфікований JSON або
payload помилки + HTTP-статус). Вміст **оновлюється наживо** з кожним циклом опитування.

Це породжує рішення того ж класу, що ADR-0009…0011 (де межа модуля, що чисте, що — shell).

## Рішення

1. **Діагностика тече через чистий пайплайн, не через shell-side sink.** Новий тип
   `PollDiagnostics { fetch: FetchDiagnostics, token: TokenDiagnostics? }` формується в ядрі
   (`pollOnce`) і тече `DiagnosedFetch` → `PollResult` → `PollOutput.diagnostics` → `AppDelegate` →
   вікно — тим самим шляхом, що health/snapshot. `PollState` **не чіпаємо**: діагностика описує
   *останню спробу*, а не акумульований стан; кожна ітерація дає рівно один `PollOutput`, і
   `AppDelegate.lastOutput` уже тримає останній.

   `UsageClient.fetch` рефакторено: тіло переїхало в `diagnosedFetch(accessToken:now:transport:) ->
   DiagnosedFetch`, яка в кожній гілці (200 / 429 / інші не-2xx / decode-fail / transport / non-HTTP /
   not-sent) складає `FetchDiagnostics` з **повним** body. `fetch` стала обгорткою
   (`try (await diagnosedFetch(...)).result.get()`) — сигнатура й усі наявні `FetchTests` незмінні.
   Кап 500 символів лишається лише для `UsageError.http` (popup); діагностична копія body — повна, без
   обрізання, і захоплюється також для 429 та decode-помилок (раніше ці body губилися).

   Альтернативу «вікно читає `TokenProvider.credentials()` / останній `UsageError` напряму»
   відкинуто: обхід чистого пайплайна, дублювання Keychain-читань, дані не оновлюються природно з
   полами.

2. **Метадані токена — заміна методу протоколу `TokenProviding`, expiry-рішення переїжджає в engine.**
   `currentAccessToken(now:) throws -> String` → `currentCredentials(now:) throws -> TokenCredentials`
   (`{ accessToken, expiresAt }` + предикат `isExpired(now:)`). Провайдер більше **не кидає
   `.expired`** — рішення про простроченість тепер у `pollOnce` (там, де вже живуть делегований
   refresh і його gate). Виграш:
   - **одне** Keychain-читання на пол (сабпроцес `security`, ADR-0019 — друге читання було б зайвим і
     race-небезпечним);
   - `expiresAt` доступний навіть для **простроченого** токена — найцінніший діагностичний випадок
     («протух о HH:MM і ще не оновився»);
   - контракт ADR-0007 «прострочений токен не йде в мережу» зберігається — тепер його гарантує engine.

   **Безпека:** у `PollOutput`/UI течуть лише дати (`TokenDiagnostics { readAt, expiresAt }`) —
   жодних токен-рядків; `TokenCredentials` свідомо **без** `refreshToken` (секрет не тягнеться в
   engine). `TokenError.expired` лишається в enum (мапінг `FailureReason` незмінний), просто його
   формує engine, а не провайдер. Лог `token expired, len=<count>` (текст незмінний) переїхав із
   `TokenProvider.accessTokenIfValid` у `PollingEngine.pollOnce` разом із перевіркою.

3. **Два окремі пункти; ⌥ показує/ховає Troubleshoot через `isHidden`, кероване modifier-polling
   таймером — не нативним `isAlternate`, не `NSMenuDelegate.menuNeedsUpdate`.** «Settings…» —
   звичайний, завжди видимий пункт із власним селектором `openSettings`; «Troubleshoot…» — окремий
   пункт одразу під ним із власним `openTroubleshoot`, `isHidden = true` за замовчуванням. Поки меню
   відкрите, `optionPollTimer` читає живий стан ⌥ і виставляє `troubleshootItem.isHidden`.

   **Чому не нативний `isAlternate` (перевірено — не з пам'яті):** alternate-механізм `NSMenu`
   (патерн Finder «About This Mac»→«System Information…») **інертний у меню статус-айтема** — пункт
   не перемикається під модифікатором. **Чому не подієвий монітор:** трекінг `NSMenu` крутить модальний
   `NSEventTrackingRunLoopMode`, який голодує `addLocalMonitorForEvents(.flagsChanged)` (перевірено:
   монітор не спрацьовував під час трекінгу). Тому reveal веде таймер, доданий у `.common`-режими (щоб
   спрацьовував під час модального трекінгу), який опитує `NSEvent.modifierFlags` кожні 50 мс —
   `menuWillOpen` сідить його, `menuDidClose` вбиває й ховає пункт назад.

   `keyEquivalent` на всіх пунктах **порожній** — гліфів шорткатів (⌘, / ⌘Q) у дропдауні немає (немає
   й головного меню, яке б їх хостило). Тож зауваження ADR-0012 §7 «дефолтного ⌘Q немає» лишається
   чинним. Попередня редакція цього ADR описувала нативний alternate-swap із ⌘,-гліфом на «Settings…»,
   але реалізація завжди йшла modifier-polling шляхом; цей запис приведено у відповідність до коду.

4. **Вікно — звичайний рівень (`.normal`), не `.floating` — свідоме відхилення від ADR-0012 §6.**
   Floating конфліктує з повноекранним Space, а велике завжди-зверху вікно вороже до користувача.
   `styleMask` включає `.resizable`/`.miniaturizable`, `collectionBehavior = [.fullScreenPrimary]`
   (зелена кнопка → нативний fullscreen у власному Space), `setFrameAutosaveName` пам'ятає
   розмір/позицію. `NSApp.activate(ignoringOtherApps: true)` в `show()` достатньо, щоб підняти вікно
   accessory-застосунку. Патерн ADR-0012 §6 для малого `.floating` Settings-вікна лишається чинним —
   тут інший клас вікна.

   **Формат timestamp** — фіксований, стабільний для баг-репортів: `2026-07-22 14:32:05 (Europe/Kyiv)`
   (`yyyy-MM-dd HH:mm:ss`, локаль `en_US_POSIX`, інжектована `timeZone` з дефолтом `.current`,
   ідентифікатор таймзони в дужках). Свідоме відхилення від локалізованого `ResetClock.absoluteString`
   — діагностика має бути однозначною. Час наступного оновлення — той самий формат із префіксом `≈`
   (wake / відновлення мережі можуть спричинити пол раніше).

5. **Секція «Update interval» + кнопка примусового refresh через новий `PollSignal.manualRefresh`.**
   Поточну каденцію винесено в окрему секцію вікна: рядок `Refresh interval: 3m` (тривалість, чистий
   `TroubleshootLayout.durationText`) над `Next update: ≈ <timestamp>` (той самий фіксований формат).
   Кнопка **«Refresh now»** примусово оновлює **обидва** потоки даних: `AppDelegate.forceRefresh()`
   надсилає новий сигнал `PollSignal.manualRefresh` у `SignalHub` (usage-цикл поллить негайно — як
   `.wake`/`.networkRestored`) **і** скидає `lastStatusSuccess = nil`, тож status-пол, який їде на
   heartbeat usage-полу, знову `isDue` на тому ж негайному тику.

   На відміну від `.wake`/`.networkRestored`, `.manualRefresh` **скидає активний 429-backoff** до
   базового 180 с: у циклі, коли `waitForNextPoll` повернув `.interrupted(.manualRefresh)`, стан
   `state.backoff` скидається (`.reset()`) **перед** негайним полом. Це свідоме рішення — ручна дія
   користувача важить більше за rate-limit-обережність (ADR-0008): він приймає ризик нового 429.
   `LivePollScheduler` проводить будь-який сигнал крім `.sleep` як `.interrupted`, тож нова гілка
   потрібна лише для скидання backoff; `waitWhileAsleep` `.manualRefresh` ігнорує (сплячий Mac не
   поллить). Тестами покрито і скидання backoff (`manualRefreshResetsBackoffToBaseInterval`), і
   формат тривалості (`durationText`).

## Наслідки

- `TokenPaceKit` отримує два нові чисті типи: `FetchDiagnostics`/`TokenDiagnostics`/`PollDiagnostics`/
  `DiagnosedFetch` (діагностичний канал) і `TroubleshootLayout` (view-model, тепер із полем
  `intervalLine` + чистим `durationText`). Обидва без AppKit → реюз у Фазі 2, покриті юніт-тестами
  (`UsageClientTests` — нова suite `diagnosedFetch`; `TroubleshootLayoutTests` —
  `prettyPrinted`/`timestampText`/`durationText`/`make`; `PollingEngineTests` — асерти діагностики,
  збереження контракту «прострочений токен не йде в мережу» і скидання backoff на `.manualRefresh`).
  `PollSignal` отримує case `.manualRefresh` (негайний пол + скидання 429-backoff).
- `TroubleshootWindowController` (`TokenPace`) — тонкий shell за зразком `SettingsWindowController`,
  але `.normal`-рівня; `render(_:)` викликається з `AppDelegate.apply(_:)` **щополу**, тож відкрите
  вікно оновлює всі три секції на місці (body присвоюється лише коли змінився — щоб не злітали
  виділення/скрол). Кнопка «Refresh now» кличе `onForceRefresh` → `AppDelegate.forceRefresh()`.
- **Логування:** додано один рядок `manual refresh requested (Troubleshoot)` (`lifecycle`, `.notice`)
  з `AppDelegate.forceRefresh()`; рядок `token expired, len=<count>` тепер емітиться з
  `PollingEngine.pollOnce`, а не з `TokenProvider` (текст, категорія, рівень незмінні). Див.
  `docs/log-messages.md`.
- ADR-0007 частково зачеплений: «provider throws `.expired`» більше не так — рішення переїхало в
  engine. Це не інвалідує ADR-0007 (контракт «прострочений токен не йде на API» зберігається), тож у
  його індексі закреслення немає; додано постскриптум-вказівник сюди.
- `JSONSerialization` вперше з'являється в кодовій базі — лише для претіфікації діагностичного JSON
  (`prettyPrinted`); основний decode-шлях застосунку й далі на `Codable`.

## Пов'язані

- [ADR-0007](0007-token-provider-throws-and-scope-split.md) — «прострочений токен не йде на API»;
  рішення про expiry переїхало з провайдера в engine (постскриптум там).
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — чистий `UsageClient` і
  transport-seam, який `diagnosedFetch` розширює.
- [ADR-0012](0012-configure-window-and-launch-at-login.md) §6 — floating-патерн Settings-вікна, від
  якого це вікно свідомо відхиляється (звичайний рівень + fullscreen).
- [ADR-0017](0017-delegated-token-refresh.md) — делегований refresh, чий gate тепер живе поряд із
  expiry-рішенням у `pollOnce`.
- [ADR-0019](0019-token-read-via-security-cli.md) — читання токена сабпроцесом `security`; мотивація
  «одне читання на пол».
