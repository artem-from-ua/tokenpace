---
status: accepted
date: 2026-07-31
---

# ADR-0051: Оранжевий «pause» гліф перед барами у стані повного блокування

## Контекст

Коли роботу **повністю зупинено** — кожне головне вікно (5h/7d) вичерпане **й** платні extra-usage
кредити не покривають (`CreditsPacing.isBlocked`), — користувач не має шляху працювати аж до ресету.
Якщо він при цьому лишив pacing-бари видимими (опція «Show pacing bars when 5h/7d limits reached», #194,
тепер default-**off**), бари показують червоні 100 %, але нічого не сигналізують про сам факт «сервіс
зупинено». Потрібен явний візуальний маркер повної зупинки.

Рішення — малювати **оранжевий SF-символ `pause.fill` як провідний (leading) елемент** віджета, за
окремою опцією «Show pause icon when fully blocked» (#199, default-**on**). Гліф **не залежить** від
тумблера барів: він з'являється і ліворуч від барів (`.expanded`), і ліворуч від countdown-тексту у
безбарному режимі (`.blockedReset`, #194) — щойно настала повна зупинка.

Два питання цього ADR: (1) **за яким предикатом** показувати гліф, і (2) **як** пробросити його через
модель.

## Рішення

### Предикат — `CreditsPacing.isBlocked`, не `mainWindowExhausted`

Гліф означає «працювати неможливо», тож тригер — `CreditsPacing.isBlocked(in:)`
(`mainWindowExhausted && !creditsCanCover`), а **не** ширший `mainWindowExhausted`, який використовує
#194 (ADR-0049) для ховання барів. Різниця істотна: коли 7d на 100 %, але кредити ще покривають, робота
триває на платному тарифі — це **не** повна зупинка, тож pause не показуємо. Це та сама межа, що й
червоний «Effective blocker» бейдж у попапі та edge «Back to work!» (`WorkAvailability.canWork` —
інверсія `isBlocked`), тож усі сигнали узгоджені.

### Модель — прапорець `blockedPause: Bool` на `MenuBarLayout`, обчислений на health-обізнаному шві

Замість того щоб view-шар (тонкий, без бізнес-логіки — ADR-0009) перевисновував `isBlocked`, прапорець
`blockedPause` обчислюється в `MenuBarLayout` — на тому ж health-обізнаному `make(...)` шві, що й `credits`
та `serviceProblem`, **після** визначення `mode`:

```
blockedPause = showBlockedPause (гейт) && CreditsPacing.isBlocked(snapshot)
             && mode ∈ {.expanded, .blockedReset}   // тобто НЕ .error
```

Гліф незалежний від тумблера барів (`hideBarsWhenBlocked`): виставляється і для `.expanded` (бари є), і
для `.blockedReset` (countdown-only). Виключено лише `.error` — стале/cold-start не є сигналом «повна
зупинка». Пробрасується через `with(serviceProblem:credits:blockedPause:)`, як інші декорації. Плоский
`make(from:now:...)` не чіпаємо.

### Малювання — leading-гліф як `drawErrorGlyph`, колір як `drawCreditsIcon`

І `drawExpanded`, і `drawBlockedReset` малюють гліф на `rect.minX + hPadding` (вертикально по центру),
отримують правий край і зсувають `originX` барів / countdown-тексту праворуч — та сама схема, що вже є для
⚠️ у `drawError`. Ширина резервується симетрично в `itemWidth` (гілки `.expanded` **і** `.blockedReset`)
через один `pauseInset`, тож draw і width читають один прапорець і не розходяться. Fallback: якщо
`pause.fill` недоступний — контент малюється на звичайному origin без гліфа (`guard … else { return originX }`),
ширина трохи над-резервується, ніколи не обрізає.

### Колір — окрема роль `ColorRole.menuPauseOrange`

Конвенція проєкту (ADR-0046): кожен menu-колір має власну роль у DevColorTuner. Перевикористання
`menuStatusOrange` (оранжевий service-dot) зв'язало б два незалежні сигнали в одному повзунку тюнера, тож
додаємо окрему роль `menuPauseOrange` (стартове значення 240/140/40, як status-orange, далі тюниться
незалежно).

## Наслідки

- Повна зупинка сервісу читається з одного погляду в **обох** режимах барів — і коли бари видимі, і в
  countdown-only. За default `showBlockedPause`=on гліф з'являється щойно `isBlocked`.
- Гліф і #194 композуються чисто, але **незалежні**: `isBlocked` (pause) — вужчий за `mainWindowExhausted`
  (hide-bars), тож при вичерпаному ліміті з покриттям кредитами бари ховаються (#194), але pause **не**
  показується (робота триває на платному тарифі — то не зупинка).
- Ще один menu-колір у тюнері (`menuPauseOrange`).
- Опція `showBlockedPause` — default-on (opt-out), гейт `PersistedConfig.showBlockedPause`, тумблер у
  Settings → Appearance (другим у списку). Тільки menu bar; попап не зачеплено.
