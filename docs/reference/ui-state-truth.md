# Джерело істини для рендерів UI

Довідник для будь-якого зображення інтерфейсу поза застосунком: артефакти, мокапи,
документація, коментарі в issue. **Кожна цифра тут узята з коду; кожен стан перевірений на
досяжність.**

> Правило, з якого це виросло: рендер, намальований із пам'яті або з чужого мокапа,
> ілюструє неіснуючий продукт. Розбір, побудований на такому рендері, хибний навіть коли
> текст правильний.

## Перед тим, як щось малювати

1. **Знайди формтер**, який друкує цей текст, і процитуй його — не переказуй.
2. **Прогони стан через модель** — колір і статус обчислюються, а не обираються.
3. **Звір метрики** з `Metrics` відповідного view.
4. **Перевір досяжність стану** — див. «Неможливі комбінації» нижче.

## Метрики

### Меню-бар — `StatusItemView.Metrics`

| Константа | Значення |
|---|---|
| `barWidth` | 34 |
| `barHeight` | 5 |
| `hPadding` | 2 |
| `labelGap` | 5 |
| `awaitingIconSize` + gap | 12 + 6 |
| `pauseGlyphSize` + gap | 11 + 3 |
| `creditsIconSize` + gap | 12 + 4 |
| `statusDotDiameter` + gap | 6 + 4 |

Шрифт лейбла — `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)`.

### Попап — `PopupBarView.Metrics`

| Константа | Значення |
|---|---|
| `barHeight` | 6 |
| `corner` | 2 |
| `indicatorWidth` × `indicatorHeight` | 7 × 14 |
| `indicatorCorner` | 2 |
| обводка маркера | 1 pt, `monochromeGrey` змішаний 40% із кольором маркера |
| `tickLength` / `tickGap` / `tickWidth` | 5 / 2 / 2 |
| `minStripWidth` | `0.75 × barHeight` = 4.5 |

**Інсет `scaleX`:** усі частки мапляться як `inset + f × (width − 2·inset)`, де
`inset = minStripWidth/2`. Частка 1.0 **не** дає правий край.

Текст: `NSFont.systemFont(ofSize: dropdownTextSize)` — **жирності немає в жодній половині
жодного рядка**.

## Анатомія бару

### Що малює `.pacing` (Pace & Time)

1. Сірий трек на всю ширину, радіус 2
2. **Кольорова капсула над проміжком `gapStart..gapEnd`** — не заливка від нуля
3. Тік-лінійка під баром (лише при `subdivisions >= 2`)
4. Маркер часу на `timeFraction`

`gapStart = min(usage, time)`, `gapEnd = max(usage, time)`.

### Що малює `.simple`

Стрічка від **лівого краю** довжиною `gapEnd − gapStart`, без маркера.

### Що малює idle-бар

Суцільний трек на всю ширину: блакитний (`ready to start`) або сірий (`blocked`).
**Без зон, без маркера**, тік-лінійка є.

### Чого не малює ніхто

**Заливки від нуля до `usageFraction`.** Рівень не малюється в жодному стилі — це свідоме
рішення ([ADR-0062](../adr/0062-configurable-bar-presentation.md)). Якщо на малюнку смуга
починається з лівого краю й закінчується на «скільки спожито» — малюнок неправильний.

Виняток: кредитний рядок при `.simple`, де стрічка теж лівоприв'язана — але її довжина це
gap, а не рівень.

## Колір обчислюється, не обирається

```swift
// PacingModel.severity
if pacing == .onPaceOrBehind {                    // usage <= time
    if elapsed <= 1200 { return .calm }           // 20-хв старт-override
    return (time - usage) > behindThreshold ? .farBehind : .calm
}
if usageFraction >= 1 { return .exhausted }       // ЧЕРВОНИЙ
if remainingSeconds <= 1200 { return .ahead }     // 20-хв кінець-override
return (usage - time) < 0.16 * (1 - time) ? .calm : .ahead
```

**Порядок гілок критичний.** Обидва 20-хвилинні override'и лежать **після** виходу зі
спокійної гілки — тож при `usage <= time` вони недосяжні. Стан «97% спожито, 97% часу, 9
хвилин до ресету» лишається **зеленим**.

Швидка перевірка перед малюванням:

| Умова | Колір |
|---|---|
| `usage >= 1` | червоний |
| `usage > time`, `usage − time >= 0.16 × (1 − time)` | помаранчевий |
| `usage > time`, менше порога | жовтий |
| `usage <= time`, відставання ≤ порога | зелений |
| `usage <= time`, відставання > порога | синій (лише базові 5h/7d) |

## Тексти — цитуй формтер

| Що | Де | Правило |
|---|---|---|
| Статус ліміту | `PopupViewController.statusText` | — |
| Статус кредитів | `creditsStatusText:1914` | `usage >= 1` → завжди `"limit reached"`, ніколи не «ahead» |
| Суми кредитів | `creditsAmountText:1922` | `"€10.77 / €15.00"` — **обидві суми, без відсотка** |
| Без capу | `creditsSpentOnlyText` | `"€10.77 spent"` — без бару й вердикту |
| Рядок ресету, попап | `ResetClock.resetLine` | `"15d"` · `"5d on Friday"` · `"20h at 03:00"` |
| Лейбл ресету, меню-бар | `ResetClock.timeToReset` | > 90 хв → `"20:40"`; ≤ 90 хв → `"45m"`, `"1h30m"` |

## Ієрархія чорнила в попапі

| Лінія | Вміст | Роль |
|---|---|---|
| Верхня | назва ліміту **і статусне слово** | `.label` — повний |
| Нижня | відсоток **і** рядок ресету | `.dimmedLabel` |

`dimmedLabel` = `tertiaryLabelColor.blended(0.5, of: .secondaryLabelColor)` — слабший за
вторинний.

Поділ іде по **лініях**, не по осі «назва ↔ значення»: вердикт стоїть у повному чорнилі
разом із назвою, і це навмисно — він найдієвіший елемент рядка.

## Неможливі комбінації

Перевіряй перед тим, як малювати стан.

| Комбінація | Чому неможлива |
|---|---|
| Pause-гліф **і** символ валюти разом | `blockedPause` вимагає `CreditsPacing.isBlocked` — «немає шляху працювати»; кредити, що покривають ліміт, і є тим шляхом |
| 100% кредитів + «well ahead of pace» | `creditsStatusText` при `usage >= 1` повертає `"limit reached"` |
| 100% кредитів без червоного бейджа ресету | Це стан блокування — бейдж є |
| Idle 5-hour + другий рядок | `if !row.sessionIdle` — детальної лінії немає |
| Idle-бар + маркер часу | Idle малюється knobless |
| `usage > time` + зелений/синій | Це гілка `.ahead` — жовтий або помаранчевий |
| `usage <= time` + помаранчевий через «20 хв» | Override недосяжний зі спокійної гілки |
| Спокійне 7d вікно, що вичерпається до ресету | `rate = usage/time <= 1` ⟹ проєкція ≤ 1 |
| Повний кредитний бар поруч з idle 5-hour | Кредити витрачаються лише коли токенний ліміт вичерпано — тоді 5h не idle |
| Жирний текст у рядку ліміту | Обидві половини — `NSFont.systemFont`, «neither half is bold» |

## Як перевірити стан арифметично

Швидкий скрипт замість здогаду:

```python
def severity(u, t):
    if u >= 1: return "RED"
    if t >= u: return "green/blue"
    return "yellow" if (u - t) < 0.16 * (1 - t) else "ORANGE"

print(severity(0.78, 0.72))   # ORANGE — не зелений
print(severity(0.88, 0.93))   # green/blue
```

Для ширин — виміряти тим самим шрифтом:

```swift
let f = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
(s as NSString).size(withAttributes: [.font: f]).width
```
