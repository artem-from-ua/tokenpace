---
status: accepted
date: 2026-06-22
superseded_by: [0091]
---

# ADR-0010: UsageHealth — стани помилок (⚠️ menu bar + банер popup + stale)

> **Частково витіснено [ADR-0091](0091-countdown-only-where-work-is-not-running.md).** Три фази
> помилки стали двома: середню («⚠️ поряд зі старими смужками», 30–60 хв) скасовано разом із
> `hideBarsAfter`, а поріг гліфа тепер рахується у спробах — `UsageHealth.glyphAfter(for:)` =
> `max(15 хв, 3 × pollInterval)` замість пласких 30 хв; 429 більше не пише `failingSince`.
> Чинними лишаються `FailureReason`, «попап попереджає одразу, без порогу» і сама двовхідна модель
> (`UsageSnapshot` + `UsageHealth`).

## Контекст

Issue #12 («Стани помилок») робить помилки видимими користувачу. Досі будь-яка невдача
(`TokenError` / `UsageError`) лише **логувалась** через `AppLogger` — у menu bar і popup нічого не
змінювалось. SPEC («Стан помилок / відсутньої авторизації») і подальші уточнення вимагають:

- у menu bar — іконка ⚠️, коли опитування довго не працює;
- у popup — пояснення помилки **одразу** (без очікування), із збереженням останніх відомих даних
  (stale) і міткою застарілості;
- без macOS-сповіщень.

Обсяг свідомо обмежено **чистою моделлю + UI-рендером + unit-тестами**: живий polling-цикл, що
породжує реальні помилки, приходить у #13 (`App.swift` поки на mock). Точки розширення були
зарезервовані заздалегідь — `MenuBarMode` (ADR-0009 п.3) і `PopupLayout`.

Постають рішення про межі модуля — той самий клас, що в ADR-0005/0007/0008/0009:

1. **Як подати «стан опитування» (успіх/невдача/коли почалось) у чисті моделі**, не змішуючи його зі
   `UsageSnapshot` (даними) і не вносячи таймер у чисту логіку.
2. **Як виразити пороги тривалості невдач** так, щоб вони були детерміновані й тестовані без годинника.
3. **Як розрізнити stale (показуємо старі дані) від error (показуємо ⚠️)** в menu bar.
4. **Як подати причину помилки до view** без витоку діагностичних деталей (`OSStatus`, HTTP-код, тіло).
5. **Як намалювати ⚠️** в non-template, `isFlipped` menu-bar образі.

## Рішення

1. **Окремий чистий value-тип `UsageHealth` (у `CCTimerKit`) як другий вхід layout-фабрик.**
   `lastSuccess: Date?` / `failingSince: Date?` / `reason: FailureReason?`. Layout-фабрики
   отримують перевантаження `make(from: UsageSnapshot?, health:, now:)` поряд із наявними
   healthy-фабриками (які лишаються незмінними й переюзуються тестами #10/#11 і циклом #13). Health —
   **окремо** від `UsageSnapshot`: снапшот описує *дані*, health — *стан їх отримання*. Це дзеркалить
   ін'єкцію `now` всюди (ADR-0009): `UsageHealth` не має власного годинника.

2. **Пороги — чисті функції від `failureAge(now:) = now − failingSince`, фіксовані, строгі межі.**
   Три фази menu bar (уточнено з користувачем, ширше за єдиний 30-хв крок SPEC):
   - `age ≤ 30 хв` і є snapshot → **stale-смужки** (як `.expanded`), без ⚠️ — дані ще свіжі;
   - `30 хв < age ≤ 60 хв` → **⚠️ + останні смужки** + час ресету (динамічна ширина);
   - `age > 60 хв`, **або cold-start** (snapshot немає) → **тільки ⚠️** — дані надто застарілі / їх нема.

   Константи `glyphAfter = 30*60`, `hideBarsAfter = 60*60`. Межі **строгі** (`>`), як
   `idleUtilizationThreshold` (ADR-0009) і `PacingModel`'s `> 90`: рівно 30:00 — ще смужки, рівно
   60:00 — ще зі смужками. Покрито boundary-тестами.

3. **Stale рендериться наявними `.idle`/`.expanded`; для помилки — один новий `MenuBarMode.error`
   з опційними смужками.** `case error(fiveHour: BarView?, sevenDay: BarView?, reset:, which:)` —
   усі значення `nil` разом (тільки ⚠️) або всі не-`nil` (⚠️ + смужки). Menu bar **не** розрізняє
   stale vs fresh (старі смужки виглядають так само); застарілість видно лише в popup (службовий
   рядок). Окремого `.stale`-case немає — це була б зайва гілка.

4. **Причина мапиться в семантичний `FailureReason` (у `CCTimerKit`); рядок збирає view.**
   `TokenError`/`UsageError` несуть деталі не для користувача (`OSStatus`, HTTP-код); `FailureReason`
   (`notSignedIn` / `authHTTP(status:body:)` / `timeout` / `cannotResolveHost` / `network` /
   `serverProblem` / `unknown`) — семантичний сигнал, як `PacingState`/`TimeToReset`. `init(_:)` —
   exhaustive `switch` **без `default`** (новий case помилки ламає компіляцію → свідомий мапінг).
   Локалізований текст (`warningTitle`/`warningDetail`) живе у `PopupViewController` (seam, ADR-0009).
   `http(401/403)` → `.authHTTP`, інші коди → `.serverProblem`. Popup показує **два рядки**: жирний
   title (для HTTP — `Auth error (HTTP <код>)`) і detail (для HTTP — тіло відповіді сервера).

5. **`UsageError` розширено, щоб донести текст до popup.** `http(status:)` → **`http(status:body:)`**
   (тіло відповіді, `.public`-safe — це *відповідь*, не запит, тож токена не несе; обрізане до
   `maxBodyLength`). `transport(String)` → **`transport(message:code:)`** з `URLError.Code?`, щоб
   розрізнити timeout / DNS / інше **детерміновано** (а не парсингом рядка `localizedDescription`,
   який залежить від локалі). `URLError.Code` — `Sendable`/`Equatable`, тож `UsageError` лишається
   обома.

6. **⚠️ — monochrome SF Symbol `exclamationmark.triangle` кольору шрифта (`labelColor`), не emoji,
   не fill.** Кольору шрифта (як idle-гліф `*`), щоб збігатися з текстом menu bar і трекати тему
   (резолвиться через наявну `snapshotImage(appearance:)` + KVO інфраструктуру ADR-0009 п.9).
   Контурний (`.triangle`, не `.triangle.fill`) — знак оклику читається навіть як суцільна заливка.
   Малюється з `respectFlipped: true`: view `isFlipped`, тож звичайний `draw(in:)` віддзеркалив би
   образ вертикально (трикутник виходив перевернутим/«кривим»). Центрується по `rect.midY` —
   спільний вертикальний центр зі смужковим блоком.

7. **Popup: банер помилки одразу після назви, блоки розділені горизонтальними рисками.**
   `PopupLayout` отримує `warning: FailureReason?` (default `nil` у memberwise init — зворотна
   сумісність із тестами/викликами #11), виставляється **за будь-якої** невдачі (`isFailing`), без
   30-хв порогу — popup попереджає одразу (SPEC). Порядок у `PopupViewController`: назва → риска →
   *(за помилки)* двозначний банер → риска → службові рядки (Last update / interval) → риска →
   секції лімітів. Навколо кожної риски — симетричний відступ (`separatorPadding`). `lastUpdateAge`
   рахується від `health.lastSuccess` (застарілість видима); `rows` — зі stale-snapshot (порожні на
   cold-start, банер стоїть сам).

8. **Без `UserNotifications`.** Свідоме рішення SPEC: увесь сигнал — у menu bar + popup. #12 не
   додає системних сповіщень.

## Наслідки

- Уся логіка станів помилок покрита unit-тестами без AppKit: `UsageHealthTests` (мапінг **кожного**
  case `TokenError`/`UsageError`, граничні HTTP-коди, body у `.authHTTP`, `failureAge`, пороги),
  доповнені `MenuBarLayoutTests` (трифазні межі 30:00 / 60:00, cold-start) і `PopupLayoutTests`
  (warning одразу, stale rows, `lastUpdateAge`). Малювання ⚠️/банера перевірено оком (`swift run`
  з demo-перемикачем `App.demoMode`).
- `CCTimerKit` лишається без AppKit: `UsageHealth`/`FailureReason` несуть лише семантику; мапа в
  кольори/символи — у `cc-timer`. Реюз у Фазі 2 збережено.
- `UsageError` тепер несе більше контексту (`body`, `URLError.Code`) — наявні тести #9 оновлено.
  Розширення свідоме: ці поля потрібні для точного user-facing тексту.
- Прив'язку до **живих** помилок робить #13: цикл будує `UsageHealth` з реальних результатів
  опитування (успіх → `healthy`, невдача → `failingSince`/`reason`) і передає в ті самі фабрики —
  моделі/view #12 лишаються незмінними.
- `MenuBarMode`/`PopupLayout` тепер закривають усі стани Фази 1; подальші зміни рендера (Фаза 2,
  SwiftUI) переюзовують чисті моделі, замінюючи лише shell.

## Пов'язані

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — розкол pure/shell, appearance,
  `MenuBarMode` лишено відкритим під цей `.error`.
- [ADR-0008](0008-usageclient-pure-backoff-and-transport-seam.md) — `UsageError`, розширений тут.
- [ADR-0007](0007-token-provider-throws-and-scope-split.md) — `TokenError`, мапиться в `FailureReason`.
