---
status: accepted
date: 2026-08-14
supersedes: []
superseded_by: []
---

# ADR-0095: Ресурсний бандл шукаємо самі, а не через `Bundle.module`

> Дописано пізніше: **єдиний споживач цього рішення зник.**
> [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) перевів прев'ю стилю бару на рантайм-
> рендер, тож три PNG, ресурсний бандл і сам `BarStylePicker.resourceBundle` видалено — у
> застосунку більше немає жодного ресурсу.
>
> **Правило лишається чинним**, і ADR не витіснено: воно стосується будь-якого **майбутнього**
> ресурсу, а не лише тих картинок. Щойно ресурси знадобляться знову, читати їх треба описаним тут
> способом, а не `Bundle.module` — інакше повториться той самий креш у `.app`. Формулювання в
> [conventions.md](../reference/conventions.md) переписано в умовний спосіб саме тому.

## Контекст

Реліз 0.94.0 крешив у встановленому `.app` при відкритті `Settings → Appearance`. Crash report
(`EXC_BREAKPOINT`, головний потік) вказує на рядок, де закінчується будь-яке розслідування:

```
0  libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:)
1  TokenPace           closure #1 in variable initialization expression of static NSBundle.module
2  TokenPace           one-time initialization function for module
...
5  TokenPace           closure #1 in variable initialization expression of static BarStylePicker.images
9  TokenPace           closure #1 in closure #1 in closure #2 in BarStylePicker.tile(for:title:)
13 TokenPace           BarStylePicker.tile(for:title:)
```

Падав не наш код, а **згенерований SwiftPM аксесор** `Bundle.module`, який `BarStylePicker.images`
викликає при першому малюванні пікера стилю бару ([ADR-0093](0093-bar-style-picked-by-picture.md)).
Ось він, дослівно з `.build/…/DerivedSources/resource_bundle_accessor.swift`:

```swift
let mainPath = Bundle.main.bundleURL.appendingPathComponent("TokenPace_TokenPace.bundle").path
let buildPath = "/Users/artem/devel/cc-timer/.build/arm64-apple-macosx/debug/TokenPace_TokenPace.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else {
    Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
}
```

Обидва кандидати в реальному `.app` хибні:

- `Bundle.main.bundleURL` для застосунку — це **сам** `/Applications/TokenPace.app`, тож `mainPath`
  вказує на `/Applications/TokenPace_TokenPace.bundle`, тобто **поруч** із застосунком. Ресурси в
  `.app` так не лежать і лежати не можуть: їхнє місце — `Contents/Resources/`, куди їх і кладе
  `scripts/build-app.sh`.
- `buildPath` — абсолютний шлях у `.build/` **машини, де збирали**, ще й `debug`-конфігурації. На
  Mac користувача такого каталогу немає.

Промах обох → `fatalError`. Замір це підтверджує напряму: `Bundle(path:)` за шляхом SPM повертає
`nil`, а за фактичним шляхом у `Contents/Resources/` — відкриває бандл, і всі три PNG вантажаться
(`bar-style-{pressure,gauge,progress}`, 54×33).

Чому це доїхало до релізу: у `swift run` бандл справді лежить поруч із бінарником, тож `mainPath`
влучає, і в дев-режимі пікер працює бездоганно. Перевірка «чи скопійовано бандл у `.app`», додана
разом із ADR-0093, теж проходила — бандл **був** на місці. Хибним було припущення, що `Bundle.module`
його там шукатиме.

## Рішення

**Не використовувати `Bundle.module`.** `BarStylePicker` резолвить бандл сам —
`BarStylePicker.resourceBundle`: `Contents/Resources/` (розкладка `.app`), далі поруч із `.app`,
далі поруч із виконуваним файлом (розкладка `swift run`).

Два наслідки цього вибору:

- **Промах повертає `nil`, а не вбиває процес.** Декоративне прев'ю не має права зносити застосунок:
  без картинок плитки лишаються клікабельними, вибір стилю працює. `fatalError` у коді, що виконується
  при малюванні панелі налаштувань, — неприйнятна ціна за відсутню PNG.
- **Порядок кандидатів починається з `Contents/Resources/`** — з розкладки, у якій застосунок
  реально їде до користувачів, а не з дев-режимної.

Додатково `scripts/build-app.sh` тепер перевіряє не лише наявність каталогу бандла, а й що в ньому
**щонайменше три PNG** (по одному на `BarStyle`). Порожній каталог копіюється `cp -R` без помилки й
проявився б лише в UI.

## Наслідки

**Це стосується будь-якого майбутнього ресурсу**, не лише цих трьох картинок: щойно ресурси
знадобляться ще десь, читати їх треба тим самим шляхом, а не `Bundle.module`. Конвенція записана в
[conventions.md](../reference/conventions.md).

**Ціна — власний код замість стандартного механізму.** Перейменування таргету чи пакета змінить ім'я
бандла, і константу `"TokenPace_TokenPace.bundle"` доведеться оновити руками — `Bundle.module`
генерувався б автоматично. Це свідомий розмін: аксесор, який автоматично вказує не туди й падає,
гірший за константу, яку видно.

**Останній кандидат — `Bundle.main`.** Якщо ресурси колись покладуть плоско в сам `.app`, пошук
все одно спрацює замість того, щоб повернути `nil`.

**Що це не лагодить:** тести цього класу дефектів не ловлять у принципі — вони виконуються з
розкладкою, у якій шлях SPM влучає. Єдина перевірка, що ловить, — запуск зібраного `.app`, як і
вимагає [ui-verification.md](../guides/ui-verification.md).
