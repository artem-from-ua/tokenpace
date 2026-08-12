---
status: accepted
date: 2026-08-02
supersedes: []
superseded_by: [0062, 0081]
---

# ADR-0061: Синя зона пейсингу «far behind» + опція «Work harder»

> **Частково витіснений [ADR-0081](0081-weekly-capacity-gate-for-blue.md).** Behind-поріг знову
> фіксований (множник — константа ×2, опцію прибрано), але з'явилася нова умова: синій показується
> лише поки **тижневе вікно саме має запас** (`BarLayout.blueAllowed` /
> `PacingModel.weeklyHasHeadroom`). Роль `ColorRole.paceBlue` злито в `.blue`.
>
> **Частково витіснений [ADR-0062](0062-configurable-bar-presentation.md) (#224).** Behind-поріг більше
> не **фіксованої** ширини — тепер конфігурований через `FarBehindInterval` (множник ×1/×2/×3 або
> off), дефолт 2h/2d. Bool-опція «Work harder» (розділ 5) замінена триставним `CalmColorMode`
> (`.off` / `.yellowGreen` / `.yellowGreenBlue`). Чинними лишаються: синій severity-case `farBehind`
> (розділ 3), 20-хв start-override (розділ 2), обсяг 5h/7d (розділ 4), роль `ColorRole.paceBlue` і
> поле `BarLayout.windowDurationSeconds`.

## Контекст

Колір пейсинг-зазору на боці «на пейсі / позаду плану» (`usage <= time`, `PacingState.onPaceOrBehind`)
досі був **однорідно зеленим** — жодного внутрішнього порогу. Це віддзеркалення ще не завершене:
бік «попереду плану» вже поділений на жовтий+помаранчовий динамічним порогом `aheadThreshold =
0.16·(1 − timeFraction)` ([ADR-0044](0044-dynamic-pacing-threshold.md)), а бік «позаду» лишався
пласким.

**Проблема.** «Трохи позаду пейсу» і «глибоко позаду з великим запасом» — це різні стани, а
однорідний зелений їх злипає. Коли ти суттєво нижче лінії витрат — маєш реальний запас ліміту, і це
варто показати окремим, найспокійнішим тоном.

## Рішення

**Розбити зелену зону на синю (`farBehind`) + зелену (`calm`) порогом **фіксованої часової ширини**;
синій — лише для базових 5h/7d барів; додати опцію «Work harder».**

### 1. Behind-поріг фіксованої часової ширини

На відміну від динамічного `aheadThreshold`, перехід зелений→синій — це **фіксований проміжок
реального часу**, різний для кожного вікна:

- **5h: 60 хв** → `behindThreshold = 3600/18000 = 0.20`
- **7d: 24 год** → `behindThreshold = 86400/604800 ≈ 0.1429`

```
behindThreshold = LimitWindow.blueBehindWidthSeconds / windowDurationSeconds
```

`surplus = timeFraction − usageFraction`:

- `surplus > behindThreshold` → **синій** (`.farBehind`);
- інакше → **зелений** (`.calm`).

Порівняння строге (`>`): запас рівно на порозі — зелений (гучніший із двох спокійних тонів).

**Чому фіксована ширина, а не динамічний мірор ahead.** «Позаду більше ніж на годину (5h) / на добу
(7d)» — це стабільний, зрозумілий запас, що не залежить від того, скільки вікна вже минуло. Динамічний
поріг (як на ahead-боці) робив би межу синього рухомою, що для «є куди розганятися» менш читабельно.
Ширина зберігається як абсолютні секунди на `LimitWindow.blueBehindWidthSeconds` і ділиться на
`windowDurationSeconds` (яке несе `BarLayout`) у `PacingModel.behindThreshold(windowDurationSeconds:)`.

### 2. 20-хвилинний blue **start**-override

У **перші 20 хв** вікна (`elapsed-since-start ≤ 1200 с`) бік «на пейсі/позаду» — **завжди зелений**,
незалежно від порогу. На самому старті майже будь-який usage читається як великий запас, тож синій
блимав би одразу. Це симетричний двійник orange-override з ADR-0044 (той стереже **кінець** вікна):
`elapsed = windowDurationSeconds − remainingSeconds`, тож на відміну від orange-override, який
працює лише з `remainingSeconds`, цей потребує **довжини вікна**. Константа —
`PacingModel.pacingBlueStartOverrideSeconds` (1200 с).

### 3. `farBehind` — окремий severity-case, **спокійніший** за зелений

`PacingSeverity` тепер чотиритактний: `farBehind` (синій) → `calm` (зелений/жовтий) → `ahead`
(помаранчевий) → `exhausted` (червоний). Порядок спокою — від найспокійнішого до найгучнішого.

Критично: `farBehind` — **підвид спокою**, не гучності. Він не повинен вмикати reset-countdown чи
інакше поводитись як «noisy». Тому:

- `BarLayout.isCalm` (і `BarView.isCalm`) = `severity == .calm || severity == .farBehind` — обидва
  «не варті прапорця»;
- **але** `MenuBarLayout.selectReset` тестує «noisy» **явно** як `severity == .ahead || severity ==
  .exhausted` (замість колишнього `!= .calm`). Без цієї правки додавання `farBehind` до `isCalm`
  зробило б глибоко-позаду вікно «noisy» і почало б форсити countdown — регресія. Явний тест лишає
  поведінку countdown **ідентичною** тій, що була до появи `farBehind`.

### 4. Обсяг — лише базові 5h/7d

Синій показується **тільки** для базових 5-годинного та 7-денного барів. **Не** для
моделеспецифічних (per-model / per-service) рядків і **не** для extra-usage (credits) — вони лишаються
зеленими, як були. Розрізнення по поверхнях:

- **Menu bar** уже несе лише 5h/7d (per-model там немає, credits — окрема `creditsIconColor`), тож
  `calmedGapColor` пускає синю логіку без гейта, а `creditsIconColor` не чіпається.
- **Popup** ділить один `PopupBarView` між базою, per-model і credits, тож додано прапорець
  `PopupBarView.isBaseLimit` — `true` лише для рядків 0/1 (`PopupLayout.rows` завжди починає з 5h,
  7d), `false` для per-model; credits йдуть сирим `addBar(bar:…)` і прапорця не отримують.

### 5. Опція «Work harder» (не-calm синій)

Нова appearance-опція (друга в секції *Menu Bar Widget*, одразу після «Calm non-critical colors»).
Коли увімкнена, синя (`farBehind`) зона трактується як **не-calm**: вона **не** мутиться в білий під
Calm colors, тобто синій завжди лишається кольоровим (нагадування «є куди розганятися»). Решта
calm-станів (зелений/жовтий) мутяться як раніше. Ефект видно лише коли Calm colors увімкнено.

- Дефолт — **вимкнено** (opt-in), ключ `PersistedConfig.workHarderColors`
  (`object(forKey:) as? Bool ?? false`).
- У пресетах (#215): **Chill — вимкнено**, **Control freak — увімкнено**.

### Колір і плюмбінг

- Новий `ColorRole.paceBlue` (дефолт `.systemBlue`) — окрема семантична роль, щоб не перевантажувати
  наявний `.blue` (idle-бар / maintenance-крапка).
- `BarLayout` отримує нове збережене поле `windowDurationSeconds: Int`, заповнюване в
  `PacingModel.barLayout(...)` з `window.durationSeconds`. Kit-`severity` і AppKit-`behindColor`
  читають те саме поле, тож колір і severity не розходяться.
- Формула — одна: `PacingModel.behindThreshold(...)`, спільна для `BarLayout.severity` (Kit) та
  `PopupBarView.behindColor(_ l: BarLayout)` (AppKit). `behindColor` приймає цілий `BarLayout` (несе
  `windowDurationSeconds`), тож start-override рахується однаково в обох шарах.

## Наслідки

- **Новий найспокійніший тон.** Глибоко-позаду тепер читається синім на базових барах обох поверхонь.
- **`hide-calm-7d` тепер ховає й синій.** Оскільки `farBehind ⊂ isCalm`, глибоко-позаду 7-денний бар
  ховається під тим самим opt-out, що й зелений. Це навмисно: синій спокійніший за зелений, тож якщо
  зелений ховається — синій тим паче.
- **Reset-countdown без змін.** `selectReset` рахує «noisy» через `.ahead`/`.exhausted`, тож
  `farBehind` ніколи не форсить countdown — поведінка ідентична дореформеній.
- **Порядок severity-рунгів на ahead-боці незмінний.** Змінена лише гілка `.onPaceOrBehind`: спершу
  20-хв start-override → зелений, потім behind-поріг → синій/зелений.
- **Credits та per-model поза обсягом.** Синій до них не застосовується; їхня поведінка (зокрема
  мутинг credits-іконки) незмінна.
- **ADR-0044 лишається чинним** для ahead-боку — цей запис лише додає behind-бік (з власним,
  фіксованим порогом) і не
  скасовує жодної його клаузи.
