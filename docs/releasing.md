# Процедура релізу

Як зібрати, нотаризувати й опублікувати реліз `cc-timer` на GitHub, щоб ним могли
користуватися інші (друзі, тестувальники) без попереджень Gatekeeper.

> **Стейдж 1 — ручний реліз** (цей документ). Автоматизацію планують окремо:
> скрипт `scripts/release.sh` і GitHub Actions workflow — див. issues у трекері.

## Передумови (одноразово)

- **Developer ID Application** identity у Keychain
  (`security find-identity -v -p codesigning` показує 1 valid identity).
- **notarytool keychain-профіль** `cc-timer-notary`:
  ```sh
  xcrun notarytool store-credentials cc-timer-notary \
        --apple-id <APPLE_ID> --team-id <TEAM_ID>
  # запитає app-specific password з appleid.apple.com (НЕ основний пароль)
  ```
- `gh` CLI автентифікований (`gh auth status`).

Деталі налаштування підпису — [ADR-0004](adr/0004-build-system.md),
[ADR-0012](adr/0012-configure-window-and-launch-at-login.md).

## Кроки

### 1. Визначити версію

Версія береться з файлу `VERSION` (марк. версія) і дублюється в
`Sources/CCTimerKit/CCTimerKit.swift` (`CCTimerKit.version`). Якщо бампаєш —
онови **обидва** місця в окремому PR **перед** релізом і дотримуйся
[SemVer](https://semver.org/).

```sh
VERSION="$(tr -d ' \t\n\r' < VERSION)"   # напр. 0.9.0
```

### 2. Зібрати, підписати, нотаризувати

```sh
./scripts/build-app.sh
```

Скрипт сам: збирає release-бінар, складає `.app`, підписує Developer ID
(`--options runtime`), нотаризує (`notarytool submit --wait`) і прикріплює
квиток (`stapler staple`). Нотаризація може зайняти кілька хвилин.

Очікувати в логах: `status: Accepted` і `The staple and validate action worked!`.

### 3. Перевірити нотаризацію

```sh
spctl -a -vvv -t exec ./build/cc-timer.app   # → accepted (Notarized Developer ID)
xcrun stapler validate ./build/cc-timer.app  # → The validate action worked!
```

Якщо `spctl` дає `rejected` — реліз **не** публікувати, спершу розібратися.

### 4. Спакувати реліз-архів

`build-app.sh` видаляє свій тимчасовий ZIP після нотаризації, тож архів для
релізу робимо окремо — з **уже застейпленого** `.app` (щоб квиток поїхав усередині):

```sh
ditto -c -k --keepParent ./build/cc-timer.app "./build/cc-timer-${VERSION}.zip"
```

`--keepParent` зберігає теку `cc-timer.app` усередині архіву (інакше
розпакується «розсипом»). `ditto` (а не `zip`) коректно зберігає підпис і
extended attributes.

### 5. Створити тег і GitHub Release

```sh
git tag "v${VERSION}"
git push origin "v${VERSION}"

gh release create "v${VERSION}" \
   "./build/cc-timer-${VERSION}.zip" \
   --title "cc-timer v${VERSION}" \
   --notes "Опис релізу: що нового, як встановити (див. нижче)."
```

Тег ставимо на актуальний `main` (усі PR уже змерджені).

### 6. Перевірити з боку користувача

Завантаж ZIP із релізу на «чистому» Mac (або симулюй quarantine):

```sh
# симуляція завантаженого з інтернету застосунку
cp -R ./build/cc-timer.app /tmp/cc-timer-test.app
xattr -w com.apple.quarantine "0081;0;Safari;" /tmp/cc-timer-test.app
spctl -a -vvv -t exec /tmp/cc-timer-test.app   # має бути accepted
rm -rf /tmp/cc-timer-test.app
```

## Інструкція для користувачів (у тілі релізу)

> 1. Завантаж `cc-timer-X.Y.Z.zip` і розпакуй (подвійний клік).
> 2. Перетягни **cc-timer.app** у теку **Applications**.
> 3. Запусти з **Launchpad** або Finder. Іконки в Dock не буде — застосунок
>    живе в menu bar (`LSUIElement`).
>
> Бо застосунок нотаризований Apple, Gatekeeper не лаятиметься.
>
> **Launch-at-login** працює лише для копії в `/Applications`, запущеної звідти.
