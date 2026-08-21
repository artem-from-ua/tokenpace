# AI agent workflow

Operational rules for an AI agent (Claude Code and others) working in this repository. This
supplements the critical rules in [../../CLAUDE.md](../../CLAUDE.md): what follows are the concrete
working habits collected from session experience. Secrets and specific identifiers (Apple ID, GitHub
Project node IDs and the like) are **deliberately absent** here — they don't belong in the repository.

"Maintainer" below means the repository owner, who runs the app and verifies changes live.

> ## ⚠️ The outright prohibitions live in CLAUDE.md, not here
>
> The categorical "never do X" rules (`pkill` on TokenPace, `defaults delete` on the domain, a dev
> `.app` in `/Applications`, a competing `log stream`, committing to `main`) were moved into
> [§ "Prohibitions that must not be broken"](../../CLAUDE.md) — and that wasn't cosmetic.
>
> **Files under `docs/` are not loaded into context automatically.** While the prohibitions lived
> only here, CLAUDE.md merely linked to them, and at the moment of acting the agent could not see
> them — that is exactly how session 2026-08-17 ran `pkill -f "TokenPace"` three times and took down
> the maintainer's notarized copy. The prohibition had been read at the start of the session and
> still failed to fire, because it was **not where the decision gets made**.
>
> So: **the text of the prohibitions that still stands is in CLAUDE.md.** What remains here is the
> detail, the rationale and the history of violations (valuable as an explanation of *why*). When you
> add a new prohibition, write it in CLAUDE.md and expand on it here if needed.

## Branches, PRs and syncing main

- **Never commit directly to `main`.** Work goes through feature branches (`<prefix>/<kebab>`,
  prefixes: `feature` / `bugfix` / `hotfix` / `release` / `docs` / `test` / `chore` / `refactor`) and
  a PR against `main`. **Not stacked** — every PR targets `main`, never another feature branch.
- **Before `gh pr create`, check whether `main` has moved.** `git fetch origin main`; if `main` has
  advanced past the branch's merge base — **rebase onto `origin/main` and resolve the conflicts
  before the PR**, don't open a PR against a stale base.
- **Semantic collisions git will not flag as conflicts:** two branches that add **the same next ADR
  number** (or migration index) have to be renumbered — even when they merge cleanly.
- **Syncing the local `main`** (when it has fallen behind `origin/main`): **fast-forward only**
  (`git merge --ff-only origin/main`), only with a **clean tree**, and **only in the main checkout** —
  never auto-pull inside a worktree (an automatic pull on a feature branch mid-work can produce a
  merge commit or a conflict on top of uncommitted changes). If a fast-forward isn't possible, or the
  tree is dirty — stop and report, don't merge or stash automatically.

## Worktrees

Background sessions are isolated in a git worktree (`EnterWorktree`). Three rough edges, all cured by
discipline rather than configuration:

1. **Ugly branch name.** `EnterWorktree` takes `feature/foo`, adds a prefix and replaces `/`→`+` →
   `worktree-feature+foo`. Rename the branch to the convention immediately after entering:
   `git branch -m feature/foo`.
2. **Edit/Write are blocked in the main checkout** while a background session is isolated. So **run
   every merge/rebase inside the worktree** (where Edit works), then fast-forward `main` / push the
   branch. Don't drive a conflict-prone git operation from the main checkout during a background
   session.

   **The most frequent session mistake is an absolute path into the main checkout.** An `Edit` with
   `/Users/…/devel/cc-timer/docs/…` gets rejected ("Edit the worktree copy of this file instead of
   the shared-checkout path"), because the file has to be edited in
   `/Users/…/devel/cc-timer/.claude/worktrees/<name>/docs/…`. The trap is that **reading succeeds**:
   `grep`/`sed` with a short path resolve against cwd (= the worktree), while `Edit` gets an absolute
   path from memory — and that one points elsewhere. Measured across every session in this project,
   there have been **47** such rejections. The cure: in `Edit`/`Write`, take the path **from the
   output of the preceding `grep`/`Read`**, not from memory; when in doubt, run
   `git rev-parse --show-toplevel`.
3. **`gh pr merge --delete-branch` fails AFTER the merge — and leaves the remote branch behind.** In a
   worktree, `main` is already checked out by the main checkout, and `--delete-branch` also deletes the
   **local** branch, for which `gh` must first switch to the base. Git refuses ("main is already used
   by worktree"), `gh` dies — but **the merge on GitHub has already gone through**. The error looks as
   if the merge failed; do not re-run it. Do this instead:
   ```sh
   gh pr merge <N> --squash                    # without --delete-branch
   gh pr view <N> --json state --jq .state     # confirm: MERGED
   git push origin --delete <branch>           # delete the remote branch yourself
   ```
   If `--delete-branch` was already passed and you see the error — **check `gh pr view` first**: the
   merge almost certainly happened, and all that's left is removing the branch.

Worktree isolation is useful (parallel background tasks don't trample the checkout) — **do not
disable** `worktree.bgIsolation`. The full escape hatch `bgIsolation: none` exists, but it is a last
resort, not the desired fix.

## Running the app for UI verification

- For live menu-bar / Settings verification, run the dev build **directly via `swift run`**:
  `TOKENPACE_STUB=… swift run TokenPace` (a background job is fine). If the status item doesn't
  appear — **kill your stale dev PID and re-run `swift run`**.
- **Never build a dev `.app` into `/Applications` on your own initiative.** That is exactly where the
  maintainer runs the installed release from; a dev bundle there **overwrites his release** with an
  unsigned build — a destructive, externally visible change he never asked for.
  **When he does ask — do it.** "Reinstall", "update my copy", "put a fresh build in" = permission for
  the whole chain (stop the old copy, replace the bundle, launch the new one) — see the ✅ exception in
  [§ Stopping the app, and logs](#stopping-the-app-and-logs).
- **Several TokenPace icons in the menu bar are expected and correct**, don't "fix" it by killing the
  release. What can be running at once: the notarized release from `/Applications` **plus several dev
  copies** with different stubs, launched from different Claude Code sessions. **All of them are
  called `TokenPace`.**
- ⚠️ **Screenshot automation (AX / `osascript` / System Events) cannot tell the instances apart.**
  `click menu bar item 1` blindly opens the Settings/menu of **some** TokenPace — easily the release
  or *someone else's* dev copy, not the one carrying your change. The screenshot then shows the wrong
  build, or the window "isn't found" in your process. Therefore:
  - **don't click a menu-bar item by name or index** to open the dropdown/Settings;
  - even `pgrep -f '\.build/debug/TokenPace' | head -1` picks *some* dev PID — when there are several
    copies, narrow it down by **your own** PID (`$!` from your own `&` launch), not by name;
  - **the dropdown (NSMenu) can't be screenshotted reliably at all** — menu tracking blocks it;
    **Settings** only if you're guaranteed to have hit your own dev icon. The reliable route: **hand it
    to the maintainer** to open the specific dev build and verify live (that is the canonical UI
    verification before a PR anyway).
- A temporary `.app` bundle is only needed for signing-dependent features (launch-at-login /
  SMAppService, update signals) — and even then not in `/Applications` without explicit permission.
  Details and the list of stubs are in [ui-verification.md](ui-verification.md).

## Stopping the app, and logs

- 🚫 **Not yours — don't stop it. Ever.** The only process you may kill is the one **this session
  launched itself** and whose PID it saved at startup. Any other TokenPace instance — the maintainer's
  notarized release from `/Applications`, another session's copy, anything — **you do not touch on
  your own initiative**.
  **This is a rule about the TARGET, not about the mechanism.** A `kill` on a single PID obtained via
  `pgrep` is the same forbidden action as `pkill`. A careful way of hitting someone else's process is
  still hitting someone else's process.
  **No reason you invent is an exception.** "It gets in the way of automation", "so only one process
  is left", "just for a second, then I'll restart it", "it's easier for me to verify this way" — none
  of these is grounds, they're a description of how the rule gets broken. If a verification can't be
  done without killing someone else's process — **hand the verification to the maintainer** and leave
  the process alive.

  ✅ **The single exception is an explicit request from the maintainer in this session.** When he asks
  to **reinstall, update, rebuild or restart the installed app** (`/Applications/TokenPace.app`) —
  "reinstall", "update my copy", "put a fresh build in", "restart the app" or equivalent — **do it
  without asking back**, and the permission covers **the whole chain** it requires: stop the old copy
  (by its PID), overwrite/replace the bundle in `/Applications`, launch the new one. This is the same
  case as the separate "don't build a dev `.app` into `/Applications`" rule above: forbidden **on your
  own initiative**, permitted **on request**.
  The limits of the exception: the permission applies to **that specific request**, not to the whole
  session in advance; it does not extend to **other sessions'** copies, and it does not turn "the
  maintainer asked me to verify a feature" into "I may kill his app because that's more convenient for
  verifying". Asked to reinstall — reinstall; asked to verify — leave the process alone.
- 🚫 **You launched it for review — don't stop it until the maintainer says he's looked.** This applies
  to **your own** instance too, and this is exactly where the rule above has a gap: it protects other
  people's processes, but the moment the agent launches a build itself "for the maintainer to look at",
  that process stops being his — it is now **someone else's verification instrument**. A restart for
  your own screenshot, a retry, a "fresh log" or an "I'll bring it back up right away" **kills someone
  else's review session**: a person is looking at the widget and it vanishes from the bar mid-review.

  The trigger is simple: if the exchange contained "run it", "show me", "check", "I'll take a look",
  the process goes **hands-off** until the maintainer's explicit word ("saw it", "ok", "stop", "run
  the other stub"). Want a different configuration — **ask**, don't silently restart. Can't take the
  screenshot yourself (for instance, `screencapture` returns an empty frame with no status items) —
  **that is not grounds for a restart**: say so and hand the verification to the maintainer, leaving
  the process alive.

  The origin of this rule is a session where the agent twice restarted its own dev build for a
  screenshot at precisely the moment the maintainer was studying the bar on screen.
- **Never do a broad kill** along the lines of `pkill -f TokenPace` / `pkill -f tokenpace` /
  `killall`. Stop **only the instance this session launched itself**, by its **specific PID**, saved at
  startup (`$!` from your own `&`/`open` launch → into a file; `kill "$(cat …)"`).
  **This covers pattern matching on the bundle path too** (`pgrep -f 'build/TokenPace.app' | kill`,
  `pgrep -f '\.build/debug/TokenPace'`): it matches **other sessions' instances and the user's own
  instances**, not just "stale dev PIDs". So **without explicit confirmation from the maintainer, don't
  kill by path or by name — only by your own saved PID.**
  **Why:** (a) the maintainer watches logs through `log stream --predicate 'subsystem ==
  "com.artem-n.tokenpace"'` — a pattern kill by name matches that process too (the predicate contains
  the subsystem string) and takes down his monitoring along with the app; (b) parallel sessions and the
  user's real instances must not die from someone else's cleanup.
- **Don't start your own `log stream` competing with the maintainer's.** For your own diagnostics use
  `log show --last <window>` — that leaves his `log stream` alive.
### The "change it → look at it" loop: one stream, N restarts

A ready-made recipe. Do it this way, don't invent your own — the numbers underneath it come from
session [#375](https://github.com/artem-from-ua/tokenpace/pull/375), where a home-grown loop cost ~150
of 321 bash calls.

⚠️ The loop describes **your own** diagnostics — when you are the one looking at the app. The moment a
build has been handed to the maintainer for review, the hands-off rule above applies: the `kill` in
step 2 is **not executed** until he says he's looked.

```sh
# 1. ONCE for the whole diagnostic session:
/usr/bin/log stream --predicate 'subsystem == "com.artem-n.tokenpace"' \
  --level debug --style compact > "$TMP/tp.log" 2>&1   # in the background
# 2. Each iteration touches only the app:
kill "$(cat "$TMP/app.pid")" 2>/dev/null              # your own PID, saved at startup
swift build && swift test                             # ONE command, not two
TOKENPACE_STUB=… swift run & echo $! > "$TMP/app.pid"
until pgrep -qf '\.build/.*/TokenPace'; do sleep 1; done
# 3. New lines come from the same growing file:
tail -20 "$TMP/tp.log"
```

- **The stream is not restarted.** It is not part of the iteration's state. Every kill of your own
  background job comes back as an `exit 143/144` notification — a "failed" that has to be read and
  costs a turn. In #375 that burned **51 tasks out of 60**.
- **`sleep` doesn't wait — it guesses.** Write `until <check>; do sleep 1; done`: it returns as soon as
  the condition holds, instead of paying the worst case. In #375, **45** commands started with a bare
  `sleep`, and 17 of them were the same `sleep 4` before `swift run`.
- **A bare timer in the background (`sleep 120; echo waited`) is the same violation in other words.**
  You wait for your own background job via `run_in_background`, and for a condition via Monitor with an
  until-loop.
- **`swift build && swift test` is one command.** Two separate ones double the turns without producing
  new information: in #375, **17 builds** ran with no new edits at all, and merging them succeeded only
  5 times out of 24.
- **Write `/usr/bin/log`, never `log`.** The zsh `log` function in the maintainer's profile shadows the
  binary, and the command fails with `(eval):log:1: too many arguments` — a message that gives no hint
  about the cause. This rule was already here and was violated anyway: copying the short form from
  memory is easier than remembering the trap, so **in the examples below and in CLAUDE.md the form is
  always the full one**.

## Diagnosing window layout bugs

Rules, each of which grew out of a real loss of time in
[#346](https://github.com/artem-from-ua/tokenpace/issues/346) (half a session of hypotheses, six
rounds of maintainer verification, his window frame clobbered).

### STOP: the first two steps, before any edit

**The trigger for this gate** is any report that a UI element "shifted", "moved", "is in the wrong
place", "is off by a pixel", "is slightly right/left/up", including the phrasing "probably the same
problem we already fixed". **Especially** when the maintainer has named the cause himself: his
hypothesis describes the symptom, not the diagnosis, and agreeing with it without measuring means
skipping both steps below.

The gate fires **before** you read the rest of this section and **before** you open the file holding
the suspected view. If the first thing you did in response to "it shifted" was an `Edit`, you have
already broken the protocol.

1. **Compare the strings.** Take the text in the "before" state and in the "after" state and see
   whether it is **the same text**. That's one look, zero builds.
2. **Then measure the live tree** (the probe below). Not earlier, and not "measure instead of editing,
   if the edit doesn't work".

**Why this order, rather than "hypothesis first".** The rules in this section already existed and were
broken: in the session about "at 20:00 the labels shift right", the edit went out on the very first
turn and the probe came on the third round, after two builds handed to the maintainer with "take a
look". The measurement then showed the geometry was **flawless** (`3h at 16:00` → 77.0 pt,
`resets in 3h at 16:00` → 132.0 pt, both integral, right edge `284.0` in both states), and what moved
was the middle of the string, because ⌥ adds a prefix. Both edits treated a fraction that wasn't there,
and both were reverted. The price of the violation: three rounds instead of one.

### Subpixel phase comes from the STRING, not from layout — fix the text, not the geometry

The most expensive conclusion of that session: **six** layout edits in a row yielded nothing, because
the source was somewhere else.

- **Symptom.** The badge text doesn't shift, it "breathes": XOR shows the bodies of the letters black,
  with only 1–2 thin outlines glowing. Measured at 0.075 pt.
- **Cause.** The phase (which subpixel the first glyph lands on) is determined by the **sequence of
  characters**: `5d on Monday` starts with `5`, `resets in 5d on Monday` with `r`. Different glyphs →
  different start. The text renderer does this, and layout can't reach it.
- **Proof that it isn't our anatomy.** Build a canonical AppKit badge — a label in a container, padding
  via **constraints**, an integral capsule, no custom `NSTextFieldCell`, nothing overridden — and
  measure the phase. You get **the same** `Δphase` (measured: 3 quarter-points in both anatomies).
  Meaning: before rewriting a view, check with the canonical version whether the view is to blame at
  all.
- **What does NOT work** (all measured, not guessed): `ceil` on the capsule width (0.074 → **0.426** pt,
  worse); `ceil` on the content width via trailing kern (Δtrail 0 → 2); `firstLineHeadIndent`; a
  half-point snap of `intrinsicContentSize`; overriding `titleRect(forBounds:)` and
  `drawingRect(forBounds:)`; drawing the string yourself with a rounded origin. **The last three are
  dead code:** `NSTextFieldCell` doesn't place text through those APIs, and the pixel render shows zero
  difference.
- **Status: NOT fixed, twelve approaches rejected.** That session closed only the drift of the right
  **labels** (`alignment = .right` in `addSplitRow`, drift 0.167 → 0.000 pt, confirmed by XOR and by
  the maintainer). The badge was left in its original state — every edit to it was reverted, because
  each either changed nothing in the live render or made things worse. The last attempt
  (`ceil(advance) − cellOwnInset`) **clipped the final letter** inside the capsule, and that was only
  noticed when the agent finally took a screenshot and looked himself, instead of reporting the probe's
  numbers.
- **How to check the badge is fixed.** Two frames (⌥ down / up), aligned on the **right** edge of the
  capsule, XOR. Right now the shared tail `5d on Monday` glows with a full outline around every letter
  (measured: max 121, 77 columns out of 95). Fixed = that tail is **black**.
- **The probe's numbers ≠ what's on screen.** The probe measured the string's `advance` and reported
  "LEAD 3.0 / TRAIL 3.0 — perfect", while on screen the text was clipped: the real ink is wider than
  the advance. **Look at the render**, and treat the number as a hint, not as proof.
- **WHAT IS ACTUALLY BROKEN in the badge — the stack stretches it, not the padding.** A live probe of
  the frames produced what no isolated replica had shown: `actual − intrinsic = 4.0 pt` on **every**
  capsule (`5d on Monday`, `resets in 5d on Monday`, `active`, `€`), despite `.required` content
  hugging. The text is pinned to the trailing edge, so all 4 pt open up on the left — and that is the
  "left inset bigger than the right one". **Start the next attempt here**: why does `NSStackView`
  stretch a view with required hugging, and what is `cellSize` actually asking for in
  `PillView.intrinsicContentSize`.
- **The formula `ceil(text) + 2 × padding` did NOT work, correct as it looks.** In isolation it gave
  phase 0 and equal gaps; in the app, the same asymmetry plus the text jumping came back, because
  subtracting `2 × cellOwnInset` makes the capsule narrower than what the cell asks for, and Auto
  Layout makes up the difference. The lesson is the same as above: **an isolated replica lies
  systematically here**, because it reproduces neither `NSStackView` nor the string's `edgeInsets`.
  Measure in the app.
- **Trap: `cellSize` already accounts for the narrowed `drawingRect`.** The cell adds back what the
  inset took away, so subtracting `2 × cellOwnInset` is not allowed — the capsule ends up narrower than
  the cell asks for, and Auto Layout stretches it back (measured: exactly those 4 pt of skew). But
  `cellSize + 2 × padding` doubles it. What exactly is correct here is **unresolved**; that is the core
  of the open defect.
- **What does NOT work, plausible as it seems.** Simply aligning right while leaving the width as it
  was: the whole rounding remainder falls on the **left**, and it's visible to the eye immediately (the
  maintainer: "too small an inset on the right on the red badge and on the gray currency one", then
  "very asymmetric insets"). Half a point instead of a whole one (`(w*2).rounded(.up)/2`) — phase is 3
  again. Narrowing `drawingRect` by half the remainder — phase 3. Centering with an "equal integral
  gap" — phase 3.
- **Don't "remove the string change" as a fix.** The temptation to keep a short caption under ⌥ looks
  elegant (the cause disappears, XOR is black) — and was rejected by the maintainer: **⌥ consistency
  matters more**. ⌥ expands **all** captions at once (ADR-0098), and an element left terse reads as a
  broken surface. Flicker and inconsistency aren't "the lesser and the greater evil" — they're two
  defects: fix both.
- **Why you don't see this at Apple.** Their surfaces rarely rewrite a caption with a different string
  in the same position — but that isn't permission to copy the limitation. If our design substitutes
  the text, then the layout is exactly what has to be built so the glyphs still land on the same grid.

### "Too small to be worth fixing" is not an argument in this project

Having burned several attempts on a 0.075 pt bug, an agent wrote "it can't be fixed cheaply" and
proposed closing its issue. The maintainer rejected that: **this is a macOS app, design comes first
here.**

- **The cost of the search ≠ the verdict on the task.** "I spent five attempts" describes the agent,
  not the bug. Don't present your own fatigue as a technical conclusion, and don't ask to close a
  defect's issue when the maintainer can see it.
- **The barely noticeable is more irritating than the obvious.** The maintainer's phrasing: "barely
  noticeable and therefore even more annoying". The eye doesn't know *what* changed, only that the
  element isn't holding still — and that's worse than an honest one-point shift. A small amplitude
  doesn't lower the priority, it raises the annoyance.
- **"That's normal system behavior" has to be proven, not assumed.** macOS really does render with
  subpixel antialiasing, but it does **not** follow that our layout can't be built so the glyphs land
  on the same grid every time. The proof is on you — by measuring every variant, not by appealing to
  "it's fundamental".
- **What to do once the cheap roundings are exhausted:** don't close it, raise the layer. The fraction
  comes from centering a fractional text width → so the question isn't the capsule's rounding, it's
  whether the text has to be centered in a fractional space at all (a fixed grid of widths, an integral
  content width, a different badge anatomy). Each such variant is its own measurement.

### XOR of two states is the first instrument, not the last

Suggested by the maintainer after the agent had burned five attempts on color detectors ("find the red
capsule", "find the white glyphs"), each of which caught the orange bar, or the antialiasing, or the
edge of its own crop. **XOR answered on the first try.**

- **Method.** Take two frames with the window in the same position, convert to grayscale,
  `ImageChops.difference`, amplify (`point(lambda v: v*6)`) and look at it with your eyes. Zero
  thresholds, zero color classification, nothing to "find" — everything that changed on screen glows,
  everything else is black.
  ```python
  from PIL import Image, ImageChops
  a = Image.open("state_a.png").convert("L")
  b = Image.open("state_b.png").convert("L")
  d = ImageChops.difference(a, b).point(lambda v: min(255, v * 6))
  ```
- **How to read the result.** This *is* the diagnosis, not intermediate data:
  - **all glyphs glowing as paired outlines** → the text really moved, go look at the geometry;
  - **1–2 letters glowing as a thin outline, the bodies of the letters black** → the glyphs sit pixel
    for pixel, only the subpixel coverage changed — that's antialiasing on a fractional width, **not**
    our bug;
  - **black everywhere while the eye sees a shift** → you're capturing the wrong element, or the wrong
    two states.
- **Why this beats a color detector.** A detector requires knowing *what* to look for, and every
  threshold is a new hypothesis that has to be verified too. XOR asks nothing: it shows the change
  itself. In that session the score was 5:1 against the detectors.
- **Two traps, both of which happened.** The crop has to fit **both** states: the shorter string fit,
  the longer one got clipped on the left edge — and the agent read his own artifact as "a shift of
  several pixels", although the measurement gave 0.075 pt. The maintainer had to correct him ("it can't
  be several pixels"). And align the frames on the **pinned** edge (in the popup, the right one),
  otherwise the element's differing width will produce solid glow on its own.
- **Brightness profile as confirmation.** The same conclusion as a number: take a band inside the
  element and print the maximum brightness per column. A half-tone where the other state has clean
  background (measured: 115 → 170 against a background of 115 and a glyph of 254) means the edge of a
  letter partially covered a pixel — subpixel, not a shift.

### The shift under ⌥ has TWO mechanisms — the cheaper one isn't the pixel one

- **Compare the strings first, the geometry second.** ⌥ doesn't "highlight the same caption" — it
  **replaces it with the expanded one** (`3h at 16:00` → `resets in 3h at 16:00`, `18d` →
  `resets in 18d`, [ADR-0098](../adr/0098-ruler-split-identify-always-explain-on-option.md)). The right
  column holds still (pinned flush right), so the string grows **leftward**, and its whole **middle**
  moves by whole points. An eye watching the time reads that as "the time shifted" — and the symptom
  description sounds identical to the subpixel defect. Different texts → this is **not** a geometry
  bug, and no amount of `ceil` will help; the question becomes a product one (what to hold still: the
  right edge, or the number itself).
- **Identical texts + different geometry** → only then the fraction, and from there follow the section
  about #374 below.
- **The sign that you're treating the wrong thing:** the measurement shows integral numbers and an
  identical right edge, yet the shift on screen remains. Stop — the mechanism hasn't been found, go
  back to comparing the strings.

### Rules for measuring

- **Measure the live tree first, hypothesize second.** A layout bug always has several plausible
  explanations, and each is killed by a single measurement — so measuring is cheaper than any of the
  theories. A temporary env-gated hook in `App.swift` writing to a file every second
  (`TOKENPACE_PROBE_FILE`): for every `NSScrollView` — the frame in window coordinates,
  `contentInsets`, `automaticallyAdjustsContentInsets`, `documentView`/clip heights, the scroller; for
  the suspect — the **chain of ancestors up to the root** with their sizes (that is precisely what
  showed, in #346, that the inflation comes from the very first SwiftUI descendant of the hosting
  controller). Measure at a minimum of **two window heights**. `print` won't do (stdout is buffered
  under a background launch), `log` commands in that shell break against the profile — a file is
  reliable.
- **Diagnostics are read-only with respect to the user's state.** The probe must not call
  `setContentSize` / `setFrame` or move the window: `windowDidResize` persists the frame, and the test
  silently overwrites the size the maintainer had set (this happened in #346 — twice). Only a human
  changes the sizes; the probe samples on a timer.
- **A person only ever gets number-verified builds.** Before "take a look" comes the probe: once the
  target numbers line up, the maintainer's eye checks the aesthetics rather than hunting for the
  mechanism. "Build it and look" iterations against a live human are the most expensive loop in this
  project.
- **Screenshots are usable for measuring layout, not just for "seeing".** The scale is derived from a
  known quantity in the frame (the window width is pinned — 792/857 pt) → px/pt → inset differences can
  be computed from screenshots already sent, without a new round. The prohibition applies only to
  **colors** (see [ui-verification.md § "Testing menu-bar widget colors"](ui-verification.md#testing-menu-bar-widget-colors-swatch-mode--color-picker)).
- **SwiftUI behaves oddly near window chrome → check the hosting boundary first.** In this repo the
  windows are an AppKit shell with SwiftUI content
  ([ADR-0009](../adr/0009-statusitemview-pure-layout-and-thin-shell.md)), and the `NSHostingController`
  contract (`sizingOptions`, `safeAreaRegions`, `contentLayoutRect`) affects layout more than any
  SwiftUI modifier. In #346, six margin/padding variants lost to a single line of
  `safeAreaRegions = []` —
  [ADR-0088](../adr/0088-settings-hosting-safe-area-and-manual-separator.md).
- **Bisecting a constant against screenshots = the mechanism hasn't been found.** If a number has to be
  tuned by hand (17→32→24→28…), you're patching the symptom in the wrong layer — stop, back to
  measuring.
- **A conclusion in a doc block or a report only after verification.** The phrasing "behaves like the
  system does" before the maintainer verifies live is a promise, not a fact; write "expected / per the
  measurement" until a human has confirmed it.

### A half-point shift: look for a fractional height, not a guilty view

Grew out of [#374](https://github.com/artem-from-ua/tokenpace/pull/374): the entire popup content
shifted by **0.5 pt** when ⌥ was pressed, in the preview next to Settings and **not** in the real
dropdown. It took seven wrong attempts, two of which broke the working preview, before the cause was
found.

- **Scan the tree, don't guess the view.** A temporary walk of the subtree logging every view with a
  non-integral `intrinsicContentSize` / `fittingSize` / `frame` finds the culprit in one pass. All
  seven attempts before it hit the **labels** — and the fraction was somewhere else entirely. The
  template:
  ```swift
  let frac = { (x: CGFloat) in x > 0 && x != x.rounded() }
  // recurse through subviews, log heights only — widths are fractional all over the popup and don't move the vertical axis
  ```
- **The fraction comes from derived font metrics, not from the text itself.** Along the **height**,
  `NSTextField` rounds its own metrics to integers (13 pt → exactly 16.0, with text and without) — so
  the labels are not the source here. What is fractional: an **SF Symbol in an `NSImageView`**
  (measured: `hand.raised` 16, `clock` 15.5, `exclamationmark.triangle` 16.5) and **your own
  computations from `ascender`/`descender`/`boundingRectForFont.height`** (our
  `PopupBarView.creditsViewHeight` gave 25.5). End every such formula with `ceil(...)`.
- **Along the WIDTH, labels ARE a source of fractions, contrary to what this page said before.**
  Measured by a probe in the popup: the `intrinsicContentSize.width` of those same fields is
  consistently `.5` (`on pace` 48.5, `limit reached` 78.5, `well ahead of pace` 113.5, `18d` 22.5), and
  `fittingSize` adds the cell's 4 pt of padding and stays fractional (52.5, 82.5, 117.5). This page
  previously asserted that "labels are **never** the source" without qualifying the axis — and that
  assertion, duplicated in the comment on `makeHandChip` in `PopupViewController.swift`, itself led the
  diagnosis astray. **The moral is broader than the fact: an assertion in a doc block is not a
  measurement.** If a rule says "X is never the cause" and the symptom points at X — measure X, don't
  trust the line.
- **Hang the constraint on the view, not on the row.** `NSStackView` creates alignment constraints at
  `NSLayoutPriorityDefaultLow` priority and documents them as "overridable for individual views using
  external constraints" (`NSStackView.h`). That's why a `heightAnchor` on the row loses to the content's
  intrinsic size, while the same constraint on the view itself works. `alignmentRectInsets` won't help
  either — `NSStackView` lays arranged views out by frame and ignores it (measured, see `addSplitRow`).
- **`backingAlignedRect` is harmful here.** It is a pixel-snapping API, and on Retina its own grid is
  **0.5 pt** — it will preserve 16.5 rather than fix it. Whole points need `ceil`.
- **"It only shows on one surface" isn't magic belonging to that surface.** The dropdown hides the
  fraction because `NSMenuItem.view` receives an explicit frame from `fittingSize` once; a window with
  Auto Layout carries the fraction onward through the vertical stack. Apple documents **no** rounding in
  `NSMenu` — so fix the source, not the surface, or the second surface stays broken.
- **Don't poke at the preview's sizing at random.** Attempts to impose a menu-like model on it (an
  explicit height constraint on the popup) broke the window twice — first collapsing the content into a
  slab, then scattering it under ⌥. Fix the fraction at its source; leave the hosting model alone.

## Issues and the GitHub Project

- After `gh issue create`, **add the issue to the maintainer's GitHub Project and set its Status right
  away** — don't leave it off the board.
- The process: two GraphQL mutations — `addProjectV2ItemById(projectId, contentId)` (returns the item
  id; `contentId` is the issue's node id), then `updateProjectV2ItemFieldValue(...singleSelectOptionId)`
  for the Status.
- Status follows the issue's state: **open → Todo**, **closed → Done** (In Progress only while actively
  being worked on).
- The specific project/field/option node IDs are private and kept outside the repository; if a mutation
  fails — re-check them (the project may have been edited).

## "Docs are part of code"

The change ships in the same commit as the code:

- A module changes → update [architecture.md](../architecture.md).
- A decision between two approaches → a new ADR in [../adr/](../adr/).
- A logging change (a call added/removed, different text/level/category) → update
  [log-messages.md](../reference/log-messages.md) in **the same** commit.
- A new convention or tool → update [conventions.md](../reference/conventions.md).
- A new feature with its own state → add a stub and update the stub table in
  [ui-verification.md](ui-verification.md).

## Verification before a PR

- **Don't open a PR and don't say "done" until the maintainer has verified the change live** — on stubs
  and/or on real data.
- **Screenshots from temporary dev-only code don't count** as verification (a synthetic render proves
  only the drawing logic, not that it works in the live widget/Settings/data flow).
- The working cycle: commit to a feature branch → `swift build` → hand it to the maintainer →
  confirmation → PR.

### Docs and ADRs are written AFTER the maintainer has seen the feature live

The full order: **code → `swift build`/`swift test` → screenshots to the maintainer → his confirmation
→ docs/ADR → PR.** The docs link sits exactly here rather than earlier, and that isn't a formality.

Writing an ADR before confirmation is wasted work. An ADR records not just *what* was done but *why
this approach was chosen*; if the behavior changes after live verification, what has to be rewritten is
not only the code but the rationale for the decision — the most expensive part of the document. The
same goes for [architecture.md](../architecture.md) and
[log-messages.md](../reference/log-messages.md): they describe what survived verification, not what was
planned before it.

This does **not** weaken the "[docs are part of code](#docs-are-part-of-code)" rule above: docs and code
still travel **in one PR**. This is only about when to write them inside the cycle — after confirmation,
not before it.
