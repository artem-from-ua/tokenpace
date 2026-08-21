# Glossary — the project's terminology contract

The vocabulary this project writes in, and the one Ukrainian term each English word replaces.

This is a **contract, not a suggestion**. The documentation is being translated in twelve
independent packages ([#441](https://github.com/artem-from-ua/tokenpace/issues/441)), and every
translator — human or agent — sees only its own slice of the corpus. Ten batches choosing
individually defensible synonyms produce ten vocabularies, each internally consistent, and no check
catches it: a synonym is not an error. Pinning the words up front is the only mechanism that works.

Nothing here was invented. The domain vocabulary was **already English** before the migration
started — `pacing` appears 190 times in the corpus, `reset` 288, `calm` 118 — surrounded by
Ukrainian prose. The job was to enumerate what already existed and pin a rendering for the concepts
that were still Cyrillic.

The third column, "replaced", is the point of the table. It is what makes it possible to audit
whether a translation was faithful: given an English page and this glossary, you can reconstruct
what the Ukrainian said. Keep it.

## House vocabulary — already English, never re-synonymize

These words were English in the Ukrainian corpus. They are the project's own terms, they appear in
UI strings and identifiers, and replacing one with a synonym silently breaks the link between the
docs and the code they describe.

| Term | What it means here | Replaced (Ukrainian) |
|---|---|---|
| **pacing** | whether spending is ahead of or behind the clock within a window — the app's core computation, not a rate | пейсинг |
| **reset** | the moment a usage window's counter returns to zero | ресет |
| **window** | one of the two subscription limits (5-hour, 7-day) | вікно |
| **calm** | the state where the widget has nothing worth saying and stays quiet | спокійний |
| **awaiting** | a Claude session waiting for the user's input | — |
| **journal** | the local append-only usage log (`usage-journal-*.jsonl`) | журнал |
| **tick** | one iteration of a periodic task | тік |
| **snapshot** | one captured reading of usage state | знімок |
| **badge** | the small count/marker drawn over a glyph | бейдж |
| **track** | the gray full-width base every bar is drawn on — the layer things sit *above* or *below*. Not a synonym for **bar**: "the zero tick is drawn under the track" and "an empty track would read as no data" are both false if you substitute *bar*. | трек |
| **strip** | the colored band drawn over the track (Balance, Pressure) | стрічка |
| **chip** | a compact labeled element (e.g. the incident chip) | чіп |
| **swatch** | a color sample, and the mode that renders one for measurement | swatch |
| **gate** | a condition that stops a periodic task from running | гейт |
| **stub** | a canned data source used for UI verification (`TOKENPACE_STUB=…`) | стуб |
| **polling** | the scheduled fetching of usage data | полінг |
| **cadence** | how often a periodic task runs | каденція |
| **marker** | a drawn indicator on a bar | маркер |
| **glyph** | an SF Symbol drawn in the menu bar | гліф |
| **pill** | a rounded capsule shape — the zero-width minimum a strip floors to | пігулка |
| **color capsule** | the colored span Progress draws over `gapStart..gapEnd` — deliberately *not* a fill from zero ([ADR-0079](../adr/0079-centred-zero-gauge-scale.md)) | кольорова капсула |


### `bar` carries two senses — both are correct

The UI element (`смужка`/`бар`) and the criterion (`планка`) both land on **bar**, and they appear in
adjacent paragraphs in [personas.md](personas.md) and [users-and-goals.md](users-and-goals.md). This is
deliberate: "clears the bar" and "raise the bar" are live English idioms carrying the same
height metaphor the Ukrainian had, and the verb disambiguates in practice — a bar that is *orange* is
the widget, a bar that is *cleared* is the criterion.

Do not "fix" this by renaming the criterion to *threshold*: that word is already taken in these files
for actual numeric thresholds (the dynamic pacing threshold, the 20-minute threshold), and the collision
would be worse than the one it solves.

### Bar anatomy — the layers have distinct names

Ordering matters in the rendering ADRs, so the parts are named separately and are not interchangeable:

| Part | What it is |
|---|---|
| **bar** | the whole widget |
| **track** | the gray full-width base |
| **strip** | the colored band over the track (Balance, Pressure) |
| **color capsule** | the colored span over `gapStart..gapEnd` (Progress) |
| **pill** | the rounded minimum a strip floors to at zero |
| **marker** | the time indicator drawn on the bar |
| **ruler** / **tick** | the subdivision scale under the bar |

`track` is already in use in the translated [SPEC.md](../../SPEC.md) ("a gray track with a green pill at
zero") and across the rendering ADRs — this table records existing practice rather than introducing it.

## Pinned mappings — one English word per concept

Where the corpus used a Cyrillic term, this is the rendering. The third column lists synonyms that
are **wrong here** — each is a word a reasonable translator would otherwise pick.

| Ukrainian | English | Do NOT use |
|---|---|---|
| смужка / бар | **bar** — the whole widget: track + strip/capsule + marker + ruler | stripe, gauge |
| планка (the criterion) | **bar**, as in "clears the bar", "raise the bar" | threshold, test, standard |
| стрічка | **strip** | ribbon, band |
| ресет | **reset** | refresh, rollover |
| вікно (5h/7d) | **window** | period, cycle |
| пейсинг | **pacing** | rate, tempo |
| спокійний | **calm** | quiet, idle |
| дропдаун | **dropdown** (the menu) | menu |
| попап | **popup** (the panel) | panel |
| пігулка | **pill** | capsule |
| маркер | **marker** | indicator |
| гліф | **glyph** | icon, symbol |
| каденція | **cadence** | frequency, interval |
| полінг | **polling** | fetching |
| витіснений | **superseded** | replaced, obsoleted |
| частково витіснений | **partially superseded** | — |
| чинний | **still stands** | valid, actual |
| хардкод | **hardcode** | fixed value |
| стуб | **stub** | mock, fake |
| гейт | **gate** | check, guard |

**`дропдаун` and `попап` are two different surfaces, not two words for one.** The dropdown is the
menu under the status item; the popup is the panel it opens. The Ukrainian corpus distinguishes
them and so must the English — collapsing both into "menu" or "panel" loses a distinction the UI
actually makes.

**`чинний` deserves the special attention.** It appears 177 times, almost all of it in the
supersession notes of [`docs/adr/README.md`](../adr/README.md) and the ADRs themselves, always
predicatively: "рішення чинне", "решта 0068 чинна". Render it **"still stands"** — "the decision
still stands", "the rest of 0068 still stands". Not "valid" (which invites "invalid" for its
opposite, and the opposite here is *superseded*), not "actual" (a false friend: Ukrainian
`актуальний` means current, English "actual" means real).

## Canonical section headings — pinned before any ADR is translated

The ADR corpus uses **eleven** different Ukrainian phrasings for one section:

```
20× ## Альтернативи                      6× ## Розглянуті варіанти
 3× ## Альтернативи, які розглянуто й відхилено
 1× ## Розглянуті альтернативи           1× ## Розглянуті альтернативи: чим саме показати, що бар інший
 1× ## Розглянуті й відкинуті альтернативи
 1× ## Альтернативи, які відхилено       1× ## Альтернативи, які відкинуто
 1× ## Альтернативи, які відпали         1× ## Альтернативи (відкинуті)
 1× ## Альтернатива: hooks (відкладено)
```

Ten independent translation batches will otherwise produce ten different English headings, each
individually defensible — and **every check will pass**, because none of them is wrong. Worse, two
variants collapsing into one heading inside a single file creates a duplicate slug: GitHub appends
`-1` to the second, and every link aimed at it silently resolves to the first. That failure is
invisible to ordinary link checking, which is why
[`scripts/check-doc-links.py --no-dup-slugs`](../../scripts/check-doc-links.py) exists as its own
gate and why every translation package must run it.

| Ukrainian heading | English (pinned) | Occurrences |
|---|---|---|
| `Контекст` | **Context** | 115 |
| `Рішення` | **Decision** | 115 |
| `Наслідки` | **Consequences** | 115 |
| all eleven `Альтернативи…` / `Розглянуті…` variants above | **Alternatives considered** | 37 |
| `Пов'язані` (16) / `Пов'язане` (15) | **Related** | 31 |
| `Верифікація` | **Verification** | 3 |
| `Посилання` | **References** | 2 |
| `Відкрите` / `Відкриті питання` / `Закриті питання` | **Open questions** | 5 |

`Пов'язані` and `Пов'язане` are two spellings of the same section, split almost evenly — precisely
the shape that yields two English headings from two different batches unless pinned.

A heading that carries a qualifier the pinned form drops (`Альтернатива: hooks (відкладено)`,
`Розглянуті альтернативи: чим саме показати, що бар інший`) keeps the qualifier in its **body**, not
its title. The heading becomes `Alternatives considered`; the specificity moves to the first
sentence under it.

## Headings are sentence case

**"Open questions", not "Open Questions".** Capitalize the first word and proper nouns only.

This mirrors the rule already in force for user-facing strings
([conventions.md § Case of user-facing strings](conventions.md#case-of-user-facing-strings--sentence-case-and-one-name-per-thing)),
which no document had yet stated for *headings*. It is stated here so it can be cited.

The same applies to ADR titles: `ADR-0116: English as the documentation language`, not
`English As The Documentation Language`.

## API identifiers are never translated

`five_hour`, `seven_day`, `resets_at`, `client_id`, `utilization`, `is_active` and every other
field name from the Claude usage API keep their original form, in prose as well as in code. They
are names, not words.

## Comments inside code blocks are prose — translate them

The byte-for-byte rule for fenced blocks protects **executable content**: commands, identifiers,
paths, JSON keys, Swift, log strings, PlantUML source. A `//`, `#`, `--` or `←` comment explaining
an example is not executable — it is written for the reader, and it must be translated like any
other sentence. Leaving it Cyrillic defeats the point of translating the paragraph above it.

A string literal a script **prints for the reader** is prose too: `print('нецілих:', n)` becomes
`print('non-integer:', n)`. The reader has to understand what was printed.

**Nothing else in the block is touched.** Not the code, not the illustrated output, not values
compared against real data — including Cyrillic ones that are *data*: `"1 ГБ"`, `"Обліковий запис
Apple"`, a test fixture such as the `TOKENPACE_AWAITING_NAMES` session name that exists precisely to
exercise long non-ASCII rendering. If a line both executes and explains, only the trailing comment
is translated.

Typography inside those comments follows the prose rules: en dash in ranges (`4–6`, `10–12 px`),
`"…"` rather than `«…»`.

The sweep that finds the remaining cases ([#465](https://github.com/artem-from-ua/tokenpace/issues/465)):

```sh
python3 - <<'PY'
import subprocess, re
cyr = re.compile('[\\u0400-\\u04ff]')   # escaped, so this sweep never flags itself
for f in subprocess.run(['git', 'ls-files', '*.md'],
                        capture_output=True, text=True).stdout.split():
    fence = False
    for i, l in enumerate(open(f, encoding='utf-8'), 1):
        if l.lstrip().startswith(('```', '~~~')):
            fence = not fence
            continue
        if fence and cyr.search(l):
            print(f"{f}:{i}: {l.rstrip()[:100]}")
PY
```

It cannot tell a comment from a deliberate literal — every hit is reviewed by hand.
