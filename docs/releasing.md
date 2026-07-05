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

Деталі налаштування підпису — [ADR-0004](adr/0004-build-system.md),
[ADR-0012](adr/0012-configure-window-and-launch-at-login.md).

## Кроки

### 1. Визначити версію

Версія береться з файлу `VERSION` (марк. версія) і дублюється в
`Sources/TokenPaceKit/TokenPaceKit.swift` (`TokenPaceKit.version`). Якщо бампаєш —
онови **обидва** місця в окремому PR **перед** релізом і дотримуйся
[SemVer](https://semver.org/).

```sh
VERSION="$(tr -d ' \t\n\r' < VERSION)"   # напр. 0.9.0
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

```sh
git tag "v${VERSION}"
git push origin "v${VERSION}"

gh release create "v${VERSION}" \
   "./build/TokenPace-${VERSION}.zip" \
   --title "TokenPace v${VERSION}" \
   --notes "Опис релізу: що нового, як встановити (див. нижче)."
```

Тег ставимо на актуальний `main` (усі PR уже змерджені).

### 6. Перевірити з боку користувача

Завантаж ZIP із релізу на «чистому» Mac (або симулюй quarantine):

```sh
# симуляція завантаженого з інтернету застосунку
cp -R ./build/TokenPace.app /tmp/TokenPace-test.app
xattr -w com.apple.quarantine "0081;0;Safari;" /tmp/TokenPace-test.app
spctl -a -vvv -t exec /tmp/TokenPace-test.app   # має бути accepted
rm -rf /tmp/TokenPace-test.app
```

## Інструкція для користувачів (у тілі релізу)

> 1. Завантаж `TokenPace-X.Y.Z.zip` і розпакуй (подвійний клік).
> 2. Перетягни **TokenPace.app** у теку **Applications**.
> 3. Запусти з **Launchpad** або Finder. Іконки в Dock не буде — застосунок
>    живе в menu bar (`LSUIElement`).
>
> Бо застосунок нотаризований Apple, Gatekeeper не лаятиметься.
>
> **Launch-at-login** працює лише для копії в `/Applications`, запущеної звідти.
