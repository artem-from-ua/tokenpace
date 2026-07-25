---
status: accepted
date: 2026-07-25
---

# ADR-0036: Сигнали авто-апдейту — один пункт дропдауна, без нотифікацій; авто-install default-ON

> Доповнює [ADR-0025](0025-check-for-updates.md) (перевірка) і [ADR-0033](0033-automatic-update-install.md)
> (авто-встановлення). **Заміщає банерну частину ADR-0025** (`UpdateNotifier` видалено) і **міняє
> дефолт** опції `installUpdatesAutomatically` (0033) з OFF на ON.

## Контекст

Після реалізації епіка #125 (авто-встановлення, #127/#128/#129) фіча технічно працює, але сигнальний
UX лишився **шумним**: три канали одночасно — системний банер macOS (`UpdateNotifier`), синя крапка в
пункті меню «New version available», і рядок «Update available: vX.Y.Z — Download» у Settings. Банер
переривав, крапка й окремий пункт множили сигнали про одне й те саме.

Мета #130 — **щонайменше переривати й шуміти**. Це **тимчасове** рішення до App Store (там оновлення —
турбота стору), тож без переінженерингу (без in-app рендеру release-notes, без окремого UI).

Постають рішення:

1. Скільки каналів лишити й де.
2. Як показувати різні контексти (є новіша / авто OFF / відкладено / вже оновились) одним пунктом.
3. Який дефолт авто-встановлення, коли банер прибрано.

## Рішення

### 1. Жодних системних нотифікацій

`UpdateNotifier` (клас + `UserNotifications`-authorization + delegate) **видалено повністю**. Це
повертає проєкт до духу SPEC.md («macOS-сповіщень немає»). Банерна частина ADR-0025 — superseded.

### 2. Один update-пункт у дропдауні — чиста машина станів

Усі некритичні сигнали зведено в **один** пункт popup-меню (над `Quit`, за власним сепаратором).
Клік **завжди** відкриває `GitHubReleaseClient.releasesPageURL` (без in-app markdown). Змінюється лише
**колір крапки** й **текст** — за пріоритетною таблицею:

| Пріор. | Умова | Крапка | Текст |
|---|---|---|---|
| прихований | нема новішої версії І нема непереглянутого what's new | — | (відсутній) |
| 1 | новіша версія + авто-install зафейлив цей tag | 🔴 | `New version available (update failed)…` |
| 2 | новіша версія + авто **OFF** | 🔵 | `New version available…` |
| 3 | новіша версія + авто **ON** + відкладено (battery/metered/disk) | 🔵 | `Update pending…` |
| 4 | встановлена = найновіша, успішний апдейт ще не переглянуто | 🔵 | `What's new in the version…` |

**Витіснення:** будь-яка версія, новіша за встановлену (1–3), витісняє «what's new» (4) — тобто (4)
лише коли встановлена = найновіша. Кейс «не клікнув what's new, а вже вийшла новіша» → показуємо
тільки `New version available`.

Під час активного download/verify (авто ON, новіша, не відкладено, не зафейлено) пункт **прихований** —
оновлення відбувається тихо, і пункт знову з'являється як `whatsNew` після рестарту (або `updateFailed`).

**Розкол pure/shell (ADR-0009):** вибір winner-стану — чистий `UpdateMenuState.evaluate(...)` у kit
(unit-тестований), що повертає семантичний `Item`-enum. **Колір і текст — у view** (`AppDelegate`),
як `ServiceStatus.word`/`dotColor`: kit каже *що* означає пункт, view — *як* він читається. Колір
береться з наявного `PopupViewController.dotColor` — тож update-крапка має **ті самі** кольори, що
крапки статусів сервісів (🔴 = `.majorOutage`, 🔵 = `.underMaintenance`).

### 3. Авто-install — default-ON (opt-out)

Коли банер прибрано, **найменш нав'язливий канал — тихий фоновий апдейт із рестартом**. Тож
`installUpdatesAutomatically` став **default-ON** (ідіома `object(forKey:) as? Bool ?? true`, як
`automaticUpdateChecks`). Повний флоу все одно вимагає реального `.app` у `/Applications` — у dev
чекбокс лишається disabled+hint (0033). Це змінює дефолт 0033, але не механізм install.

Персистенція (нове в `PersistedConfig`):

- `pendingWhatsNewVersion: String?` — виставляється **перед рестартом** у `startInstall` (успішний
  install закінчується relaunch+terminate *усередині* `install()`, тож маркер має бути на диску до
  того, як стартує новий білд і покаже стан 4). Скидається: (a) по кліку по пункту, (b) коли є новіша
  за встановлену версія (витіснення).
- `lastFailedInstallVersion: String?` — виставляється при фейлі install; гейтить retry **саме цього**
  tag (стан 1, червоний). Новішу версію пробувати далі (машина станів матчить лише поточний latest).

### 4. Вирівнювання крапок

Update-крапка в меню **і** крапки статусів сервісів у popup підняті по оптичному центру тексту
(cap-height), а не по baseline — спільним хелпером `PopupViewController.dotAttachment(...)` через
`NSTextAttachment.bounds`. Раніше символ-attachment сідав низько; тепер обидва вирівняні однаково, як
крапка menu-bar-віджета.

## Наслідки

- **Один канал у меню** замість трьох сигналів; жодних банерів. Settings-рядок «Update available —
  Download» лишається як окремий канал у вікні налаштувань (не «шум» на екрані).
- **Тестова межа (ADR-0009):** `UpdateMenuState` (усі 4 пріоритети + витіснення + гейт retry) покрито
  unit-тестами; рендер пункту / вирівнювання — вручну на живому білді.
- **Верифікаційний стуб** `TOKENPACE_UPDATE_STATE=failed|available|pending|whatsnew` форсує стан пункту
  без реального релізу/фейлу (пише лише в пам'ять, не в UserDefaults) — до сімейства
  `TOKENPACE_STUB`/`TOKENPACE_FAKE_LATEST`. Занесено в `CLAUDE.md`.
- **Обмеження:** повний авто-install (стан 4 після рестарту, стан 1 після фейлу) працює лише на
  нотаризованому `.app` із `/Applications`; на `swift run` — no-op, стани перевіряються стубом.

## Пов'язані

- [ADR-0025](0025-check-for-updates.md) — перевірка оновлень; **банерна частина superseded** цим ADR
  (`UpdateNotifier` видалено); fetch-шлях / `SemanticVersion` / cadence лишаються.
- [ADR-0033](0033-automatic-update-install.md) — механізм авто-встановлення; цей ADR **міняє його
  дефолт** (OFF → ON) і додає сигнальні маркери (`pendingWhatsNewVersion`/`lastFailedInstallVersion`).
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — чисте ядро / тонкий shell, за яким
  розділено `UpdateMenuState` (kit) і рендер пункту (view).
- [ADR-0024](0024-configurable-logical-services.md) — `ServiceStatus`/`dotColor`, палітру яких
  переюзовує update-крапка.
