---
status: accepted
date: 2026-07-06
---

# ADR-0018: Відновлення launch-at-login після оновлення — `.notFound` не термінальний

## Контекст

[ADR-0012](0012-configure-window-and-launch-at-login.md) §4 («Best-effort на unsigned» →
«Недоступність — видима, не мовчазна») трактує статус `SMAppService.mainApp.status == .notFound`
як **термінальний**: немає реєстровного login-item для цієї code identity, тож чекбокс
«Launch at login» у вікні Settings дизейблиться (сірий) і показує хінт «Unavailable in this
build… (not a developer build)». Орієнтир — кейс `swift run` (голий бінар без бандла), де
реєстрація справді неможлива.

На практиці виявилося, що `.notFound` **перевантажений** — macOS повертає його у двох семантично
різних ситуаціях (issue #69):

1. **`swift run` / голий бінар без бандла** — реєстрація неможлива. Дизейбл коректний.
2. **Легітимна підписана (Developer ID) і нотаризована інсталяція в `/Applications`, чия
   BTM-реєстрація login-item злетіла разом зі старим бандлом при in-place оновленні** —
   реєстрація можлива й потрібна.

Два предикати спільно давали баг:

- `isAvailable(.notFound) == false` → `SettingsWindowController.syncToggleFromSystem()` дизейблив
  чекбокс і показував «Unavailable…».
- `shouldRegisterOnFirstLaunch` fires лише на `.notRegistered` → `App.registerLaunchAtLoginIfNeeded()`
  логував `status=notFound, no auto-register` і виходив. Шляху відновлення з UI теж не було.

**Наслідок:** кожне оновлення застосунку назавжди вбивало launch-at-login — чекбокс сірий, жодного
способу відновити з інтерфейсу. Докази з unified log (обидві версії, одразу після інсталяцій
2026-07-06):

```
02:12:22 TokenPace (0.13.0, PID 50659): launch-at-login: status=notFound, no auto-register
13:22:43 TokenPace (0.14.0, PID 41449): launch-at-login: status=notFound, no auto-register
```

Не допомагали перезапуск чи `lsregister -f /Applications/TokenPace.app`. Quarantine/трансльокації
немає (процес живе за реальним `/Applications/…`), `spctl` → `accepted (Notarized Developer ID)`.

Ключова складність: **за самим статусом код не може розрізнити** dev-білд від post-update
інсталяції — обидва дають `.notFound`. У проєкті немає й ніколи не було детекції «підписаний бандл
у /Applications»: це повністю делеговано `SMAppService`.

## Рішення

1. **`.notFound` більше не термінальний-за-статусом. Предикат `isAvailable` видалено з kit;
   доступність чекбокса гейтиться по `.app`-бандлу, не по статусу.** Оскільки статус сам не
   розрізняє «dev `swift run`» від «`.app` після оновлення» (обидва `.notFound`), тримати цю
   дискримінацію в чистому ядрі неможливо — прибираємо `isAvailable` з
   `TokenPaceKit/LaunchAtLogin.swift`. Натомість `SettingsWindowController` гейтить
   `launchToggle.isEnabled` по `LaunchAtLoginController.isAppBundle`:
   - **`swift run` (не `.app`)** → чекбокс **сірий/недоступний**, хінт «Unavailable in this build…»
     — точно як ADR-0012 §4. Dev-білд ми не автозапускаємо і не даємо вмикати з UI.
   - **`.app`-бандл** → чекбокс **завжди enabled**, зокрема на `.notFound` (для інстальованого
     бандла це означає, що login-item злетів при оновленні); клік `register()` відновлює його (#69).

2. **`register()` — єдиний арбітр «чи можемо реєструвати».** Не будуємо евристику «підписаний +
   у /Applications» для *здатності*: інспекція шляху/підпису крихка (трансльокація, `/Applications`
   vs `~/Applications`, симлінки, майбутні зміни sandbox), дублює рішення, яке
   `SMAppService.register()` уже робить авторитетно. Даємо side-effect'у вирішувати: клік по toggle
   викликає `register()`, і воно або реєструє, або throw'ає.

   **Уточнення до припущення ADR-0012 §4** (виявлено при верифікації #69): `SMAppService.register()`
   на сучасній macOS реєструє й **ad-hoc-підписаний** `swift run` бінар (Swift ad-hoc-підписує
   вихід `swift build` зі стабільною code identity `TokenPace-<hash>`). Тобто «`swift run` завжди
   `.notFound`, реєстрація неможлива» — неточне узагальнення: dev-бінар реєструється під своєю
   ad-hoc-identity, окремою від Developer-ID-identity `.app`. Реальна причина #69 — не «неможливо
   зареєструвати», а те, що для `.app` у BTM **немає активного запису під його
   Developer-ID-identity** (`SMAppService.status` → `.notFound`), а старий код на `.notFound`
   відмовляв.

3. **Auto-register fires на `.notRegistered` **і** `.notFound`, але лише в `.app`-бандлі.** Предикат
   у kit перейменовано `shouldRegisterOnFirstLaunch` → `shouldAttemptRegister` (стара назва подвійно
   брехала: не «first launch» — виклик щозапуску, і не лише `.notRegistered`). Post-update старт
   `.app` self-heal'иться: `.notFound` → `register()` відновлює реєстрацію. Ідемпотентність — той
   самий guard за статусом (`.registered`/`.requiresApproval` не чіпаємо). Persistence-флаг «перший
   запуск» **не** додаємо — він завадив би саме цьому відновленню на post-update старті.

4. **Opt-out auto-register гейтований на `.app`-бандл** (`LaunchAtLoginController.isAppBundle` —
   `Bundle.main.bundleIdentifier != nil && bundleURL.pathExtension == "app"`). Оскільки ad-hoc
   dev-бінар **реєстровний** (Рішення §2), без цього гейта кожен `swift run` мовчки прописував би
   login-item на шлях у `.build/…` і засмічував Login Items користувача (#69). Гейт — це рішення про
   **політику авто-дії** (opt-out без згоди доречний лише для продукційного бандла), а не про
   *здатність* (нею лишається `register()`). Це визначення бандла живе в shell
   (`LaunchAtLoginController.isAppBundle`, поряд зі `SMAppService`-glue), а не в чистому kit — той
   самий предикат гейтить і доступність чекбокса (Рішення §1), і тег «(dev build)» у popup
   (Рішення §6). На dev-білді чекбокс сірий, тож ручний клік теж недоступний — launch-at-login на
   `swift run` вимкнено повністю (ми його не автозапускаємо). Фейл auto-register в `.app`-бандлі —
   несподіванка (інстальований, але нереєстровний), тож логуємо `.error`; клік-фейл теж `.error`.

5. **Хінт має три стани** (`hintText(inAppBundle:)`): (a) не `.app` (dev) → «Unavailable in this
   build…»; (b) `.app` + останній клік throw'нув (`lastToggleFailed`) → рядок відновлення
   («Reinstall… or add manually…»); (c) інакше → нейтральне «Launch TokenPace automatically when
   you log in.» Прапорець `lastToggleFailed` скидається на успішному toggle та на свіжому `show()`
   (стан, полагоджений у System Settings, не має перекриватися застарілим фейлом) і має сенс лише
   коли чекбокс enabled (тобто в `.app`).

6. **Dev-білд тегується «(dev build)» у popup.** Перший (жирний) рядок детального popup показує
   `TokenPace (dev build)` на `swift run`-бінарі й `TokenPace` в `.app` — той самий гейт
   `isAppBundle`. Це прибирає плутанину, коли dev-білд і встановлений `.app` працюють одночасно й
   у menu bar виглядають ідентично.

## Наслідки

- **dev-UX (`swift run`):** launch-at-login вимкнено повністю — auto-register на старті **не** fires
  (гейт `.app`, Рішення §4), тож `swift run` більше не прописує login-item на `.build/…`, і чекбокс
  сірий/недоступний (Рішення §1), як в ADR-0012 §4. Перший рядок popup тегується «(dev build)»
  (Рішення §6). Фікс #69 стосується виключно `.app`-бандла і dev-поведінку не змінює.
- **Прибирання старих dev-записів:** до гейта попередні `swift run` (і стара назва `cc-timer`) могли
  лишити login-items у BTM на шляхи в `.build/…` або `~/.Trash/…`. Їх прибирають вручну через
  System Settings → General → Login Items (user-space, точкове видалення; `sfltool resetbtm` не
  годиться — скидає всю BTM-базу). Після гейта нові `swift run` таких записів не створюють.
- **Едж `register()` → `.requiresApproval` на `.notFound`:** реальний і вже обробляється на
  клік-шляху — `toggleLaunchAtLogin` після `enable()` перевіряє `needsSystemSettings` і веде в
  System Settings → Login Items. На фоновому старті туди не ведемо (правильно), стан лишається
  `.requiresApproval` до наступного відкриття вікна.
- **Тести:** `isAvailable` видалено разом із тестом `unavailableOnlyWhenNotFound`; тест auto-register
  тепер очікує `true` на `.notFound` (регрес-guard для #69). `toggleState`/`needsSystemSettings`
  незмінні. SMAppService-glue і stateful-хінт — manual-verify за конвенцією
  ([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) §«Наслідки»).
- **Перевірити (manual):**
  - `swift run`: старт логує `not an .app bundle (swift run), skipping opt-out auto-register` — і в
    BTM **не** з'являється запис на `.build/…`. Чекбокс у Settings клікабельний.
  - Підписаний+нотаризований `.app` у `/Applications` **після in-place оновлення** (заміни бандла):
    статус `.notFound` → auto-register на наступному старті **відновлює** реєстрацію; чекбокс
    active/on. Це **саме той сценарій, який верифікація ADR-0012 не покривала**: її нотатка
    перевіряла свіжу інсталяцію (`.enabled`) і `swift run` (`.notFound`), але не заміну бандла.
    Підтверджено з unified log (#69): п'ять поспіль стартів `.app` давали `status=notFound,
    no auto-register` до фіксу.

## Пов'язані

- [ADR-0012](0012-configure-window-and-launch-at-login.md) — superseded у частині §4 (термінальність
  `.notFound`); решта чинна.
- [ADR-0002](0002-ukrainian-documentation.md) — мова документації.
- Issues: #14 (початкова реалізація launch-at-login), #21 (поведінка підписаного бандла),
  #69 (цей баг).
