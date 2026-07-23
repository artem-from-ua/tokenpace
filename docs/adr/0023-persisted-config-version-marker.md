---
status: accepted
date: 2026-07-23
---

# ADR-0023: Версійний маркер конфігу + межа тестованого в persistence-шарі

## Контекст

Issue #71 закладає **перший шар персистентності** в проєкті: до нього
`grep -r UserDefaults Sources` порожній — жодного `UserDefaults`, `@AppStorage` чи запису
налаштувань на диск. Єдине, що «запам'ятовувалося» між запусками, — це системний стан
(`SMAppService` login-item через `LaunchAtLoginController`) та frame Troubleshoot-вікна
(`setFrameAutosaveName`), а не конфіг застосунку.

Потреба: тримати в збереженому конфігу **версію, якою параметри були востаннє записані**
(`lastRunVersion`), щоб новіший білд міг порівняти «остання збережена версія» ↔ «поточна» і за
потреби виконати міграцію ключів або cleanup системного стану (напр. прибрати застарілі login-items
від старої назви `cc-timer`) **до** того, як конфіг почне використовуватися.

Постає той самий клас рішень про межу модуля, що в
[ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md),
[ADR-0010](0010-usage-health-and-error-states.md),
[ADR-0011](0011-polling-engine-adaptive-cadence-and-signal-seams.md): де живе side-effecting частина
(`UserDefaults`), а де — чиста тестована логіка, і як не зчепити їх.

Обсяг цього тікета навмисно вузький: **лише версійний маркер + каркас міграції**. Реальних
міграцій немає, ширший typed config store — поза обсягом (окремий майбутній тікет). Ключове рішення,
яке треба зафіксувати, — де провести межу тестованого, щоб перший persistence не приніс у проєкт
непокриту логіку.

## Рішення

1. **Чиста частина — предикат рішення про міграцію — живе в `TokenPaceKit` (`MigrationPlan`) і
   покрита тестами.** Framework-free `enum` без `Foundation`-I/O: `transition(stored:current:)`
   класифікує старт у `firstRun` / `unchanged` / `upgraded(from:to:)`, а `needsMigration(_:)`
   вирішує, чи є що виконувати. Це той самий поділ, що `LaunchAtLogin` (чисті предикати) vs
   `LaunchAtLoginController` (SMAppService-glue): семантика й рішення — у kit, реюзовні у Фазі 2 й
   тестовні без живого сховища.

2. **Side-effecting частина — обгортка `UserDefaults` — живе в `TokenPace` shell
   (`PersistedConfig`) і верифікується вручну.** `UserDefaults.standard` — системний синглтон, який
   не інжектується й не мокається чисто (як `SMAppService`), тож код, що його читає/пише, лишається
   в executable-таргеті й перевіряється manual-verify за конвенцією
   ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) §«Наслідки»). Обгортка мінімальна:
   один ключ `lastRunVersion` (String) з `get`/`set`. Це шов, який майбутній тікет розширює іншими
   ключами (напр. конфіг monitored services, #89), а не універсальний store наперед.

3. **`lastRunVersion == nil` трактується як `firstRun` — свіжа установка або доверсійний білд.**
   Відсутній ключ означає, що параметри ще жодного разу не писалися під версійним маркером: або це
   перший запуск після впровадження цього тікета, або апгрейд із білда, що персистентності не мав.
   В обох випадках міграцій немає — просто записуємо поточну версію. Persistence-флаг «перший
   запуск» окремо **не** вводимо: `nil`-маркера достатньо, і він не заважає майбутнім post-update
   міграціям (на відміну від «зробити раз назавжди»-прапорця).

4. **Хук міграції — найперша дія `applicationDidFinishLaunching`, до створення UI й полінгу.**
   `AppDelegate.runConfigMigrationsIfNeeded()` читає `lastRunVersion`, класифікує через
   `MigrationPlan.transition`, логує вихід (`AppLogger.lifecycle`, три стани) і **записує поточну
   версію назад**. Розміщення першим гарантує, що майбутня міграція встигне підчистити стан, від
   якого залежить решта старту, перш ніж той його прочитає. Структурно дзеркалить
   `registerLaunchAtLoginIfNeeded()` — той самий клас lifecycle-хелперів.

5. **Порівняння версій — наразі рядкова нерівність (`stored != current`), не SemVer-впорядкування.**
   Для каркаса без реальних міграцій цього достатньо: `.upgraded` спрацьовує на будь-яку відмінність
   і несе обидва кінці (`from`/`to`), тож майбутня міграція зможе прив'язатися до точного кроку.
   Повноцінний SemVer-compare («мігрувати лише якщо `old < X.Y.Z`») відкладено до першої реальної
   міграції, яка його потребуватиме. «Даунґрейд» (старіший запущений білд, ніж той, що писав конфіг)
   свідомо лишається просто `.upgraded` — не спецкейс.

## Наслідки

- `TokenPaceKit` лишається без залежностей: `MigrationPlan` оперує лише семантикою; платформенний
  бік (`UserDefaults`) — у `TokenPace`. Предикат покритий unit-тестами (`MigrationPlanTests`);
  обгортка й хук — manual-verify.
- Каркас без реальних міграцій означає, що `needsMigration` наразі ніде не гейтить справжню роботу —
  гілка `.upgraded` лише логує. Це навмисно: точка розширення готова, кроки додасть тікет, який
  їх потребуватиме (перша реальна міграція / cleanup, напр. старі `cc-timer` login-items — #69).
- **Логування** (`AppLogger.lifecycle`, `.notice`): «config: first run, no prior version (X)» /
  «config: version unchanged (X)» / «config: version X → Y, running migrations». Версія — `.public`
  (безпечний діагностичний рядок, не секрет). Записи додано в `docs/log-messages.md`.
- **Перевірити (manual):**
  - Перший запуск після оновлення (порожній `lastRunVersion`) → лог «first run, no prior version»;
    `defaults read com.artem-n.tokenpace lastRunVersion` показує поточну версію.
  - Другий запуск тієї самої версії → лог «version unchanged».
  - Запуск білда з іншою версією (або підміненим `lastRunVersion`) → лог «version X → Y, running
    migrations».

## Пов'язані

- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — чиста-core / тонкий-shell поділ і
  manual-verify для side-effecting glue; persistence-шар слідує тому ж поділу.
- [ADR-0010](0010-usage-health-and-error-states.md) — `UsageHealth` як зразок чистого value-типу зі
  станами; `MigrationPlan.Transition` — його аналог для migration-домену.
- Issues: #71 (цей тікет), #69 (приклад системного стану, який майбутня міграція могла б чистити —
  застарілі login-items), #89 (перший споживач, що розширить `PersistedConfig` конфіг-ключем).
