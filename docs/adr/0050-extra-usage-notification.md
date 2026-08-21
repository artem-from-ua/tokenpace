---
status: accepted
date: 2026-07-31
---

# ADR-0050: Нотифікація «Now using Extra Usage Credit» — фронт not-spending→spending, спільна інфраструктура з ADR-0039

> ⚠️ **Рішення цього ADR чинне повністю** — предикат `isOnCredits`, окремий ключ
> `extraUsageWasOnCredits`, спільна авторизація й quiet-hours, тіло з сумою+лімітом, кнопка «Try».
> Застаріла лише секція **«Співіснування з "Back to work!"»** нижче: вона описує сигнал сусідньої
> нотифікації, який [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md) замінив
> (`canWork` → `subscriptionAvailable`). Актуальне співіснування — у постскриптумі до тієї секції.

## Контекст

Коли базовий ліміт Claude Code вичерпано, а користувач увімкнув Extra Usage Credit, робота **тихо**
переливається на платний кредит — реальні гроші витрачаються без жодного сигналу. TokenPace має сам
надіслати системний банер рівно в момент цього переключення, з **поточною сумою витраченого** та
**лімітом** (якщо заданий) у тілі.

Це дзеркалить нотифікацію «Back to work!» ([ADR-0039](0039-back-to-work-notification.md)): той самий
патерн «фронт стану між полами + persisted edge-state + quiet-hours + opt-in + `.app`-only авторизація»,
але **інший** перехід. Ключове питання — який саме сигнал і як він співіснує з `WorkAvailability`.

## Рішення

### Фронт `not-on-credits → on-credits`, а не «баланс перетнув поріг»

Чистий предикат `ExtraUsageOnset.isOnCredits(_ snapshot:)` (`TokenPaceKit`):

```
isOnCredits = spend != nil
           && mainWindowExhausted(snapshot)
           && isSpending(spend, baseLimitExhausted: true)   // enabled && !spend_limit_reached
```

Реюз наявних предикатів `CreditsPacing.isSpending` + `CreditsPacing.mainWindowExhausted` — не винаходимо
нову перевірку. Свідомо взято **`mainWindowExhausted`** (лише 5h/7d, що реально гейтять роботу), а не
`anyBaseLimitExhausted` (яка рахує per-model під-вікна для показу **іконки**): per-model cap сам по собі
не переливається на кредити (#177), тож брати ширшу вичерпаність означало б хибний onset.

### Співіснування з «Back to work!»

Два фронти **не** колізують: `WorkAvailability.canWork` спрацьовує на `blocked → workable`, а
`isOnCredits` — на `not-spending → spending-on-credits` (стан, який уже «workable», бо `isSpending`
входить у `canWork`). Це різні переходи різних станів — один банер описує «ліміт ресетнувся», інший —
«почав платити». На стелі (`spend_limit_reached`) `isSpending` = false → це домен «Back to work»
(блокування), не цей.

> **Постскриптум (#161, [ADR-0113](0113-back-to-work-tracks-the-subscription-quota.md)).** Абзац вище
> описує сигнал, якого більше немає: «Back to work!» стежить за `subscriptionAvailable`
> (`!mainWindowExhausted`), а не за `canWork`. Що змінилося по суті:
>
> - **Аргумент «різні стани» вже не потрібен, бо стани більше не перетинаються за побудовою.** Раніше
>   неколізію доводили тим, що `isOnCredits` живе всередині «workable»; тепер сигнали просто читають
>   різні речі — один підписку, інший кредити.
> - **Обидва банери можуть стосуватися одного проміжку — і це нормально.** 5h/7d на 100 % із
>   активними кредитами: `isOnCredits` дає «почав платити» на вході, `subscriptionAvailable` дає
>   «квота повернулася» на виході. Вони описують початок і кінець того самого епізоду, а не
>   дублюють одне одного.
> - **Останнє речення абзацу хибне.** Стеля кредитів (`spend_limit_reached`) більше **не** належить
>   домену «Back to work»: ні вона, ні наступний ресет кредитів не рухають `subscriptionAvailable`.
>
> Окремий edge-state (`extraUsageWasOnCredits` проти `backToWorkWasBlocked`) лишається правильним
> рішенням — тепер із ще очевиднішої причини.

### Спільна інфраструктура, окремий edge-state

- **Авторизація** `UNUserNotificationCenter` — **один** дозвіл `[.alert, .sound]` на обидві нотифікації;
  запитується лениво при першому вмиканні **будь-якої** з них (спільний `onBackToWorkEnabled` callback).
- **Quiet-hours** — той самий `NotificationSchedule.isAllowed` (вікно годин + suppress-дні), винесений у
  спільний `AppDelegate.notificationsAllowedNow()`. Рядки Settings «Allowed hours» / «Suppress on
  weekends» винесено в **окрему секцію «Schedule»**, яка **завжди видима й активна** (навіть коли обидві
  нотифікації вимкнені) — розклад можна налаштувати наперед; він гейтить обидві нотифікації однаково.
- **Постинг** — узагальнений `BackToWorkNotifier.post(kind:idPrefix:title:body:)`; `postBackToWork()` і
  новий `postExtraUsage(body:)` — тонкі обгортки. Тіло extra-usage несе суму+ліміт, тож постинг
  приймає динамічний `body` (на відміну від фіксованого back-to-work).
- **Кнопка «Try»** (як у back-to-work, #193) — біля перемикача, **завжди активна** (навіть коли фіча
  вимкнена): форсує банер негайно, оминаючи edge-детект і quiet-hours; тіло бере суму/ліміт з останнього
  снапшоту (`onTryExtraUsage` у shell читає `lastOutput.spend`), або generic-рядок, якщо `spend` немає.
  Пост сам гейтить на support+authorization, тож без дозволу це тихий no-op. Перемикач у Settings
  зветься **«Switching to Extra Usage»**; заголовок банера — **«Now using Extra Usage Credit»**.
- **Edge-state** — **окремий** persisted ключ `PersistedConfig.extraUsageWasOnCredits` (не ділиться з
  `backToWorkWasBlocked`, бо це різні стани). Як і там: оновлюється щополу незалежно від тумблера
  (off→on не забуває pending-edge і не вистрілює stale), постинг гейтиться `extraUsageNotifyEnabled`.

### Тіло банера — точні гроші, той самий формат, що дропдаун

`ExtraUsageOnset.bannerBody(for:)` (Kit) форматує суму+ліміт з **цілих** `Money` (`amount_minor /
10^exponent`), fallback на `extra_usage.used_credits` коли `spend.used` відсутній. Правила символу
валюти дзеркалять `PopupViewController.moneyText` (відомі валюти — символ у своїй позиції; невідомі —
ISO-код). Форматер **продубльовано** в Kit навмисно: pop-версія — `static` на AppKit-в'юконтролері
(executable target), не імпортується; правило мейнтейнера — тримати чисту копію в Kit для юніт-тестів.
Обидві копії мають лишатися синхронними (спільний known-currency набір).

### Розкол pure/shell ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md))

Уся логіка (сигнал + текст) — у `TokenPaceKit` (`ExtraUsageOnset`), повністю юніт-покрита
(`ExtraUsageOnsetTests`: 7 сигнальних + 6 формат-кейсів). Побічні ефекти (`UNUserNotificationCenter`,
edge-детект у `AppDelegate.detectExtraUsageEdge`) — у виконуваному таргеті, верифікуються вручну.

## Наслідки

- Default-OFF (opt-in), як і back-to-work — жодного банера, доки користувач не ввімкне (і не надасть
  дозвіл). На dev-білді (`swift run`) тумблер вимкнений і форсується off (авторизація неможлива).
- Верифікація — стуб `TOKENPACE_STUB=credits-onset` (перший пол не на кредитах → 7d=100 % з enabled
  credits) в установленому `.app`; деталі в [docs/guides/ui-verification.md](../guides/ui-verification.md).
- DND делеговано системі (як в ADR-0039).

## Альтернативи

- **Розширити ADR-0039 замість нового ADR** — відхилено: ADR immutable, а тут свідомі нові рішення
  (вибір `mainWindowExhausted`, окремий edge-state, узагальнення notifier).
- **Нотифікувати на кожній зміні суми** — відхилено: набридливо; сигнал — саме **момент переключення**,
  один банер на фронт (поточна сума живе в дропдауні постійно, ADR-0037).
- **Спільний edge-state із back-to-work** — відхилено: різні стани, злиття дало б хибні/пропущені фронти.
