---
status: accepted
date: 2026-07-22
---

# ADR-0019: Читання токена сабпроцесом `security` CLI (скидання partition list)

## Контекст

Симптом (липень 2026, нотаризований `.app` з /Applications): при кожному протуханні токена macOS
знову показує keychain-промпти (по два за цикл), і «Always Allow» не допомагає — наступного
протухання промпти повертаються. Між протуханнями читання тихе.

Діагностика на живому Keychain (read-only дамп ACL через `SecKeychainItemCopyAccess`):

- Item `Claude Code-credentials` **не пересоздається**: `cdat` = 2026-01-21, `mdat` оновлюється
  щорефрешу — Claude Code переписує його на місці. Гіпотеза «назва/об'єкт щоразу інші» хибна.
- У trusted-apps ACL — **46 записів**, майже всі дублі dev- і release-бінарів TokenPace: кожен
  клік «Always Allow» додавав запис, записи зберігаються — але не допомагають.
- **Partition list** item-а — лише `apple-tool:`. Із macOS Sierra тихий доступ вимагає *двох*
  умов: застосунок у trusted apps **і** його code-signing партиція (`teamid:S5A4U9798Y`) у
  partition list. Другої умови GUI-збірки TokenPace не задовольняють ніколи надовго:
- Claude Code читає й пише item через `/usr/bin/security` (у бінарнику CLI є рядки
  `add-generic-password` / `find-generic-password` / `delete-generic-password`; партиція
  створення `apple-tool:`; жодного node/claude у trusted apps). **Симуляція підтвердила
  механізм**: на тестовому item-і зі списком `apple-tool:,teamid:S5A4U9798Y` виклик
  `security add-generic-password -U` (саме так CC оновлює креденшали) **скидає partition list
  до `apple-tool:`**. Тобто кожен refresh (~кожні 8 год) відкликає доступ, виданий юзером.

Розглянуті варіанти:

1. **Разовий `security set-generic-password-partition-list -S "apple-tool:,teamid:…"`** —
   працює лише до наступного refresh (див. симуляцію вище). Відпадає.
2. **Кешування креденшалів у пам'яті** — зменшує кількість промптів, але перше читання після
   кожного refresh все одно промптить. Відпадає.
3. **Власна копія токена у власному keychain item** — щоб синхронізувати копію, треба спершу
   прочитати оригінал → промпт лишається. Відпадає.
4. **Читання сабпроцесом `/usr/bin/security find-generic-password -w`** — той самий канал, яким
   користується сам Claude Code: `security` — Apple-tool, завжди всередині партиції
   `apple-tool:` і (як creator item-а) у trusted apps, тож читає тихо незалежно від того, як
   часто CC переписує item, і незалежно від підпису збірки TokenPace (ad-hoc `swift run`
   включно). Обрано.

Місце зміни: `TokenProvider.readRawData()` (kit) — єдина точка Keychain-читання; через неї
проходять і полінг (`KeychainTokenProvider`), і `ClaudeCLIRefresher` (before/after-перевірки).
Альтернатива «shell-side seam у таргеті `TokenPace`» (за прикладом `ClaudeCLIRefresher`)
відхилена: розмазує зміну на два таргети, вимагає розширення протоколу `TokenProviding` та
інжекції в refresher, а Фаза 2 keychain-читання не реюзає (iOS/watchOS отримують дані з
CloudKit) — тож «чистота kit без сабпроцесів» не купує нічого практичного.

## Рішення

1. `TokenProvider.readRawData()` спавнить `/usr/bin/security find-generic-password -s
   "Claude Code-credentials" -w` (фіксований шлях бінарника; матч лише за service) замість
   `SecItemCopyMatching`. stdin → `/dev/null`, stdout/stderr — у pipe (stderr ніколи не
   логується — може містити атрибути item-а). Жорсткий таймаут 10 с (`SIGTERM`).
2. Pure-обробка, юніт-тестована: `parseSecretOutput` (зрізання одного trailing newline,
   захисний hex-декод — `-w` hex-кодує не-текстові секрети; JSON-обгортка починається з `{` і з
   hex не колізує) та `mapExitStatus` (exit 44 → `.itemNotFound`, перевірено емпірично; інші
   коди → `.keychainError(код)`).
3. `TokenError` не змінюється (public enum, exhaustive-switch у `FailureReason`):
   `.accessDenied` новим шляхом не продукується, але лишається; `.keychainError` тепер несе
   exit code тулзи або локальні сентинели `-1` (spawn failed) / `-2` (timeout).
4. Політика ADR-0017 незмінна: TokenPace у Keychain **не пише**; refresh так само делегується
   `claude` CLI.

## Наслідки

- **(+) Промптів немає назавжди** — для нотаризованої, dev- і будь-якої майбутньої збірки;
  жодних разових ритуалів із partition list. Верифіковано на ad-hoc dev-бінарі: читання тихе,
  `usage 200 ok` за ~300 мс від старту.
- **(+)** Issue #20 (pre-auth UX-діалог перед першим keychain-промптом) втрачає предмет —
  промпта більше немає; #21 (перевірка ACL signed vs unsigned) закривається цим дослідженням.
- **(−)** Другий спавн сабпроцесу в кодовій базі, тепер у kit (відступ від «спавн лише
  shell-side», зафіксованого в ADR-0017) — свідомо, див. Контекст.
- **(−)** Залежність від формату виводу `security -w` (plaintext + `\n`, hex для бінарних
  даних) — покрито `parseSecretOutput` і тестами; зміна формату зламає читання показово
  (`malformedData`), не мовчки.
- **(−)** Синхронний виклик із таймаутом 10 с: у патології (залочений keychain) полінг-потік
  блокується до таймаута; штатно — десятки мілісекунд.
- Секрет проходить через stdout-pipe сабпроцеса в межах процесу TokenPace — не в аргументах,
  не в env, не в логах (логуються лише exit status і байт-каунт).
