---
status: superseded
superseded_by: [0086]
date: 2026-07-25
---

# ADR-0034: Ховати спокійну 7d-смужку в menu bar (опція, default-on)

> **Замінено [ADR-0086](0086-tri-state-calm-bar-hiding.md).** Булева опція стала трипозиційною
> («Hide the calm bar»: `5-hour` / `7-day` / `Never`), тож ховати можна **будь-яку** з двох смужок, а
> не лише 7-денну; фабричний дефолт відтоді ховає **5-годинну**. Описане нижче лишається чинним як
> опис режиму `.sevenDay` і як контекст рішення.

> Продовжує лінійку «менше шуму» в menu-bar віджеті — ту саму, що [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md)
> / [ADR-0029](0029-reset-countdown-selection-by-severity.md) (ховання reset-часу) і
> [#105](https://github.com/artem-from-ua/tokenpace/issues/105) (calm-кольори). Реюзує той самий
> предикат `BarView.isCalm`.

## Контекст

Menu-bar віджет завжди малює **дві** стековані смужки: 5h зверху, 7d знизу
(`MenuBarMode.expanded(fiveHour:sevenDay:…)`). Коли 7-денне вікно спокійне (в межах темпу —
зелене on-pace/behind або трохи-попереду жовте), нижня смужка не несе корисного сигналу: на крихітній
іконці дві смужки конкурують за увагу, хоча цікава лише 5h. Тема «прибрати шум з menu bar»
проходить наскрізно через де-ноїз-сесію ([#94](https://github.com/artem-from-ua/tokenpace/issues/94)).

`#94` пропонував ширший механізм — «показувати лише найважливіший бар» (динамічний автовибір
домінантного вікна: 5h **або** 7d). Ми свідомо взяли **вужчий** варіант: ховати **саме 7d**, коли
вона спокійна, лишаючи 5h як завжди-присутню опорну смужку. 5h — вікно, що пече найчастіше (5-годинний
цикл), тож тримати його стабільно на місці, а 7d показувати лише коли вона реально шумить (orange/red),
дає «менше шуму» без когнітивного стрибка «яка з двох смужок зараз перед очима».

## Рішення

### Що і коли ховаємо

- Нова опція `PersistedConfig.hideCalmSevenDayBar`, **default-on** (opt-out, як `showServiceStatusDot`):
  `object(forKey:) as? Bool ?? true`.
- Коли увімкнено і 7d-бар `isCalm` (`severity == .calm` — green/mild-yellow, той самий предикат, що
  живить ADR-0028/0029 і #105) → 7d-смужка **ховається повністю**, 5h стає єдиною, **вертикально
  центрованою** смужкою.
- **Orange (`.ahead`) / red (`.exhausted`) 7d завжди показується** — це і є шум, на який варто
  дивитися.

### Де живе логіка: Kit, не view

`MenuBarMode.expanded.sevenDay` стає **опційним** (`BarView?`); рішення «ховати чи ні» приймає
`MenuBarLayout.make(...hideCalmSevenDay:)` — чиста, тестована функція. View (`StatusItemView`)
лишається тонким shell'ом: бачить `sevenDay == nil` → малює одну смужку центровано на `rect.midY`.

Мотивація — узгодженість із ADR-0009/0028/0029: усі рішення «**що** показувати в menu bar за
severity» вже живуть у Kit як pure-логіка (`selectReset` вирішує показати/сховати reset-label через
`ResetToShow?`). Ховання смужки — рішення того самого класу, і воно тестується як `#expect(seven == nil)`
без AppKit і рендер-геометрії. Альтернатива (прапорець читає view напряму з `PersistedConfig`) розколола
б одне сімейство рішень на два шари і зробила б логіку нетестованою (`PersistedConfig` — `@MainActor`
UserDefaults-shell). Доставка прапорця копіює `showServiceStatusDot`: `App.render` читає
`PersistedConfig.hideCalmSevenDayBar` щоразу й передає в `make`.

### Незалежність від вибору reset-часу

`selectReset` бачить **справжні** severity обох вікон незалежно від ховання смужки, тож reset-countdown
не змінюється: спокійна 7d, яку сховали, і так ніколи не керувала countdown (за таблицею ADR-0029 lone
calm-7d не показує час). Ховаємо лише **смужку**, не рішення про час.

### Межові випадки

- **Session-idle** (#100, ADR-0027): спокійна 7d ховається так само → лишається сама idle-5h,
  центрована. Шумна 7d в idle — показується, 5h-idle над нею.
- **Error-стан** (#12, ⚠️ + stale-смужки, 30–60 хв): ховання **не діє** — 7d там діагностична, тож
  завжди показується (error-гілка кличе `make` з `hideCalmSevenDay: false`).
- **Ширина item не змінюється** — та сама `barWidth`; ховання 7d змінює лише вертикальний layout.

## Наслідки

- **+** Тихіший віджет out-of-the-box: одна смужка, коли тиждень на темпі; 7d повертається сама,
  щойно стане orange/red — нуль втрати сигналу.
- **+** Pure-тестована логіка (`MenuBarLayout hide calm 7d (#94)` suite, 8 кейсів), View лишається
  тонким.
- **−** `expanded.sevenDay: BarView?` торкнувся кількох pattern-match `.expanded` (view + тести) —
  разова ціна. Error-кейс уже мав `BarView?`, тож типи зійшлися.
- Хто хоче обидві смужки завжди — знімає чекбокс «Hide 7-day bar when calm» (Settings → Menu bar
  widget). Стуб `TOKENPACE_STUB=calm-both` демонструє лону центровану зелену 5h.

## Пов'язане

- [ADR-0028](0028-hide-reset-label-when-pacing-is-calm.md), [ADR-0029](0029-reset-countdown-selection-by-severity.md)
  — та сама де-ноїз-лінійка, той самий `isCalm`.
- [ADR-0015](0015-no-idle-mode.md) — «смужки не колапсують у гліф» лишається чинним: тут
  колапсує лише **одна** (спокійна 7d), 5h завжди на місці; це не idle-гліф.
- [ADR-0027](0027-session-idle-no-phantom-reset.md) — session-idle interplay.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — pure/shell розкол (рішення в Kit, малювання в view).
