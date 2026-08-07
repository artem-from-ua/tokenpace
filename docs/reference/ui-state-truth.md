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
5. **Іконки — справжні SF Symbols**, відрендерені з системи. Не емодзі, не Unicode-замінники,
   не SVG з бібліотеки — див. нижче.

## Метрики

### Меню-бар — `StatusItemView.Metrics`

| Константа | Значення |
|---|---|
| `barWidth` | 34 |
| `barHeight` | 5 |
| `hPadding` | 2 |
| `labelGap` | 5 |
| `awaitingIconSize` + gap | 12 + 6 |
| `awaitingSlideTravel` | 22 (= `height`) |
| `pauseGlyphSize` + gap | 11 + 3 |
| `creditsIconSize` + gap | 12 + 4 |
| `statusDotDiameter` + gap | 6 + 4 |

Шрифт лейбла — `NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)`.

**Слот awaiting-долоні резервується з опції, а не з даних** ([#283](https://github.com/artem-from-ua/cc-timer/issues/283),
[ADR-0073](../adr/0073-awaiting-icon-reserved-slot-and-slide.md)): `awaitingIconSize + gap` входить у
ширину віджета, поки ввімкнена Appearance-опція, **незалежно від того, чи хтось чекає вводу зараз**.
Малюючи меню-бар у мокапі, не прибирай це місце разом з іконкою — інакше сусідні елементи стануть не
там, де їх покаже застосунок. Сам гліф їде по Y на `awaitingSlideTravel` (з обрізанням по слоту), тож
проміжний кадр — це **обрізана** долоня біля нижньої межі, а не зменшена або напівпрозора.

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

## Іконки — тільки справжні SF Symbols

**Емодзі, Unicode-замінники (`⚡`, `✋`, `❚❚`) і намальовані вручну гліфи в мокапах
заборонені.** Вони мають іншу ширину, іншу оптичну вагу й іншу форму, ніж те, що намалює
застосунок — тобто мокап показує неіснуючий інтерфейс, і всі висновки про компонування з
нього хибні.

Рендерити треба з системи, тими самими параметрами, що й у коді:

```swift
// mock-symbols.swift — запустити `swift mock-symbols.swift`
import AppKit

func png(_ name: String, _ colour: NSColor,
         pt: CGFloat = 11, scale: CGFloat = 4) -> String? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }          // ← nil = символу НЕМАЄ
    let w = base.size.width * scale, h = base.size.height * scale
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let r = NSRect(x: 0, y: 0, width: w, height: h)
    base.draw(in: r)
    colour.set()
    r.fill(using: .sourceAtop)                                     // тонування
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
        .map { "data:image/png;base64," + $0.base64EncodedString() }
}
```

Далі результат вставляється в HTML як `<img src="data:image/png;base64,…">` з розміром у
пунктах (`width: 12px; height: 15px` для 12×15 pt) — CSP артефактів блокує зовнішні
хости, тож інший шлях і не працює.

### Що це дає, крім точності

- **`nil` означає, що символу не існує.** Так знайшлося, що `hare.slash` і
  `hare.fill.slash` відсутні в SF Symbols — і саме тому в Deadline mode обрано `bolt`,
  який має системну перекреслену пару.
- **Реальна ширина.** `hare` — 20 pt, `bolt` — 12 pt. На поверхні, де бюджет міряють
  пунктами, різниця у 8 pt вирішує вибір.
- **Тонування як у коді.** `contentTintColor` у застосунку = `fill(using: .sourceAtop)`
  тут, тож колір гліфа в мокапі той самий, що на екрані.

### Параметри, що мають збігатися з кодом

| Параметр | Звідки брати |
|---|---|
| `pointSize` | `Metrics.awaitingIconSize` (12), `pauseGlyphSize` (11), `creditsIconSize` (12), `Metrics.textSize` у попапі |
| `weight` | `.semibold` — так конфігуруються всі наявні гліфи обох поверхонь |
| колір | роль із `ColorStore`, не довільний відтінок |
| `scale` | 4× для retina; розмір в HTML лишається в пунктах |

## Анатомія бару

### Що малює `.pacing` (Pace & Time)

1. Сірий трек на всю ширину, радіус 2
2. **Кольорова капсула над проміжком `gapStart..gapEnd`** — не заливка від нуля
3. Тік-лінійка під баром (лише при `subdivisions >= 2`)
4. Маркер часу на `timeFraction`

`gapStart = min(usage, time)`, `gapEnd = max(usage, time)`.

### Що малює `.simple`

Стрічка від **лівого краю** довжиною `gapEnd − gapStart`, без маркера.

### Нульова стрічка — це пігулка, а не порожнеча

У стилях без маркера на меню-барі (`.simple`, `.mixed`) стрічка — **єдина** мітка бару, тож
навіть при довжині рівно 0 вона малюється як пігулка мінімальної ширини (`minStripWidth`,
3.75 pt на меню-барі) — `PopupBarView.pillRect`. Порожній трек означав би «даних немає»,
а не «нуль».

Стан `usage == time == 0` — не артефакт округлення, а регулярний кадр: після кожного ресету
5-годинного вікна `PollingEngine.applyIdleGrace`/`suppress` ([ADR-0041](../adr/0041-idle-grace-on-reset-boundary.md),
[ADR-0045](../adr/0045-honest-reset-boundary-grace.md)) тримають «ready»-кадр із `0 %` і
`resets_at = now + 5h`, доки не зайде перша трата. У Pace & Time цього floor'а **немає**:
там порожній gap означає «точно за темпом», і позицію вже показує маркер.

### Що малює idle-бар

Суцільний трек на всю ширину: блакитний (`ready to start`) або сірий (`blocked`).
**Без зон, без маркера**, тік-лінійка є.

### Маркер часу видає стиль — не забувай його

**Бар без маркера — це `.simple`, а не Pace & Time.** Найчастіша помилка в мокапах:
підписати рендер «Pace & Time», намалювавши лише кольорову смугу. Маркер — не
декоративна деталь, а те, що відрізняє один стиль від іншого.

Перед публікацією мокапа з барами:

- маркер на `timeFraction` є в **кожному** барі `.pacing` — і в меню-барі теж (5 × 9 pt, а
  не лише 7 × 14 попапа). У `.mixed` маркер має **тільки попап**: на меню-барі цей стиль
  малює стрічку без маркера ([ADR-0062](../adr/0062-configurable-bar-presentation.md) —
  «маркер лише там, де є місце»), тож `BarStyle.menuBarShowsTimeMarker == (self == .pacing)`;
- маркер стоїть на **своїй** частці, не на краю смуги: при `usage > time` він **зліва**
  від gap, при `usage < time` — **справа**. Обидва бари з маркером ліворуч означають, що
  геометрія скопійована, а не порахована;
- усі x проходять через інсет `scaleX`, включно з маркером.

Швидка перевірка: якщо на малюнку два бари й обидва маркери з одного боку — майже напевно
помилка.

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
| Вичерпаний ліміт **без жодного** з них | Зворотний бік того самого: при `mainWindowExhausted` стани вичерпні — або `creditsCanCover` (символ валюти), або `isBlocked` (pause-гліф). Порожнього варіанту не буває |
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

## Кожне посилання — гіперпосилання

Стосується всіх артефактів і документів, не лише тих, що містять рендери. **Голий
`#283` у тексті — це робота, перекладена на читача**: щоб перейти, він має скопіювати
номер, згадати репозиторій і зібрати URL руками.

Гіперпосиланнями мають бути:

| Що згадується | Куди веде |
|---|---|
| Тікет чи PR — `#283` | `https://github.com/artem-from-ua/tokenpace/issues/283` (GitHub редіректить `/issues/` на `/pull/` за потреби) |
| Коміт — `5ee4820` | `…/commit/5ee4820` |
| Файл у репозиторії | `…/blob/main/Sources/TokenPace/StatusItemView.swift` |
| Рядок коду | той самий URL + `#L936` |
| Документ проєкту | відносний шлях, якщо артефакт лежить у репо; повний URL — якщо ні |
| ADR | `…/blob/main/docs/adr/0044-dynamic-pacing-threshold.md` |
| Інший артефакт | його `claude.ai/code/artifact/…` URL |

### Перевірка перед публікацією

Голі згадки легко пропустити — особливо ті, що стоять одразу після тега (`<div>#283`),
бо вони не потрапляють у наївний пошук «пробіл + решітка».

```python
import re
s = open("artifact.html").read()
body = s.split("</style>", 1)[1]                     # CSS-кольори не рахуємо
parts = re.split(r"(<a\b[^>]*>.*?</a>)", body, flags=re.S)
bare = [m.group() for i, p in enumerate(parts) if i % 2 == 0
        for m in re.finditer(r"#\d{2,4}(?![\da-fA-F])", p)]
print(bare or "усі згадки клікабельні")
```

І звірити, що номер у `href` збігається з видимим текстом — заміна регексом легко
розсинхронізує їх, і посилання поведе не туди, мовчки.
