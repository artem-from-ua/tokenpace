# Як читати меню-бар

Довідник **із боку читача**: що означає те, що зараз на екрані. Дві сусідні сторінки розвʼязують
обернені задачі — [ui-state-truth.md](ui-state-truth.md) каже, як стан **малювати**, а
[bar-status-conditions.md](bar-status-conditions.md) — за яких даних смужка набуває якого кольору.

Англомовний варіант кроків 1–2 нижче призначений для README та довідки в застосунку.

## Дві незалежні осі

Читаються окремо від усього іншого й присутні в **будь-якому** режимі:

- **Крапка праворуч** — стан сервісів Claude (#31). Кольорова = є проблема на боці Anthropic.
  Малюється навіть тоді, коли віджет більше нічого не показує: у режимі «опитування вимкнено» вона
  єдиний живий сигнал.
- **Долоня ліворуч** — сесія Claude Code чекає на відповідь (#233). Найчастіша декорація: за
  [ADR-0073](../adr/0073-awaiting-icon-reserved-slot-and-slide.md) її слот зарезервований постійно,
  щоб віджет не смикався десятки разів на день.

Далі — сам віджет.

## Крок 1. Чи є число?

Відлік зʼявляється **лише** тоді, коли робота не йде на підписці
([ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md)). Якщо число є, гліф поруч
називає причину:

| На екрані | Стан | Число означає |
|---|---|---|
| ⏸ + число | робота **стала** | коли відновиться |
| ¤ + число | робота йде, але **за гроші** | коли перестане коштувати |
| ⚠️ сам | дані **суперечать собі** — вікно вичерпане, а його `resets_at` зламаний | нічого; часу ми не знаємо |
| перекреслена антена | **не дістаємось API** довше за поріг | нічого; даних немає |
| `zzz` | опитування **вимкнене користувачем** (#341) | нічого; це вибір, не збій |

Смужок у жодному з цих станів немає: вікно на 100 % не несе інформації про темп, і єдине, що варте
уваги — коли це скінчиться.

**Чому ⚠️ без гліфа.** Пауза стверджувала б «ти заблокований» поруч зі знаком, який відмовляється
від даних. На екрані ніщо не каже, що недовіра стосується лише часу, тож пара читалася б як
поламаний віджет. Суперечливі дані отримують один сигнал.

## Крок 2. Числа немає → читай смужки

Робота йде на підписці. Смужки показують **темп**, а не залишок квоти.

| Що видно | Що означає |
|---|---|
| **одна смужка** | 5-годинне вікно спокійне й відступило — лишилось тижневе |
| **дві смужки** | 5-годинне вікно попереду темпу, тому лишається на екрані. Верхня — 5h, нижня — 7d |
| **помаранчева** | це вікно йде попереду темпу. Нічого не заблоковано — це **прогноз** |
| зелена, жовта | темп у нормі |
| синя | ідеш помітно **позаду** темпу — можна прискоритись |

Дві застороги:

- **«Одна смужка = 5h спокійне» справджується при дефолтному `CalmBarHiding = .fiveHour`.** Хто
  обрав `Never`, завжди бачить обидві.
- **Idle — інша причина одної смужки.** Коли активної сесії немає, 5-годинного вікна не існує
  взагалі ([ADR-0027](../adr/0027-session-idle-no-phantom-reset.md)), і його смужка малюється як нуль
  ([ADR-0078](../adr/0078-idle-drawn-as-zero-in-both-styles.md)). Той самий піксель, інша історія.

## Інваріант

**Смужка ніколи не несе відліку, а відлік ніколи не несе смужок.** Разом вони не зʼявляються ніде —
і це властивість типу: `MenuBarMode.expanded` не має поля для числа, тож така пара
нерепрезентовна.

Практичний наслідок: якщо бачиш число, дивись на гліф, а не на смужки — їх там немає.

## Чого меню-бар не каже

- **Абсолютного відсотка.** Ані «88 %», ані «12 % лишилось» — ніде, у жодному стилі. Це свідомо:
  сам по собі рівень не проходить перевірку «яку дію користувач виконає інакше»
  ([users-and-goals.md](users-and-goals.md)). Відсотки є в попапі.
- **Чи вистачить квоти на конкретну задачу.** Віджет не знає, що ти збираєшся робити. Він знає, чи
  твій **поточний темп** веде до вичерпання — це й каже колір.
- **Часу до ресету в робочому стані.** За ним — один клік у попап: рядок ресету є на кожному ліміті
  й не ховається ніколи.

## Англійською — для README та довідки

> **Reading the menu bar**
>
> **Step 1. Is there a number?**
>
> A countdown appears only when work is not running on the subscription. If you see one, look at the
> glyph beside it:
>
> - **Pause + number** — work has stopped. The number is when it resumes.
> - **Currency + number** — work continues, but you are paying for it. The number is when it stops
>   costing money.
> - **⚠️ alone** — a limit is spent but the server did not say when it resets.
> - **Slashed antenna** — the app cannot reach the API.
> - **`zzz`** — usage polling is switched off. Nothing is wrong.
>
> There are no bars in any of these states: a window at 100 % carries no pacing information, and the
> one thing worth knowing is when it ends.
>
> **Step 2. No number? Read the bars.**
>
> You are working on the subscription. The bars show pace, not remaining quota.
>
> - **One bar** — the 5-hour window is calm and steps aside; what you see is the weekly one.
> - **Two bars** — the 5-hour window is ahead of pace, so it stays on screen. The top bar is the
>   5-hour one, the bottom is the weekly.
> - **Orange** — that window is running ahead of its pace. Nothing is blocked; it is a forecast.
> - **Blue** — you are well behind pace and could speed up.
> - **Green, yellow** — nothing to act on.
>
> A bar never carries a countdown, and a countdown never carries bars.

## Повʼязані документи

- [bar-styles.md](bar-styles.md) — три стилі смужки (Pressure / Gauge / Progress): що кожен каже,
  як його читати й кому підходить
- [ui-state-truth.md](ui-state-truth.md) — як малювати стан (метрики, анатомія, неможливі комбінації)
- [bar-status-conditions.md](bar-status-conditions.md) — за яких даних смужка набуває якого кольору
- [users-and-goals.md](users-and-goals.md) — критерій «корисного сигналу»
- [ADR-0091](../adr/0091-countdown-only-where-work-is-not-running.md) — рішення, що відлік живе лише
  в безсмужкових станах
- [ADR-0090](../adr/0090-menu-bar-answers-can-we-work.md) — «чи можемо ми працювати» як єдине питання
