---
status: accepted
date: 2026-07-27
---

# ADR-0041: Грейс на reset-boundary — придушити хибний 5h-idle одразу після ресету

> Доповнює [ADR-0027](0027-session-idle-no-phantom-reset.md) (чесний детект idle) і
> [ADR-0030](0030-optimistic-reset-and-exact-timer.md) (оптимістичний ресет). Детект idle
> лишається чинним — цей ADR лише додає короткий часовий гейт поверх нього.

## Контекст

За [ADR-0027](0027-session-idle-no-phantom-reset.md) 5-годинне вікно **створюється першою витратою
токенів**: до неї сервер віддає `five_hour` без `resets_at`, і декодер чесно виставляє
`sessionIdle: true`. Це коректно для справжньої паузи, але має хибний бік на **межі ресету**.

Спостережено вживу (логи `process == "TokenPace"`, реальні дані):

```
17:38:43  five_hour: utilization 71, resets_at 2026-07-27T15:40:00Z        ← активне вікно
17:40:00  optimistic reset applied, forcing refresh                        ← настав ресет (ADR-0030)
17:40:00  five_hour: {utilization:0, resets_at:null}  → sessionIdle=true    ← бар блимнув у idle
          "five_hour idle — no active session (resets_at absent)"
17:43:12  five_hour: {utilization:14, resets_at:20:40} → active again       ← idle зник сам
```

Одразу після ресету старе вікно знищено, а нове ще не створене (жодної витрати токенів у першу
хвилину-дві). Сервер ~3 хв (≈ один полінг) віддає `five_hour` без `resets_at`, тож декодер —
за дизайном — рапортує idle. Menu bar і попап на ці ~3 хв показують «waiting for limit reset» /
порожній 5h-бар, хоча щойно до ресету вікно було активне. Це виглядає як збій, а не як стан «немає
сесії».

Ключове: детект idle **stateless** — `UsageSnapshot.window(...)` бачить лише поточне тіло плюс
інжектований `now`. Він не пам'ятає, що попередній полінг мав активне вікно, тому не може відрізнити
reset-blip від справжньої паузи.

## Рішення

Додати короткий **грейс** (гістерезис): не перемикати в idle одразу після **активного** вікна;
тримати «готовий» бар певний час і показати справжній idle лише якщо вікно так і не з'явилось.

- **D1. Місце гейта — `PollingEngine.advance` (`.success`), не декодер.** Це єдиний seam, де в scope
  є і `previous.lastSnapshot` (доресетне вікно), і новий snapshot — та сама точка, де
  `sessionIdleTransition` (ADR-0027, D6) порівнює обидва. Декодер лишається stateless.
- **D2. Чистий helper `applyIdleGrace(decoded:previous:activeUntil:now:)`.** Повертає
  `(snapshotДляРендеру, новийДедлайн)`:
  - `decoded` не idle → `(decoded, nil)`: стійкий стан, будь-який активний грейс знято;
  - `decoded` idle, грейс озброєний, `now < deadline` → `(suppress(decoded), deadline)`: тримаємо;
  - `decoded` idle, `now ≥ deadline` → `(decoded, nil)`: вікно не повернулось, показуємо **справжній**
    idle;
  - `decoded` idle, грейсу ще не було, попереднє вікно **активне** (не idle, present `resets_at`) →
    `(suppress(decoded), now + idleGraceWindow)`: озброїти грейс (це reset-blip);
  - `decoded` idle, грейсу не було, попереднє absent/idle → `(decoded, nil)`: справжній idle із
    cold-start чи усталеної паузи **не** придушується.
- **D3. Придушення на рівні snapshot.** `suppress(_:)` перебудовує snapshot із `sessionIdle: false`,
  решта полів як є. Оскільки всі три рендер-гілки читають `snapshot.sessionIdle` (menu bar, попап,
  фарбування), один фікс лікує всі. Придушене вікно вже має `utilization: 0, resets_at: ""` →
  рендериться як звичайний calm-«готовий» бар 0 %; порожній `resets_at` парситься в `nil`, тож
  каунтдаун падає на 7-денний ресет — жодного фантомного `resetNow`/`<1m`.
- **D4. Тривалість — `idleGraceWindow = 300 с` (5 хв), час-дедлайн, не лічильник полів.** Полінг на
  межі нерівномірний (оптимістичний ресет форсує негайний `manualRefresh`, далі base 3 хв), тож час
  надійніший за «N полів». 5 хв покриває 1–2 base-полінги із запасом; максимальна затримка правдивого
  idle — 5 хв.
- **D5. Критерій «reset-boundary vs справжній idle» — простий «previous активне → current idle».**
  Прив'язку до конкретного часу `previous.resets_at` свідомо відкинуто як зайву складність: активне
  вікно, що раптом стало idle, майже за визначенням щойно пройшло свій ресет. Справжній idle зазвичай
  приходить, коли попередній полінг **уже** idle → гейт не озброюється.
- **D6. Лог — раз на перехід.** `"five_hour idle suppressed — within reset grace"`
  (`AppLogger.network.notice`), лише коли `idleSuppressedUntil` переходить `nil → non-nil` — та сама
  «only on change» дисципліна, що `intervalDecision` / `sessionIdleTransition`.

## Взаємодія з оптимістичним ресетом (ADR-0030)

Це два **незалежні** шари, не дублюють один одного:

- `fireOptimisticReset` працює на **shell**-рівні (пише лише в `AppDelegate.lastOutput`), накладає
  overlay зі старим вікном (`util 0` + synth `now+5h`) і рендерить одразу на момент `t0` (спрацювання
  таймера). Engine-стан (`PollState`) він **не** чіпає.
- Хибний idle-блимок приходить наступним **реальним** полінгом через `advance` (момент `t1`, мережа).
  Там `previous.lastSnapshot` = доресетне активне вікно (overlay engine не бачить) → гейт озброюється
  і придушує blip.

Тобто overlay латає `t0` (таймер), грейс латає `t1` (полінг). `ResetClock.optimisticReset` (його
idle-спецкейс) не змінено.

## Чому лог і `sessionIdleTransition` не конфліктують

Оскільки в `next.lastSnapshot` кладеться **придушений** snapshot (`sessionIdle=false`),
`sessionIdleTransition` (ADR-0027, D6) під час грейсу не бачить active→idle → хибної трійки
active→idle→active не буде. Коли грейс вичерпається і покажемо справжній idle, transition чесно
залогує один active→idle. Змін у `sessionIdleTransition` не потрібно.

## Наслідки

- Одразу після ресету 5h menu bar/попап більше не блимають у idle: до 5 хв тримається звичайний
  «готовий» бар 0 % із 7-денним каунтдауном.
- Справжній idle (cold-start, усталена пауза > 5 год) не зачеплено — він приходить, коли попередній
  полінг уже idle, тож гейт не озброюється; максимальна затримка правдивого idle після активного
  вікна — 5 хв.
- Уся логіка гейта — чиста функція (`applyIdleGrace`), покрита unit-тестами; shell лише пробрасує
  попередній стан через нове поле `PollState.idleSuppressedUntil`.

Див. також: [ADR-0027](0027-session-idle-no-phantom-reset.md) (детект idle),
[ADR-0030](0030-optimistic-reset-and-exact-timer.md) (оптимістичний ресет),
[ADR-0032](0032-simplified-polling-cadence.md) (каденс полінгу).
