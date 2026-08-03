# Процедура релізу

Як зібрати, нотаризувати й опублікувати реліз `TokenPace` на GitHub, щоб ним могли
користуватися інші (друзі, тестувальники) без попереджень Gatekeeper.

> **Стейдж 1 — ручний реліз** (цей документ). Автоматизацію планують окремо:
> скрипт `scripts/release.sh` і GitHub Actions workflow — див. issues у трекері.

## Передумови (одноразово)

- **Developer ID Application** identity у Keychain
  (`security find-identity -v -p codesigning` показує 1 valid identity).
- **notarytool keychain-профіль** `tokenpace-notary`:
  ```sh
  xcrun notarytool store-credentials tokenpace-notary \
        --apple-id <APPLE_ID> --team-id <TEAM_ID>
  # запитає app-specific password з appleid.apple.com (НЕ основний пароль)
  ```
- `gh` CLI автентифікований (`gh auth status`).

Деталі налаштування підпису — [ADR-0004](../adr/0004-build-system.md),
[ADR-0012](../adr/0012-configure-window-and-launch-at-login.md).

## Передпольотні перевірки (перед збіркою)

Прогнати **перед** тим, як бампати версію та збирати. Мета — не випустити реліз, що
тихо ламає збережені налаштування чи стан у користувачів, які оновлюються з попередньої
версії. За базу порівняння беремо тег останнього GitHub-релізу:

```sh
LAST="$(gh release view --json tagName -q .tagName)"   # напр. v0.44.0
```

### A. Чи змінилися конфігураційні опції — і чи потрібна міграція

Усі опції користувача живуть у єдиному файлі `Sources/TokenPace/PersistedConfig.swift`
(`enum PersistedConfig` над `UserDefaults`; приватний `enum Key` — канонічний реєстр
рядкових ключів). `@AppStorage` ніде не використовується, `register(defaults:)` немає —
дефолти зашиті в геттерах.

```sh
git diff "${LAST}..HEAD" -- Sources/TokenPace/PersistedConfig.swift
```

На що дивитися в дифі й що це означає для міграції:

- **Новий ключ** — сумісно, міграція не потрібна: стара збірка його просто не писала,
  геттер віддасть дефолт.
- **Перейменований або видалений ключ** — **несумісно**. Старе значення осиротіє під
  старим рядком. Або читати старий ключ і переписувати в новий (справжня міграція, див.
  нижче), або зберегти зворотну сумісність через fallback у геттері.
- **Змінений дефолт** — перевір ідіому. Opt-out опції читаються як
  `object(forKey:) ... ?? true`, opt-in — `?? false`; це навмисно відрізняє «не задано»
  від явного вибору. Зміна цієї гілки мовчки перевизначить те, що користувач уже вимкнув/
  увімкнув — це помітна поведінкова зміна, а не косметика.

### B. Чи змінилися persistent-стани — і чи потрібна міграція

Persistent-стан (переживає рестарт, окрім простих опцій) теж лежить у тих самих
`UserDefaults`-ключах. Окремого on-disk сховища немає (usage-snapshot тримається лише в
пам'яті; `UpdateInstaller` пише лише в temp із `defer`-видаленням). Ключове — це
серіалізовані типи, чия **форма** персиститься:

```sh
git diff "${LAST}..HEAD" -- \
  Sources/TokenPaceKit/MonitoredServices.swift \
  Sources/TokenPaceKit/ResetCountdownMode.swift \
  Sources/TokenPaceKit/SuppressDays.swift
```

- `MonitoredServices` (`Codable`) серіалізується як JSON-блоб у `monitoredServices`.
  `MonitoredServicesTests.swift` пінить raw-рядки саме тому, що вони персистяться.
- `ResetCountdownMode`, `SuppressDays` — raw-string enums, зберігаються за raw-значенням.
- **Правило сумісності:** усі троє декодуються **forward-compatible** — несумісний/невідомий
  raw тихо падає в дефолт (не креш). Якщо міняєш форму (нове/перейменоване поле, інший
  raw) — **збережи цю властивість**: старий блоб має або коректно декодуватись, або
  безпечно відкотитись у дефолт. Легенду legacy-значень тримай у коментарях типу (як уже
  зроблено для `show_distant_7d`/`hide_distant_7d` → `.smart`).

Також перевір edge-detect / update / archive стан (`backToWorkWasBlocked`,
`pendingWhatsNewVersion`, `lastFailedInstallVersion`, `lastUpdateCheck`,
`lastSeenLatestVersion`, `lastArchiveSync`) у тому ж дифі `PersistedConfig.swift` — зміна
семантики цих ключів між версіями теж може дати неочікувану поведінку після оновлення.

### C. Якщо міграція таки потрібна

Каркас існує, але **реальних кроків міграції ще немає** (див.
[ADR-0023](../adr/0023-persisted-config-version-marker.md)):

- Чисте ядро — `Sources/TokenPaceKit/MigrationPlan.swift` (`MigrationPlan.transition`,
  `needsMigration`).
- Хук на старті — `AppDelegate.runConfigMigrationsIfNeeded()` (`Sources/TokenPace/App.swift`),
  викликається першим у `applicationDidFinishLaunching`. Гілка `.upgraded` зараз **порожня**
  (scaffold, #71); маркер версії — `PersistedConfig.lastRunVersion`.

Найдешевший шлях — зробити зміну forward-compatible (як існуючі enum-decode). Якщо це
неможливо (перейменування ключа зі збереженням значення, реальна трансформація форми) —
наповни `.upgraded`-гілку в `runConfigMigrationsIfNeeded` кроком from→to й покрий тестом.
Зміна `MigrationPlan`/поява реального кроку — привід оновити ADR-0023.

## Кроки

### 1. Визначити версію

Версія береться з файлу `VERSION` (марк. версія) і дублюється в
`Sources/TokenPaceKit/TokenPaceKit.swift` (`TokenPaceKit.version`). Якщо бампаєш —
онови **обидва** місця в окремому PR **перед** релізом і дотримуйся
[SemVer](https://semver.org/).

```sh
VERSION="$(tr -d ' \t\n\r' < VERSION)"   # напр. 0.9.0
```

**Звір обидва джерела ПЕРЕД тегом** — розбіжність означає, що бамп зачепив лише одне місце:

```sh
grep -q "\"${VERSION}\"" Sources/TokenPaceKit/TokenPaceKit.swift \
  || echo "MISMATCH: VERSION=${VERSION} != TokenPaceKit.version — онови обидва в окремому PR"
```

### 2. Зібрати, підписати, нотаризувати

```sh
./scripts/build-app.sh
```

Скрипт сам: збирає release-бінар як **universal** (arm64 + x86_64 — кожна арка
окремо за `--triple`, потім `lipo -create`, щоб `.app` працював і на Apple
Silicon, і на Intel), складає `.app`, підписує Developer ID (`--options
runtime`), нотаризує (`notarytool submit --wait`) і прикріплює квиток (`stapler
staple`). Нотаризація може зайняти кілька хвилин.

Очікувати в логах: `lipo archs: x86_64 arm64`, `status: Accepted` і
`The staple and validate action worked!`.

**Агент/фонова сесія:** харнес блокує голий `sleep`, тож не чекай нотаризацію через `sleep N` —
підніми білд у фоні й опитуй лог until-циклом (нотаризація може зайняти кілька хвилин):

```sh
( ./scripts/build-app.sh 2>&1 | tee "$CLAUDE_JOB_DIR/tmp/build.log" ) &
until grep -qE 'notarization complete|done:|error|Invalid' "$CLAUDE_JOB_DIR/tmp/build.log"; do
  sleep 2
done
```

### 3. Перевірити нотаризацію

```sh
spctl -a -vvv -t exec ./build/TokenPace.app   # → accepted (Notarized Developer ID)
xcrun stapler validate ./build/TokenPace.app  # → The validate action worked!
lipo -archs ./build/TokenPace.app/Contents/MacOS/TokenPace   # → x86_64 arm64
```

Якщо `spctl` дає `rejected` — реліз **не** публікувати, спершу розібратися.
Якщо `lipo` показує лише одну арку — бінар не universal, перебудувати.

### 4. Спакувати реліз-архів

`build-app.sh` видаляє свій тимчасовий ZIP після нотаризації, тож архів для
релізу робимо окремо — з **уже застейпленого** `.app` (щоб квиток поїхав усередині):

```sh
ditto -c -k --keepParent ./build/TokenPace.app "./build/TokenPace-${VERSION}.zip"
```

`--keepParent` зберігає теку `TokenPace.app` усередині архіву (інакше
розпакується «розсипом»). `ditto` (а не `zip`) коректно зберігає підпис і
extended attributes.

### 5. Створити тег і GitHub Release

**Перед тегуванням переконайся, що стоїш на чистому `main`** — тег на випадковій feature-гілці
(або коміт прямо в `main`) уже колись ламав реліз, коли `checkout -b` тихо не спрацював через
git-lock:

```sh
[ "$(git branch --show-current)" = main ] && git diff --quiet && git diff --cached --quiet \
  || echo "STOP: не на чистому main — не тегуй звідси (див. agent-workflow.md § Гілки)"
```

Деталі git-дисципліни — [agent-workflow.md § Гілки, PR і синхронізація main](agent-workflow.md#гілки-pr-і-синхронізація-main).

```sh
git tag "v${VERSION}"
git push origin "v${VERSION}"

RELEASE_NOTES_APPROVED=1 gh release create "v${VERSION}" \
   "./build/TokenPace-${VERSION}.zip" \
   --title "TokenPace v${VERSION}" \
   --notes "Опис релізу: що нового, як встановити (див. нижче)."
```

Тег ставимо на актуальний `main` (усі PR уже змерджені).

> **Гейт release notes.** `gh release create` стереже hook
> (`.claude/hooks/release-notes-guard.sh`): він блокує публікацію, доки команду не запущено з
> префіксом `RELEASE_NOTES_APPROVED=1`. Префікс додають **лише після** того, як нотатки складено за
> цим документом (автооновлення — канонічний шлях) і затверджено мейнтейнером. Це запобіжник проти
> публікації нотаток, написаних із пам'яті без звірки з цим файлом.

### 6. Перевірити з боку користувача

Завантаж ZIP із релізу на «чистому» Mac (або симулюй quarantine):

```sh
# симуляція завантаженого з інтернету застосунку
cp -R ./build/TokenPace.app /tmp/TokenPace-test.app
xattr -w com.apple.quarantine "0081;0;Safari;" /tmp/TokenPace-test.app
spctl -a -vvv -t exec /tmp/TokenPace-test.app   # має бути accepted
rm -rf /tmp/TokenPace-test.app
```

## Якщо реліз обірвався посередині — як продовжити

Реліз — це ланцюг кроків, і сесія може обірватися (перервали, впала мережа GitHub, `--wait`
завис) посеред нього. **Не перезапускай із нуля** — спершу перевір, що вже зроблено, і продовжуй
з місця зупинки. Кожна перевірка нижче — недеструктивна (читає стан, не змінює його).

### `.app` уже зібраний і застейплений

```sh
spctl -a -t exec ./build/TokenPace.app   # accepted → build+notarize+staple вже позаду
```

Якщо `accepted` — пропусти кроки 2–3, йди прямо до пакування (крок 4). Перебудовувати не треба:
`.app` у `build/` уже нотаризований і з квитком.

### Нотаризація: `--wait` завис на `In Progress`

Це не збій — `submit --wait` іноді не відпускає, хоча Apple уже завершила. **Не перезбирай.**
Дізнайся фінальний статус окремо від `--wait`:

```sh
xcrun notarytool history --keychain-profile tokenpace-notary        # знайди свій submission-id
xcrun notarytool log <submission-id> --keychain-profile tokenpace-notary
```

Якщо статус `Accepted` — одразу застейпли й перевір, минаючи повторний `submit`:

```sh
xcrun stapler staple ./build/TokenPace.app
spctl -a -t exec ./build/TokenPace.app   # → accepted
```

### Тег `v${VERSION}` уже існує

```sh
git rev-parse "v${VERSION}" 2>/dev/null   # існує → звір, куди вказує
```

- Вказує на потрібний HEAD (актуальний `main`) → пропусти `git tag`, йди до `git push` / релізу.
- Вказує на інший коміт (залишок обірваної спроби) → `git tag -d "v${VERSION}"` і перестворити
  на правильному коміті.

### Реліз для цієї версії частково існує

```sh
gh release view "v${VERSION}"   # існує? з яким асетом?
```

- Реліз є, але **без ZIP-асета** → долий асет:
  `gh release upload "v${VERSION}" "./build/TokenPace-${VERSION}.zip"`.
- Лишився **конфліктний старіший реліз**, що заважає (напр. попередній `latest`, чий бінар не
  відповідає новому тегу) → видали його перед публікацією нового:
  `gh release delete "v${VERSION_OLD}"` (з підтвердженням мейнтейнера).
- Тег є, релізу нема → просто виконай `gh release create` (крок 5), тег повторно не створюй.

## Зміст і стиль release notes

Аудиторія — **гіки, що самі користуються Claude Code**. Пиши українською, як для колеги, а не для
пресрелізу.

**Обов'язково перед публікацією — показати згенеровані нотатки мейнтейнеру на затвердження.** Не
публікувати реліз, доки він не сказав «ок».

**Крок 0 — узгодити, що взагалі ввійде в нотатки.** Перш ніж писати текст, склади
**повний перелік нових фічей і помітних змін** з останнього GitHub-релізу й дай
мейнтейнеру відзначити чекбоксами ті, що потрапляють у release notes. Не вирішуй сам, що
«дрібне» — покажи все й дай обрати.

```sh
LAST="$(gh release view --json tagName -q .tagName)"        # напр. v0.44.0
git log "${LAST}..HEAD" --no-merges --pretty='- [ ] %s'     # кандидати як чекбокс-список
```

Подай результат як Markdown-чекліст, згрупувавши споріднені коміти в один пункт (див.
правила мержу нижче) і відсіявши суто внутрішнє (рефактор без видимого ефекту, CI, бампи
версії). Кожен рядок — `- [ ] <людський опис фічі>`, напр.:

```markdown
- [ ] Динамічний yellow→orange поріг pacing + 20-хв override (#179)
- [ ] Reset-line єдиного формату для всіх лімітів у попапі (#175)
- [ ] Чесна grace-межа ресету — більше без «resetting…» (#180)
```

Мейнтейнер проставляє `[x]` навпроти тих, що йдуть у реліз; лише **відзначені** пункти
стають основою тексту нотаток. Ті, що лишились `[ ]`, у нотатки не потрапляють.

**Що охоплювати:**

- **Охоплюй усе з останнього GitHub-релізу.** Між релізами накопичується кілька проміжних версій;
  бери всі значущі зміни від останнього тегу на GitHub (`gh release view` → його тег →
  `git log <тег>..HEAD`). Дрібні косметичні/точкові правки можна не згадувати.
- **Не вказуй окремі проміжні версії.** Читачеві байдуже, що фіча зайшла в `0.32.0`, а допрацювалась
  у `0.34.0` — пиши про зміну як про одне ціле. У нотатках фігурує лише **фінальна** версія релізу.
- **Мерж текст споріднених фічей, коли доречно.** Кілька новин про ту саму фічу з різних проміжних
  версій — злий в одну. Приклади: параметри однієї фічі, додані в різних версіях → один пункт;
  доданий функціонал + виправлена його поведінка в наступній версії → один пункт (описуй кінцевий
  стан, не історію ітерацій).

**Тон і структура:**

- **Дружньо й лаконічно.** «Додали / полагодили / тепер», а не «реалізовано / здійснено оптимізацію».
- **Головне — вперед.** Що змінилось для користувача в першому реченні; технічні деталі — нижче або
  за посиланням на ADR/PR.
- **Гумор — гомеопатично.** Одна легка фраза на нотатку максимум, і лише якщо доречна. Без емодзі-спаму.
- **Поважай читача.** Гік не потребує пояснення, що таке menu bar чи ресет.
- **Структура** (гнучка): короткий заголовок фічі → 1–2 речення суті → за потреби компактний список
  конкретики → секція про оновлення й встановлення (нижче).

**Секція про оновлення (в кінці нотаток):**

- **Рекомендуй увімкнути автооновлення** в застосунку (Settings → About → «Check for updates periodically» +
  «Install updates automatically») — щоб наступні релізи прилітали самі, без ручного качання.
- **Лиши короткий опис ручного встановлення** для тих, хто ставить уперше або віддає перевагу вручну
  (завантажити zip → розпакувати → перетягнути в Applications → запустити з Launchpad). Повна
  інструкція — нижче.

Приклад вдалого тону: «Тепер віджет не мозолить очі часом ресету, коли й так усе спокійно — показує
його лише коли пора звертати увагу.» Приклад невдалого (надто сухо): «Реалізовано механізм умовного
приховування countdown-елемента згідно з матрицею станів.»

## Інструкція для користувачів (у тілі релізу)

> 1. Завантаж `TokenPace-X.Y.Z.zip` і розпакуй (подвійний клік).
> 2. Перетягни **TokenPace.app** у теку **Applications**.
> 3. Запусти з **Launchpad** або Finder. Іконки в Dock не буде — застосунок
>    живе в menu bar (`LSUIElement`).
>
> Бо застосунок нотаризований Apple, Gatekeeper не лаятиметься.
>
> **Launch-at-login** працює лише для копії в `/Applications`, запущеної звідти.
