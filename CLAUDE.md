# CLAUDE.md

Instructions for Claude Code (and other AI agents) working in this repository.

## What this project is

`TokenPace` is a macOS menu bar mini-widget showing Claude Code subscription limit usage
(the 5-hour and 7-day windows) with *pacing* and the time to the nearest reset. Later come the
iPhone widgets and an Apple Watch complication.

**Sources of truth (read before working):**

- [SPEC.md](SPEC.md) — the full product spec: architecture, UI, behavior, Phase 1 scope, work plan.
- [docs/architecture.md](docs/architecture.md) — architecture and data flow.
- [docs/conventions.md](docs/reference/conventions.md) — development conventions.
- [docs/adr/](docs/adr/) — architectural decisions (Swift, documentation language, closed-source agent, build).

## Language

- **Everything in the repository and on GitHub is English** — README, SPEC, `docs/`, ADRs, this
  file, skills, code, identifiers, commit messages, PRs, issues, comments, release notes. See
  [ADR-0116](docs/adr/0116-english-as-documentation-language.md).
- API identifiers (`five_hour`, `resets_at`, `client_id`) keep their original form and are never
  translated.
- A few Ukrainian fragments survive on purpose: [ADR-0002](docs/adr/0002-ukrainian-documentation.md)
  as an immutable record, the glossary's source column, test fixtures, and quoted strings that are
  data rather than prose (a localized macOS pane title, a command the maintainer actually types).

## Stack and build

- **Swift 6.1+**, minimum target **macOS 15 Sequoia**.
- Phase 1: **Swift Package Manager** + a build script (`.app` bundle, optional signing/notarization).
  A full Xcode is not needed — `swift build` / `swift run` work with the Command Line Tools.
- macOS UI: AppKit `NSStatusItem` with custom drawing (not `MenuBarExtra`).
- Phase 2 (iOS/watchOS): an Xcode project gets added. See [ADR-0004](docs/adr/0004-build-system.md).

## Commands

```sh
swift build        # build
swift test         # unit tests (PacingModel, time parsing/formatting, backoff)
swift run          # run
```

## Logs — read them RIGHT (don't hammer the wrong ones)

**Before any `log` command, read the "Collecting logs — methods & gotchas" section in
[log-messages.md](docs/reference/log-messages.md)** — the commands, the patterns and the traps are
there. This is the most common trap in this project: nearly all our lines are `.notice`/`.info`, and
those **are not written to the persistent store**.

- **`log show` does NOT show `.notice`/`.info`/`.debug`** — only `.error`/`.fault`. An empty
  `log show` does **not** mean "the app isn't logging". Don't draw that conclusion.
- **A live stream is the default, and `--level debug` is MANDATORY** — without it you only see `.error`.
- **Launch-time / one-shot events** (the first poll, edge detection, a migration): bring the stream
  up **first**, then launch the app — otherwise the event happens before the stream attaches.

## Statistics from the journal — read the reference before processing

**Before any count over `usage-journal-*.jsonl` (yours or one provided by another user), open
[docs/reference/journal-analysis.md](docs/reference/journal-analysis.md)** — the line format, the
resolution limits, the processing traps and the significance requirements. Naive journal parsing
yields numbers that look convincing and are wrong: doubled resets, a crash on an empty `reset`,
quantized durations, the session-stitching threshold as a hidden parameter.

**The bar for a signal in Insights/Notifications is the same one as in the menu bar** (the "is there
an action the user would take differently" test from
[users-and-goals.md](docs/reference/users-and-goals.md)); for notifications it is **higher**, because
they arrive on their own and interrupt work.

To start such a session from scratch, use the **`/journal-insights`** skill
([`.claude/skills/journal-insights/`](.claude/skills/journal-insights/SKILL.md)): it computes the
series profile and then answers your questions about that data. An overview report and an artifact
happen by separate agreement, not by default.

## Colors: no screenshot gives trustworthy RGB — measure with Digital Color Meter

**Before any color comparison or calibration, open
[ui-verification.md § "Testing menu-bar widget colors"](docs/guides/ui-verification.md#testing-menu-bar-widget-colors-swatch-mode--color-picker)** —
the method, the target values, the swatch mode.

- **No screenshot — ours, sent to us, from any source — is a source of color.** macOS applies color
  management, so a pixel in a PNG is not what is on the screen. Do not calibrate against a pixel
  measured from a screenshot: that has already cost a session hours of false calibration.
- **The source of truth is Digital Color Meter** in **sRGB** mode; compare TARGET and RENDER in the
  same space.
- **Capture the real menu bar, not a window** (full screen + crop the top strip). Transparency and
  vibrancy against the wallpaper are visible only there; vibrant surfaces draw their own material,
  not `windowBackgroundColor`.

## Layout bugs in windows: measure before hypothesizing

- **Probe the live tree first, theorize second** — and no programmatic resizing of the user's window
  during diagnosis. The rules and the probe template are in
  [agent-workflow.md § "Diagnosing window layout bugs"](docs/guides/agent-workflow.md#diagnosing-window-layout-bugs).
- **SwiftUI behaving strangely near window chrome → check the hosting boundary first**
  (`sizingOptions`/`safeAreaRegions`), not the SwiftUI modifiers —
  [ADR-0088](docs/adr/0088-settings-hosting-safe-area-and-manual-separator.md).

## 🚫 Prohibitions that must not be violated (the full text lives here, not in the guide)

These rules used to live only in [agent-workflow.md](docs/guides/agent-workflow.md). **That is
exactly why they got violated:** files under `docs/` are not loaded into context automatically —
CLAUDE.md only linked to them, so at the moment a hand reached for `pkill`, the prohibition was
physically not in front of it. Now it is here. The guide remains the detail and the history; **the
text in force is this one**.

### App processes

- **🚫 Never `pkill` / `killall` / `pgrep … | kill` for TokenPace.** Not by name, not by path, not
  "precisely by the one PID from pgrep". The maintainer runs a **notarized copy from
  `/Applications`**, and any such call takes it down along with your build; a pattern by name kills
  his `log stream` too.
- **✅ Instead — launch with the PID saved and stop only by that PID:**
  ```sh
  TOKENPACE_STUB=<name> swift run & echo $! > /tmp/tp-dev.pid
  kill "$(cat /tmp/tp-dev.pid)" && rm -f /tmp/tp-dev.pid
  ```
  **No PID saved → nothing may be stopped.** Several TokenPace icons in the bar are expected and
  normal; launch one more instance or ask the maintainer to close the extra ones.
- **The rule is about the TARGET, not the mechanism.** A tidy way to hit someone else's process is
  still hitting someone else's process. "It gets in the way of automation", "so only one is left",
  "just for a second, then I'll bring it back" — these are not exceptions, they are a description of
  how the rule gets violated.
- **Launched it "for the maintainer to look at" — don't stop it and don't restart it** until he says
  "seen it". At that moment even your own process is **someone else's verification instrument**.
- **✅ The one exception:** the maintainer himself asks to reinstall / update / restart the installed
  copy ("reinstall it", "update my copy", "put a fresh build in"). Then the whole chain is allowed:
  stop the old one by PID, replace the bundle, launch the new one. The permission covers **that
  request**, not the session.
- **🚫 Never build a dev `.app` into `/Applications`** on your own initiative.

### Logs

- **🚫 Don't start your own `log stream` competing with the maintainer's.** For your own diagnosis,
  use `log show --last <window>`.
- **Write `/usr/bin/log`, never `log`.** The zsh function `log` in the maintainer's profile shadows
  the binary and fails with `too many arguments`.
- **`log show` does NOT show `.notice`/`.info`/`.debug`** — only `.error`/`.fault`. Empty output ≠
  "the app isn't logging". For a live stream `--level debug` is mandatory.

### Settings

- **🚫 Never `defaults delete` on the app's domain.** It wipes the maintainer's real settings and
  looks like a save bug.
- **The domains differ:** `swift run` writes to **`TokenPace`**, the installed copy to
  **`com.artem-n.tokenpace`**. Don't mix them up, and don't pin a setting via `-key value` at launch
  — the control in Settings will look broken.

### Git

- **🚫 Don't commit or push to `main` directly** — only a feature branch (`<prefix>/<kebab>`) + a PR
  against `main`, not stacked.
- **🚫 Don't delete branches/worktrees this session didn't create.** Before deleting your own, prove
  the changes are in `main`: `git diff <branch> origin/main` must be **empty**.

## Critical rules

- **Never commit tokens/credentials.** The token lives in the macOS Keychain
  (`Claude Code-credentials`); it **never leaves the Mac**. Don't log it, don't show it in the UI.
- **The `User-Agent: claude-code/<version>` header is mandatory** on every request to
  `GET /api/oauth/usage` — otherwise an aggressive rate limit (429).
- **Don't commit to `main` directly.** Work goes through feature branches (`<prefix>/<kebab>`) and a
  PR against `main` (not stacked).
- **Docs are part of the code.** A module changed → update `docs/architecture.md`; a new decision
  between approaches → a new ADR; **a logging change** (a call added/removed, different message
  text, a different level or category) → update `docs/log-messages.md` in the same commit.
- **A PR without docs doesn't get merged — stop and say so.** Before opening a PR or merging one,
  check whether the change touches anything on the list above (a module, a decision between
  approaches, logging, UI string names, verification scenarios). If it does and the diff has no docs
  — **stop and tell the maintainer**, instead of merging with "docs later" in mind. A separate docs
  PR after the merge breaks atomicity: `main` keeps a commit where code and docs disagree, and
  nothing signals it. Proceeding without docs takes the maintainer's explicit word in this session.
- **Don't assert from memory** facts about external APIs/tools — verify them (curl/--help/docs).
- **`gh release create` runs only after the maintainer's explicit go-ahead.** A direct instruction to publish this release — "релізь", "make release", "publish the release" or equivalent — is required each time. Building, notarizing, tagging and drafting release notes may proceed without it, but the actual `gh release create` waits for that explicit word. This is separate from and additional to the `RELEASE_NOTES_APPROVED=1` notes-approval gate (that gate guards the notes; this rule guards the act of publishing).

## Workflow

Phase 1 work is split into tickets (an Epic + child issues, a GitHub Project). Execution goes **one
ticket per separate session**, in the recommended order (see the Epic / the plan in `SPEC.md`).

## Actions the maintainer's parallel work disrupts — warn before and after

Screenshotting a window, AX navigation over the running app, changing system settings, any command
that depends on GUI state — all of it breaks if the maintainer happens to be moving the mouse,
switching windows or closing the very thing being captured. He cannot guess when that moment has
arrived.

- **Before such an action — warn explicitly and wait:** say in one line what is about to happen and
  ask him not to touch the screen/mouse for a few seconds.
- **Right after — say he can carry on.** Without that the maintainer stays blocked and doesn't know
  whether he is free yet.
- This applies **only** to actions that genuinely depend on GUI state. Builds, tests, git, editing
  files need neither a warning nor an all-clear.

## UI verification before a PR

- **Don't open a PR until the maintainer has checked the change live** — on stubs (`TOKENPACE_STUB=…`)
  and/or on real data. A PR comes only after his confirmation.
- **Screenshots from temporary dev-only code do NOT count as verification** (a synthetic render
  proves the drawing logic alone, not that it works in the live widget/Settings/data flow).
- **Docs and ADRs are written AFTER the maintainer has seen the feature live.** The order is: code →
  `swift build`/`swift test` → **screenshots to the maintainer** → his confirmation → docs/ADR → PR.
  Writing an ADR before the confirmation is wasted work: if the behavior changes, it is not just the
  code that has to be rewritten but the rationale for the decision too.
- **🚫 Never launch the notarized copy without `TOKENPACE_JOURNAL_FILE`.** Features that depend on
  the signature (launch-at-login/SMAppService, automatic update installation) don't work under
  `swift run` — they are checked on the `.app` from `/Applications`. Without that variable a test
  run writes into the maintainer's **real** journal (the file without the `-dev` suffix — the very
  one used in production work), and corrupted data can't be rolled back:
  ```sh
  TOKENPACE_JOURNAL_FILE=/tmp/tp-test.jsonl /Applications/TokenPace.app/Contents/MacOS/TokenPace
  ```
- The working cycle: commit to a feature branch → `swift build` → **hand it to the maintainer** →
  confirmation → PR.

The list of stubs, the scenarios without a stub and the command details are in
[ui-verification.md](docs/guides/ui-verification.md).
**Adding a feature with a state of its own — add a stub and update that list.**

## Analyzing proposals and mockups outside the app

This covers everything that describes or depicts the UI **outside the app itself**: artifacts,
mockups, issue comments, reviews of other people's proposals, design notes.

- **Drawing UI — open [ui-state-truth.md](docs/reference/ui-state-truth.md) before rendering.** It
  has the metrics of both surfaces (they differ — don't take numbers "in general"), the anatomy of
  the bar, the table of **impossible combinations** and the requirement to render icons as real SF
  Symbols rather than emoji. A render of a nonexistent state makes the whole analysis around it
  false, even when the text is right.
- **Claiming something about behavior — quote the line of code**, not "it looks like it does X". The
  order of the branches decides as much as their contents, and a property's name is not proof — it
  is often a conjunction with live data ([the rule and
  examples](docs/reference/ui-state-truth.md#claiming-something-about-behavior--quote-the-line-of-code)).
- **Motivating a change by a user need — check it against
  [users-and-goals.md](docs/reference/users-and-goals.md)**: the "is there an action the user would
  take differently" test, examples of signals that fail it, and the list of what the user **already
  controls himself**. Before proposing to "remove X", check whether the switch isn't already right
  where that very value is set.
- **Every mention of a ticket, PR, commit, file or ADR is a hyperlink**
  ([the table of targets and the check script](docs/reference/ui-state-truth.md#every-mention-is-a-hyperlink)).
  The easiest ones to miss are those sitting right after a tag (`<div>#283`). **The exception is the
  `Closes #NNN` line in a PR body:** GitHub triggers auto-closing only on a bare number, so a link
  there quietly breaks it.

The principle running through all of it: **a value is the model's input, the color and the verdict
are its output** ([users-and-goals.md](docs/reference/users-and-goals.md)). Proposals to raise the
weight of the input (a fill by level, the remainder in severity, primary ink on the percentage) come
up regularly and fall for that same reason.

## Release notes style

**NEVER compose release notes from memory.** Before writing the notes you **must open and read**
[docs/guides/releasing.md](docs/guides/releasing.md) (the "Release notes: content and style"
section) — the canonical rules are there, not in memory and not in this file. The key points from
it:

- **The canonical installation path is auto-update** (Settings → About → "Check for updates
  periodically" + "Install updates automatically"), so that subsequent releases arrive on their own.
  The manual zip is only a **short fallback** for those installing for the first time.
- Cover everything since the last GitHub release without mentioning the intermediate versions; merge
  related features.
- **The generated notes must be shown to the maintainer for approval before publishing.**

Publishing a release is guarded by a hook (`.claude/hooks/release-notes-guard.sh`): it blocks
`gh release create` until the command is run with the `RELEASE_NOTES_APPROVED=1` prefix, which is
added **only** after the maintainer has approved the notes.
