# Development conventions

## Language

- **Everything in the repository and on GitHub is English** — README, SPEC, `docs/`, ADRs,
  agent-instruction files, skills, code, identifiers, comments, commit messages, PRs, issues,
  release notes. See [ADR-0116](../adr/0116-english-as-documentation-language.md).
- API identifiers (`five_hour`, `resets_at`, `client_id`, …) keep their original form and are
  never translated. The same holds for UI strings quoted from the app.

## Stack

- **Swift** for the whole project (menu bar app, iOS/watchOS later). See
  [ADR-0001](../adr/0001-swift-stack.md).
- macOS: AppKit (`NSStatusItem`) + SwiftUI inside (`NSHostingView`).
- **Minimum target: macOS 15 Sequoia.**
- **Phase 1 build:** Swift Package Manager + a build script (bundle/sign/notarize). Xcode comes in
  Phase 2, for iOS/watchOS. See [ADR-0004](../adr/0004-build-system.md).
- **Tests:** `swift-testing` (`import Testing`, `@Test func`, `#expect(…)`) — `XCTest` is unavailable
  on Command Line Tools without a full Xcode. `swift-testing` ships with Swift 6.1 CLT.

### Resources (images and the like)

**Right now the app has no resources at all.** The three PNG previews of the bar styles were the
only ones; they are drawn at runtime
([ADR-0097](../adr/0097-bar-style-preview-rendered-at-runtime.md)), so `Package.swift` has no
`resources:` and `scripts/build-app.sh` copies nothing. The rule below stays — it is about the
**next** resource, and this is the exact mine that blew up release 0.94.0.

**Before adding a resource, ask whether it can be drawn in code instead.** An image has no way to
diverge from the code loudly: the bar style preview spent two releases showing a bar the app no
longer drew, and no test saw it.

If a resource is genuinely needed: files go in `Sources/TokenPace/Resources/`, wired up as
`resources: [.process("Resources")]`. `.process` (not `.copy`) — then they sit flat at the root of
the bundle and are reachable by their bare name. Name retina images with an `@2x` suffix: `NSImage`
then sets the correct logical size on its own.

**Reading them through `Bundle.module` is not allowed — in a `.app` it is a guaranteed crash.** The
generated SwiftPM accessor looks for the bundle at `Bundle.main.bundleURL/<name>.bundle`, i.e.
**next to** the `.app` (`/Applications/TokenPace_TokenPace.bundle`), whereas in a `.app` the
resources live inside it, in `Contents/Resources/`. The fallback path is an absolute path into the
developer's `.build/`, which does not exist on anyone else's machine. Both miss, and the accessor
calls `fatalError`. Under `swift run` the bundle really does sit next to the binary, so the defect
is invisible in dev mode — which is exactly how the crash rode all the way into release 0.94.0
([ADR-0095](../adr/0095-own-resource-bundle-lookup.md)).

Resolve the bundle yourself instead: first `Contents/Resources/`, then next to the `.app` and next
to the executable; a miss must return `nil`, not kill the process. The bundle only ends up in the
`.app` because `scripts/build-app.sh` copies it into `Contents/Resources` — and does so **before**
`codesign` (a bundle added after signing breaks the seal). The copy must be paired with a check that
the bundle is not empty: `cp -R` of an empty directory succeeds and only breaks in the UI.

**When you add a resource, verify it in the built `.app`, not only in `swift run`.**

## Git

- Branches: `<prefix>/<kebab-case>` (`feature/`, `bugfix/`, `docs/`, `refactor/` …).
- **Do not commit to `main` directly.** A PR against `main` (not stacked).
- Commit messages are in English.

### Git hooks

The hooks live in `.githooks/` (committed to the repo). Enable them locally **once** after cloning:

```sh
git config core.hooksPath .githooks
```

`pre-commit` runs three checks:

- **Swift build + test** — only when the commit touches `*.swift` / `Package.swift` (docs-only
  commits stay fast). A build or test failure blocks the commit. To get a deliberate WIP commit
  through: `TOKENPACE_SKIP_SWIFT_HOOK=1 git commit …`.
- **Documentation links** — only when the commit touches `*.md`. Runs
  `scripts/check-doc-links.py` over the **whole** corpus (not just the staged files: renaming a
  heading breaks links in files the commit never touched). To bypass:
  `TOKENPACE_SKIP_DOC_LINKS_HOOK=1 git commit …`.
- **PlantUML URL sync** — blocks the commit if a diagram's URL in a `.md` has diverged from its
  source (managed by the `plantuml` plugin; do not hand-edit between the markers).

The link validator has four more modes, needed while the docs are being migrated to English
([#441](https://github.com/artem-from-ua/tokenpace/issues/441)):

```sh
python3 scripts/check-doc-links.py --snapshot OUT     # anchor graph as JSON (a named listing)
python3 scripts/check-doc-links.py --compare OLD NEW  # what broke between two snapshots
python3 scripts/check-doc-links.py --inbound FILE     # who links to this file's anchors
python3 scripts/check-doc-links.py --no-dup-slugs     # heading slug collisions
```

**`--no-dup-slugs` is a separate mode for a reason.** Two different headings that produce the same
slug look valid to an ordinary check: GitHub appends `-1` to the second one, and a link written for
the first resolves — into the wrong section. That is exactly what happens when two Ukrainian
headings translate into one English heading, which is why every translation package is required to
run this mode separately.

## Versioning

- SemVer 2.0.0.
- **The single source of truth for the app version** is the `VERSION` file at the repository root
  (`CFBundleShortVersionString`). Starting point: `0.1.0`. The build number is the git commit count
  (`git rev-list --count HEAD`). `TokenPaceKit.version` in the code duplicates the value from
  `VERSION` and is updated along with it.

## UI design (AppKit + SwiftUI)

- **The goal: follow the design of native macOS apps as closely as possible** (System Settings above
  all). For standard system elements — **zero hardcoded** sizes, fonts, insets or colors; use the
  system mechanisms (semantic `NSColor`, `NSFont.systemFontSize`/text styles, `NSSwitch.controlSize`,
  `NSStackView.firstBaseline`, `NSPathControl` and so on).
- **The Settings window is SwiftUI** — `Form { Section }.formStyle(.grouped)` + `NavigationSplitView`,
  embedded in an `NSWindow` through `NSHostingController` (ADR-0042, #168) — just like System
  Settings itself. The grouped-inset cards, the chip and the time picker are **no longer** hand-rolled
  AppKit exceptions: row height/padding/corner radius/dividers, the grouped background and the rounded
  `DatePicker` all come from the system without a single constant. There used to be measured constants
  here (`SettingsCard` and friends) — they are gone. **The menu bar widget and the popup remain
  AppKit** (see ADR-0009/0021/0022) — but **both surfaces now draw with system semantic colors**
  (the `labelColor` family + `.system*`; menu bar — ADR-0059, popup — ADR-0060), not fixed sRGB. The
  exception is the popup's Claude brand accent (`popupClaudeBrand`), which stays sRGB.
- **Before a PR, check both themes (light+dark) and every state** (sidebar icon size, dev build /
  `.app`) with screenshots. The full breakdown, the measurement method and the usual mistakes are in
  [system-settings-parity.md](system-settings-parity.md); the governing decisions are ADR-0040 (zero
  hardcode) and ADR-0042 (SwiftUI Form for Settings).
- **Before committing a UI change (menu bar popup, windows, any AppKit screen) — check it against the
  current Apple Human Interface Guidelines**
  (developer.apple.com/design/human-interface-guidelines). Do not assert HIG details from memory —
  the HIG site is an SPA and often resists a direct `WebFetch`; when it does, search via WebSearch for
  official Apple Developer pages and forums rather than community sources, and state the limits of
  your confidence honestly when no exact official number turns up (see ADR-0021 — an example of such
  a search, for the Troubleshoot window's typography).
- **Find out the canonical way to build an element first — then write the code.** The HIG rule above
  is about *appearance*; this one is about *construction*. Before building a custom UI element (a
  labeled plate, a badge, a chip, a custom row), find the mechanism AppKit provides for it: search
  Apple Developer Forums / the documentation / Stack Overflow / `r/macdev` for the element's name +
  "proper way"/"best practice". **That is cheaper than any number of trial-and-error iterations.**
  - **The symptom that you are doing the wrong thing:** you find yourself computing text positions by
    hand, compensating for rounding, eyeballing constants, or chasing sub-pixel offsets. The standard
    mechanism needs none of that — the framework resolves the rounding itself.
  - **An example from this repository** (#158 follow-up, the blocking-reset badge): the insets inside
    the plate were done first with constraints on a nested `NSTextField`, then by drawing the string
    by hand — and both times the text "floated" when the string changed under ⌥, because the field
    rounds its own width to the backing pixel and the remainder gets split by centering. The canonical
    answer is an **`NSTextFieldCell` subclass with `drawingRect(forBounds:)`**: one text entity, with
    AppKit applying the insets itself (see `PillView`/`PillCell`). Six iterations of guessing → one
    search.
  - **Measure in the pixels of the rendered image, not in the math.** Arguments of the form "by the
    formula this is zero" systematically disagreed with what was on screen: a difference of 0.2–0.4 pt
    vanishes under rasterization, whereas the real error was 6 pt. Example scripts —
    `scripts/check-badge-column.swift`.
  - **Measure the element in its real surroundings, not on its own.** The same badge, measured solo,
    reported identical numbers for three different alignments; inside an `NSStackView` row, where its
    width is dictated by `edgeInsets`, left alignment produced **9 px** of skew and centering produced
    1 px. A test rig that reproduces a component without its container will confirm any hypothesis you
    bring it.
  - **System controls have hidden insets of their own — your constant is not what lands on screen.**
    `NSTextFieldCell` reserves ~4.5 pt on each side on top of whatever you set through
    `drawingRect(forBounds:)`: `hInset = 6` rendered as 10.5 pt of air, and the badge looked bloated.
    Before you start guessing at a number, measure the "constant → rendered pixels" relationship
    across a range of values; it is usually linear with an offset, and the offset is the thing you
    need to know.
- **One point size and one typeface for the whole dropdown popup**, with weight (bold/regular) the
  only axis distinguishing headings from ordinary text. Do not eyeball the size of a custom
  `NSTextField` against a native `NSMenuItem` — there is no reliable way to *read* the actual size
  AppKit uses to draw `NSMenuItem.title` (a side effect of the Big Sur+ redesign;
  `NSFont.menuFont(ofSize:)` does not match the render). Instead of guessing — **one shared
  constructor** (`dropdownTextSize` in `PopupViewController.swift`) that sets the font explicitly on
  both the custom labels and the native menu items (via `NSMenuItem.attributedTitle`), so a divergence
  is structurally impossible. See ADR-0021.

### Case of user-facing strings — sentence case, and one name per thing

This covers **everything the user sees**: Settings, the popup, the status item's menu, notifications,
window titles. HIG does not mandate a particular case — it demands **consistency within an element
type** ([HIG · Writing](https://developer.apple.com/design/human-interface-guidelines/writing)), and
the app already has that consistency: `Usage history`, `Monitored services`, `Settings…`,
`Development tools…`, `Back to work!`. The rule is written down here not to change anything but to
keep the drift from starting again: before
[#416](https://github.com/artem-from-ua/tokenpace/issues/416) the convention existed only as a habit,
so three buttons (`Check Now`, `Update Now`, `Archive Now`) sat in Title Case for years and nobody
noticed.

**Writing a new string — sentence case**, capital on the first letter and proper nouns only. Three
kinds of exception, each of them deliberate rather than an oversight:

- **Proper nouns** — `TokenPace`, `Claude`, `Claude Usage API`, `Finder`, the names of the bar styles
  (`Pressure`/`Balance`/`Progress`, sourced from `BarStyle.displayName`).
- **macOS system phrases** — quoted in the spelling the system uses: `Open in Finder` is exactly how
  it appears in Finder's context menu, and "fixing" it to `Open in finder` would make our action look
  unlike the system one.
- **An inline link inside a sentence** — `release notes` in About stays lowercase: it is not an action
  button but words in a sentence that happen to be clickable (`.buttonStyle(.link)`).

**Naming an element of another surface — take its name from the single source, not from memory.** A
Settings string that mentions a dropdown section must spell it exactly the way the dropdown itself
does. The canonical example is `Extra usage`: the source is
`PopupViewController.extraUsageTitle`, italicized in Settings (`*Extra usage*`), because it is a name
and not a description ([ADR-0114](../adr/0114-extra-usage-is-one-name.md)). The italics require
`Text(.init(_:))` — a plain `Text(String)` will print the asterisks literally; `SettingsHint` and
`SettingsDisabledLabel` know how to do this, but **a `Toggle`'s hidden label stays unmarked**, because
VoiceOver reads it and would pronounce the asterisks.

The same goes for text duplicated between targets: the notification title lives in
`ExtraUsageOnset.bannerTitle` (Kit), and `BackToWorkNotifier` **reads** it rather than repeating it as
a literal. Same seam as `CopyFeedback` below — a constant duplicated across it will inevitably
diverge.

### Copy-to-clipboard buttons — shared behavior (`CopyFeedback`)

Writing to the clipboard is **invisible**: nothing changes on screen and there is no system
confirmation. So every copy button swaps its glyph for a `checkmark` for ~1.2 s and then swaps it
back. The constants — glyphs, duration, accessibility labels — live in `CopyFeedback` (Kit), because
the buttons are built with different toolkits (`AppearancePane` is SwiftUI,
`TroubleshootWindowController` is AppKit), and a constant duplicated across that seam will inevitably
diverge.

**Adding a new copy button — take the glyphs and the duration from there**, not from a number of your
own. For AppKit, do not forget `setButtonType(.momentaryPushIn)`: `.momentaryChange` restores the
image on mouse-up and wipes out the checkmark.

### Config export: key order = the order of the controls in the pane

The "Copy Appearance settings to clipboard" button (Settings → Appearance, #257) produces JSON in
which the keys inside the `appearance` block run **in the same top-to-bottom order as the controls on
the Appearance page** — not alphabetically and not in the order of the struct's fields. The dump gets
read with the pane in front of you: matching the order gives you a line-for-line correspondence.

**The structure is nested by surface** (since
[#381](https://github.com/artem-from-ua/cc-timer/issues/381),
[ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md); before that all seven keys
sat in a flat list). Two groups in the order of the child pages, each with its own keys in control
order, and the keys inside a group carry **no surface prefix** — the group already provides it, so
`menuBar.style` in `UserDefaults` is `"style"` inside `"menuBar"` in the dump:

```json
{
  "appVersion" : "…",
  "preset" : "workHarder",
  "appearance" : {
    "menuBar" : {
      "style" : "…",
      "colorsTell" : "…",
      "hideTop5hBar" : "…",
      "showServiceStatusDot" : true
    },
    "dropdown" : {
      "style" : "…",
      "showPerModelLimits" : "…",
      "showExtraUsage" : "…"
    }
  }
}
```

**Adding an Appearance option — insert its key at the position matching the control's place in the
pane, and inside its own group.** Do not append it at the end and do not sort. Three lists have to
stay in sync:

1. [`AppearancePanes.swift`](../../Sources/TokenPace/Settings/AppearancePanes.swift) — the control
   itself (the file was called `UIPanes.swift` before
   [#381](https://github.com/artem-from-ua/cc-timer/issues/381));
2. [`AppearanceConfigExport`](../../Sources/TokenPaceKit/AppearanceConfigExport.swift) —
   `json(values:preset:appVersion:)` (the `menuBar` / `dropdown` arrays that emit the lines) and
   `MenuBarKeys` / `DropdownKeys` in the same file;
3. `AppearanceConfigExportTests.paneOrderedGroups` — the reference that guards the order (the flat
   `paneOrderedKeys` is derived from it as `"<group>.<key>"`).

The order **cannot** be delegated to `Codable`/`JSONEncoder`/`JSONSerialization`: a keyed container
sits on top of an unordered dictionary, so the key order differs **between runs of the same binary**.
The only determinism they offer is `.sortedKeys`, i.e. alphabetical. That is why
`AppearanceConfigExport` emits the text directly, and `Codable` is kept only for reading it back
(round-trip).

## Security

- **Never commit tokens or credentials.** `.credentials.json` and `secrets/` are in `.gitignore`.
- Do not log the token, do not show it in the UI, do not let it leave the Mac.

## Logging

- All logging goes through the `AppLogger` facade (`os.Logger`), subsystem `com.artem-n.tokenpace`,
  categories `network`/`keychain`/`lifecycle`/`ui`. Do not pre-format messages into a `String` — keep
  `os.Logger`'s compile-time interpolation with per-argument privacy.
- **Never log secrets** (OAuth tokens, Keychain payloads). Mark only safe diagnostic fields with
  `, privacy: .public`; everything else is redacted as `<private>` by default.
- **`docs/log-messages.md` is the catalog of every log message.** Any change to logging (a new call,
  a removal, a change to a message's text or its level/category) updates the corresponding line in
  `docs/log-messages.md` **in the same commit** — line numbers and summary counters included.
- **How to read the logs (methods and gotchas)** — see
  [log-messages.md → Collecting logs](log-messages.md#collecting-logs--methods--gotchas). The main
  gotcha: `.notice`/`.info` are **not** written to the store, so `log show` will not show them — you
  need `log stream … --level debug` (without `--level debug` only `.error` is visible). This applies
  to signed release builds too (they log the same way).

## Verification env variables

The `TOKENPACE_*` family switches the app into manual-verification modes. **Never set them in a normal
run** — they are all for diagnostics, screenshots or walking a UI flow.

- **`TOKENPACE_STUB`** = `1` / `screenshot` / `error` / … — replaces the live `URLSession` with a
  canned transport (`StubUsageTransport`), so the app runs end-to-end without the usage/status API and
  without the Keychain (`1` — rising utilization; `screenshot` — a frozen frame for the README;
  `error` — 401 + degraded services). The full list of stubs (idle, pacing frames, calm-both and so
  on) is in [ui-verification.md](../guides/ui-verification.md).
- **`TOKENPACE_GH_AUTH`** (a presence flag — any non-empty value) — enables the `gh` route for the
  update check (`GHReleaseFetcher`): `gh api …/releases/latest` as a subprocess, with `gh` taking the
  token from the keyring. For maintainers, while the repo is private; without the variable it is
  anonymous HTTPS (ADR-0025). It has its own login-shell resolver, `AppDelegate.resolveGHAuth`: first
  `ProcessInfo` (terminal / `launchctl setenv`), and if it is not there, from `~/.zshrc`/`~/.zprofile`
  through `ShellEnvironment` (`zsh -l -i`), because the app often starts via launchd (login / Finder /
  Dock) **without a shell**, where `export …` is invisible to `ProcessInfo`. So `export
  TOKENPACE_GH_AUTH=1` in `~/.zshrc` is enough — it works in the notarized `.app` launched from Finder
  or at login too. No `launchctl setenv` or LaunchAgent needed.

> **Dev tools are not enabled through an env variable.** The ⌥ item "Development tools…" — and with it
> the stub selector (#187) and the payload-log checkbox (#279) — are gated by a `UserDefaults` key:
> `defaults write com.artem-n.tokenpace devToolsEnabled -bool true`.
> The key is only read in an **installed `.app`** (bundle id → the correct `UserDefaults` domain);
> under `swift run` the binary has no bundle id → a different domain, so the key has no effect there
> (ADR-0053).
- **`TOKENPACE_FAKE_LATEST`** = `vX.Y.Z` — forces a canned "latest release" (`StubUpdateFetcher`)
  with no network, to exercise the "update available" / "up to date" branches. Takes priority over
  `TOKENPACE_GH_AUTH` (ADR-0025).
- **`TOKENPACE_SKIP_SWIFT_HOOK`** = `1` — bypasses the Swift build/test in the pre-commit hook (for a
  deliberate WIP commit).
- **`TOKENPACE_SKIP_DOC_LINKS_HOOK`** = `1` — bypasses the doc link check in the pre-commit hook (for
  a deliberate WIP commit with a knowingly broken link).

> **UserNotifications and how the bundle is launched.** The update check's system banner only works in
> a signed, installed `.app` launched through LaunchServices (`open`), **not** by invoking the binary
> `…/Contents/MacOS/TokenPace` directly — `UNUserNotificationCenter`'s completion handlers run on a
> non-main queue, so any `@MainActor`-isolated code inside them dies with `SIGTRAP`
> (`dispatch_assert_queue`). Log from such handlers only through `nonisolated` helpers (ADR-0025).

## Documentation as part of the code

- A module changes → update `docs/architecture.md`.
- Logging changes → update `docs/log-messages.md` (see the "Logging" section).
- A decision between two approaches → a new ADR in `docs/adr/`. Creating one, or superseding an
  existing one, follows [writing-adrs.md](../guides/writing-adrs.md) — the numbering, the
  frontmatter, the postscript, and the one-row index entry it must produce.
- A new convention or tool → update this file.

### Comments are priced per read

**Length is a cost, not a virtue** ([ADR-0122](../adr/0122-comments-are-read-every-session.md)).
Comments are 47% of the lines under `Sources/` and **64% of the bytes** — ~312 000 tokens against
~172 000 of code. Every session that opens a file pays for all of it, usually while looking for
something else: `PacingModel.swift` is 82% comment, `MenuBarLayout.swift` 78%. Write the shortest
comment that answers what the next editor must know.

**Deleting beats rewording.** A pass over 37 sites that rewrote history into the present tense
while preserving length changed total volume by ~0.05%. The win is in paragraphs removed.

**Origin stories go outright.** Where the code came from — a bash prototype, an earlier module —
cannot be acted on: `PacingModel.elapsedFraction` cited `statusline.sh` lines 266–287, and that
file exists neither in the repo nor in its git history. Keep the boundary rules such a comment
states; drop the provenance around them.

### Comments and docs are written in the present tense

**A comment states what holds now and what the next editor must not break — not what the code used
to do.** The past tense arrives honestly: a comment written *during* a change explains it as "this
used to be X", which is commit-message language. The commit passes; the sentence stays, and it
becomes a third copy of a fact already held by git history and, usually, by an ADR. Copies drift —
that is how the ADR index came to spell one status eleven ways
([#488](https://github.com/artem-from-ua/tokenpace/pull/488)).

When you catch yourself writing *used to* / *previously* / *was removed*, **rewrite the sentence in
the present tense**:

- A fact survives → keep the fact, drop the history. "Both used to start at x=0, so a 9-pt dot and a
  15-pt glyph had centres 3 pt apart" → "Starting both at x=0 would leave a 9-pt dot and a 15-pt
  glyph with centres 3 pt apart." Same length, and it now warns instead of reminiscing.
- Nothing survives → drop the sentence. A rejected alternative belongs in the ADR that rejected it.

### An ADR reference is a footnote, not the explanation

**Write the reason so it stands on its own; the `ADR-NNNN` after it is where to read more, never
what makes the sentence mean something.** "Centred on the dot's axis (ADR-0094)" tells the next
editor nothing they can act on. "A 9 pt dot and a 15 pt glyph put their centres 3 pt apart, enough
to read as a misaligned column" is checkable against the code, and stays true whatever the ADR
corpus does next.

That last part is the point. ADRs get superseded, often in pieces — 0027 by six later records, 0009
and 0020 in part, 0013 and 0086 in full — and **nothing warns a comment that its citation moved**.
This codebase already carries 45 references to fully superseded ADRs and over a hundred to
partially superseded ones. A comment leaning on the link is wrong the moment that happens and gives
no sign; a comment carrying its own reason merely loses a convenience.

The one thing always worth writing is the case where **the obvious move is wrong and the code cannot
show it** — `setButtonType(.momentaryPushIn)`, because `.momentaryChange` restores the image on
mouse-up and silently wipes the checkmark. That is a warning, not a memory.
