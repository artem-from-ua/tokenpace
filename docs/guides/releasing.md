# Release procedure

How to build, notarize and publish a `TokenPace` release on GitHub so that other people (friends,
testers) can use it without Gatekeeper warnings.

## Prerequisites (one-time)

- A **Developer ID Application** identity in the Keychain
  (`security find-identity -v -p codesigning` shows 1 valid identity).
- A **notarytool keychain profile** named `tokenpace-notary`:
  ```sh
  xcrun notarytool store-credentials tokenpace-notary \
        --apple-id <APPLE_ID> --team-id <TEAM_ID>
  # it will ask for an app-specific password from appleid.apple.com (NOT your main password)
  ```
- The `gh` CLI authenticated (`gh auth status`).

Signing setup details are in [ADR-0004](../adr/0004-build-system.md),
[ADR-0012](../adr/0012-configure-window-and-launch-at-login.md).

## Preflight checks (before building)

Run these **before** bumping the version and building, to catch a release that would quietly break
saved settings or state for users upgrading. The comparison base is the tag of the last GitHub release:

```sh
LAST="$(gh release view --json tagName -q .tagName)"   # e.g. v0.44.0
```

### A. Did the configuration options change — and is a migration needed

Every user option lives in the single file `Sources/TokenPace/PersistedConfig.swift`
(`enum PersistedConfig` over `UserDefaults`; the private `enum Key` is the canonical registry of
string keys). `@AppStorage` is not used anywhere, there is no `register(defaults:)` — the defaults are
baked into the getters.

```sh
git diff "${LAST}..HEAD" -- Sources/TokenPace/PersistedConfig.swift
```

What to look for in the diff, and what it means for migration:

- **A new key** — compatible, no migration needed: the old build simply never wrote it, and the getter
  returns the default.
- **A renamed or deleted key** — **incompatible**. The old value is orphaned under the old string.
  Either read the old key and rewrite it into the new one (a real migration, see below), or preserve
  backward compatibility with a fallback in the getter.
- **A changed default** — check the idiom. Opt-out options read as `object(forKey:) ... ?? true`,
  opt-in as `?? false`; that deliberately distinguishes "not set" from an explicit choice. Changing
  that branch silently overrides what the user has already turned off or on — a noticeable behavioral
  change, not a cosmetic one.

### B. Did the persistent state change — and is a migration needed

Persistent state (anything that survives a restart, beyond plain options) also lives in those same
`UserDefaults` keys. There is no separate on-disk store (the usage snapshot is kept in memory only;
`UpdateInstaller` writes only into temp with a `defer` deletion). What matters is the serialized types
whose **shape** is persisted:

```sh
git diff "${LAST}..HEAD" -- \
  Sources/TokenPaceKit/MonitoredServices.swift \
  Sources/TokenPaceKit/SuppressDays.swift \
  Sources/TokenPaceKit/TopBarHiding.swift \
  Sources/TokenPaceKit/ColorAdvice.swift \
  Sources/TokenPaceKit/BarStyle.swift \
  Sources/TokenPaceKit/PopupSectionVisibility.swift
```

- `MonitoredServices` (`Codable`) is serialized as a JSON blob into `monitoredServices`.
  `MonitoredServicesTests.swift` pins the raw strings precisely because they are persisted.
- `SuppressDays`, `TopBarHiding`, `ColorAdvice`, `BarStyle`, `PopupSectionVisibility` are raw-string
  enums, stored by raw value.
- **The compatibility rule:** all of them decode **forward-compatible** — an incompatible or unknown
  raw value falls back to the default quietly (no crash). If you change the shape (a new or renamed
  field, a different raw value) — **preserve that property**: an old blob must either decode correctly
  or fall back to the default safely. Keep the legend of legacy values in the type's comments (as is
  already done for `TopBarHiding.migrated(fromLegacyHide:)` and `BarStyle.legacySurfaceStyles`).
- **Renaming a raw value is two edits, not one**
  ([ADR-0104](../adr/0104-appearance-named-for-behaviour-on-three-layers.md)). Besides the new case you
  need an entry in the type's `legacyRawValues` (`ColorAdvice`, `TopBarHiding`,
  `PopupSectionVisibility`, `BarStyle` — each has its own) and a custom `init(from:)` that consults it
  **before** the default fallback. Without that, the user's saved choice quietly falls back to the
  default — which is exactly what a rename has no right to do.

**Appearance keys are prefixed by surface** (`menuBar.*` / `dropdown.*`), and the config export emits
**nested** `menuBar` / `dropdown` groups. If you rename a key, you need **both** halves:

1. a `migrateRawKey(from:to:label:resolve:)` step in
   [`PersistedConfig.migrateAppearanceKeysIfNeeded()`](../../Sources/TokenPace/PersistedConfig.swift)
   — it moves the raw value from the old key to the new one and **eats** the old one, so idempotency
   needs no separate marker key;
2. `legacyRawValues` in the type itself — so that the same transfer also works for an **imported**
   config, which never sees the `UserDefaults` migration.

The second half is the easiest to forget: `defaults` migrates, while JSON pasted from someone else's
dump quietly slides into the defaults.

Also check the edge-detect / update / archive state (`backToWorkWasBlocked`,
`pendingWhatsNewVersion`, `lastFailedInstallVersion`, `lastUpdateCheck`, `lastSeenLatestVersion`,
`lastArchiveSync`) in the same `PersistedConfig.swift` diff — a change in the semantics of those keys
between versions can also produce unexpected behavior after an update.

### C. If a migration really is needed

The scaffolding exists, but there are **no real migration steps yet** (see
[ADR-0023](../adr/0023-persisted-config-version-marker.md)):

- The pure core is `Sources/TokenPaceKit/MigrationPlan.swift` (`MigrationPlan.transition`,
  `needsMigration`).
- The startup hook is `AppDelegate.runConfigMigrationsIfNeeded()` (`Sources/TokenPace/App.swift`),
  called first in `applicationDidFinishLaunching`. The `.upgraded` branch is currently **empty**
  (scaffold, #71); the version marker is `PersistedConfig.lastRunVersion`.

The cheapest route is to make the change forward-compatible (like the existing enum decoding). If that
is impossible (renaming a key while preserving its value, a real transformation of the shape) — fill
the `.upgraded` branch in `runConfigMigrationsIfNeeded` with a from→to step and cover it with a test.

## Steps

### 1. Determine the version

The version comes from the `VERSION` file (the marketing version) and is duplicated in
`Sources/TokenPaceKit/TokenPaceKit.swift` (`TokenPaceKit.version`). If you're bumping it — update
**both** places in a separate PR **before** the release and follow [SemVer](https://semver.org/).

```sh
VERSION="$(tr -d ' \t\n\r' < VERSION)"   # e.g. 0.9.0
```

**Reconcile both sources BEFORE tagging** — a mismatch means the bump only touched one of them:

```sh
grep -q "\"${VERSION}\"" Sources/TokenPaceKit/TokenPaceKit.swift \
  || echo "MISMATCH: VERSION=${VERSION} != TokenPaceKit.version — update both in a separate PR"
```

### 2. Build, sign, notarize

```sh
./scripts/build-app.sh
```

The script builds the release binary as **universal** (arm64 + x86_64 — each architecture separately
via `--triple`, then `lipo -create`), assembles the `.app`, signs it with Developer ID
(`--options runtime`), notarizes it (`notarytool submit --wait`) and staples the ticket
(`stapler staple`). Notarization can take several minutes.

Expect in the logs: `lipo archs: x86_64 arm64`, `status: Accepted` and
`The staple and validate action worked!`.

**Agent / background session:** the harness blocks a bare `sleep`, so don't wait out notarization with
`sleep N` — start the build in the background and poll the log with an until-loop (notarization can
take several minutes):

```sh
( ./scripts/build-app.sh 2>&1 | tee "$CLAUDE_JOB_DIR/tmp/build.log" ) &
until grep -qE 'notarization complete|done:|error|Invalid' "$CLAUDE_JOB_DIR/tmp/build.log"; do
  sleep 2
done
```

### 3. Verify the notarization

```sh
spctl -a -vvv -t exec ./build/TokenPace.app   # → accepted (Notarized Developer ID)
xcrun stapler validate ./build/TokenPace.app  # → The validate action worked!
lipo -archs ./build/TokenPace.app/Contents/MacOS/TokenPace   # → x86_64 arm64
```

If `spctl` says `rejected` — do **not** publish the release, work out why first.
If `lipo` shows only one architecture — the binary isn't universal, rebuild it.

### 4. Pack the release archive

`build-app.sh` deletes its own temporary ZIP after notarization, so the release archive is made
separately — from the **already stapled** `.app` (so the ticket travels inside it):

```sh
ditto -c -k --keepParent ./build/TokenPace.app "./build/TokenPace-${VERSION}.zip"
```

`--keepParent` keeps the `TokenPace.app` folder inside the archive (otherwise it unpacks as loose
files). `ditto` (rather than `zip`) preserves the signature and extended attributes correctly.

### 5. Create the tag and the GitHub Release

**Before tagging, make sure you're on a clean `main`** — a tag on some random feature branch (or a
commit straight into `main`) has broken a release before, when `checkout -b` silently failed because of
a git lock:

```sh
[ "$(git branch --show-current)" = main ] && git diff --quiet && git diff --cached --quiet \
  || echo "STOP: not on a clean main — don't tag from here (see agent-workflow.md § Branches)"
```

Git discipline details are in
[agent-workflow.md § Branches, PRs and syncing main](agent-workflow.md#branches-prs-and-syncing-main).

```sh
git tag "v${VERSION}"
git push origin "v${VERSION}"

RELEASE_NOTES_APPROVED=1 gh release create "v${VERSION}" \
   "./build/TokenPace-${VERSION}.zip" \
   --title "TokenPace v${VERSION}" \
   --notes "Release description: what's new, how to install (see below)."
```

The tag goes on the current `main` (with every PR already merged).

> **The release notes gate** is enforced by `.claude/hooks/release-notes-guard.sh` — see CLAUDE.md.
> The `RELEASE_NOTES_APPROVED=1` prefix is added only after the notes are composed per this document
> and approved by the maintainer.

### 6. Verify from the user's side

Download the ZIP from the release onto a "clean" Mac (or simulate quarantine):

```sh
# simulating an app downloaded from the internet
cp -R ./build/TokenPace.app /tmp/TokenPace-test.app
xattr -w com.apple.quarantine "0081;0;Safari;" /tmp/TokenPace-test.app
spctl -a -vvv -t exec /tmp/TokenPace-test.app   # should be accepted
rm -rf /tmp/TokenPace-test.app
```

## If a release broke off halfway — how to continue

A release is a chain of steps, and the session can break off (interrupted, GitHub's network failed,
`--wait` hung) in the middle of it. **Don't restart from scratch** — first check what has already been
done, and continue from where it stopped. Every check below is non-destructive (it reads state, it
doesn't change it).

### The `.app` is already built and stapled

```sh
spctl -a -t exec ./build/TokenPace.app   # accepted → build+notarize+staple are already behind you
```

If it says `accepted` — skip steps 2–3 and go straight to packing (step 4). There is no need to
rebuild: the `.app` in `build/` is already notarized and carries its ticket.

### Notarization: `--wait` hung on `In Progress`

This is not a failure — `submit --wait` sometimes doesn't return even though Apple has already
finished. **Don't rebuild.** Find out the final status independently of `--wait`:

```sh
xcrun notarytool history --keychain-profile tokenpace-notary        # find your submission id
xcrun notarytool log <submission-id> --keychain-profile tokenpace-notary
```

If the status is `Accepted` — staple and verify right away, bypassing a second `submit`:

```sh
xcrun stapler staple ./build/TokenPace.app
spctl -a -t exec ./build/TokenPace.app   # → accepted
```

### The tag `v${VERSION}` already exists

```sh
git rev-parse "v${VERSION}" 2>/dev/null   # exists → check what it points at
```

- Points at the right HEAD (the current `main`) → skip `git tag`, go to `git push` / the release.
- Points at a different commit (left over from an interrupted attempt) → `git tag -d "v${VERSION}"` and
  recreate it on the correct commit.

### A release for this version partially exists

```sh
gh release view "v${VERSION}"   # does it exist? with which asset?
```

- The release exists but has **no ZIP asset** → upload the asset:
  `gh release upload "v${VERSION}" "./build/TokenPace-${VERSION}.zip"`.
- A **conflicting older release** is in the way (e.g. the previous `latest`, whose binary doesn't match
  the new tag) → delete it before publishing the new one:
  `gh release delete "v${VERSION_OLD}"` (with the maintainer's confirmation).
- The tag exists but the release doesn't → just run `gh release create` (step 5), don't recreate the
  tag.

## Release notes: content and style

The audience is **geeks who use Claude Code themselves**. Write in English, the way you would to a
colleague — not for a press release.

**Mandatory before publishing: show the generated notes to the maintainer for approval.** Do not
publish the release until he has said "ok".

**If he gives you his own wording, take it verbatim.** The maintainer's versions are shorter and more
precise than the generated ones; don't "tidy up" text that has already been approved, and don't change
the markup without asking (expanding a code block "so it's easier to copy from GitHub" was reverted
with "no, put it back"). If his edit breaks something factually — say so, but don't silently rewrite
it.

**Step 0 — agree on what goes into the notes at all.** Before writing any text, put together the
**complete list of new features and notable changes** since the last GitHub release and let the
maintainer tick the checkboxes for the ones that make it into the release notes. Don't decide on your
own what counts as "minor" — show everything and let him choose.

```sh
LAST="$(gh release view --json tagName -q .tagName)"        # e.g. v0.44.0
git log "${LAST}..HEAD" --no-merges --pretty='- [ ] %s'     # candidates as a checkbox list
```

Present the result as a Markdown checklist, grouping related commits into a single item (see the
merging rules below) and filtering out the purely internal (refactors with no visible effect, CI,
version bumps). Each line is `- [ ] <human description of the feature>`, e.g.:

```markdown
- [ ] Dynamic yellow→orange pacing threshold + 20-minute override (#179)
- [ ] A single reset-line format for every limit in the popup (#175)
- [ ] An honest reset grace boundary — no more "resetting…" (#180)
```

Ticket numbers **belong here** — the maintainer needs them to open the PR quickly. They do **not**
carry over into the **text of the notes themselves**.

The maintainer puts `[x]` next to the ones going into the release; only the **ticked** items become the
basis for the notes. Those left as `[ ]` don't make it in.

### How much of the checklist survives into the notes

**A release is two or three items, not a changelog.** The actual "proposed → kept" ratio over recent
releases: `v0.69.1` 10→3, `v0.65.1` 5→3, `v0.62.0` 11→4, `v0.76.0` 4→2 — roughly **a third**.

**The criterion isn't "visible", it's "changes what the user does".** Visibility is far too weak a bar,
and it is precisely the one the agent gets wrong most often. In `v0.76.0`, the single reset-time format
(`20:40` → `5h` right there in the menu bar) and the end of the widget's width jumping both went under
"unnecessary cosmetics" — both changes are obviously visible every day, and neither made the cut.

What systematically does **not** go into the notes, per observations from past releases:

- links and menu items added "for convenience" (e.g. "Release notes" next to the version in About);
- an icon moving between elements, a marker's width changing by 1.5 pt, bars being aligned;
- two options merged into one, a settings section renamed;
- fixing the position of a window that opened off-screen;
- any change you'd describe with the words "while we were at it, we tidied up".

**Don't create a "Minor" / "Menu-bar odds and ends" / "For those who dig around" section.** Sections
like that got deleted wholesale every time, along with the real fixes inside them. If an item is only
good enough for the bucket of small things, it isn't good enough for the notes at all. Section headings
are plain and descriptive.

**Push back once, not twice.** If you think a struck-out item deserves a mention, say so in one
sentence and accept the answer.

**What to cover:**

- **Cover everything since the last GitHub release** — in the step 0 **checklist**. Several
  intermediate versions accumulate between releases; take every significant change since the last tag
  on GitHub (`gh release view` → its tag → `git log <tag>..HEAD`). Only a minority of that list survives
  into the **text of the notes** — see "How much of the checklist survives into the notes" above.
- **Don't name individual intermediate versions.** The reader doesn't care that a feature landed in
  `0.32.0` and was polished in `0.34.0` — write about the change as one whole. Only the **final** release
  version appears in the notes.
- **Merge the text of related features where it makes sense.** Several pieces of news about the same
  feature from different intermediate versions — fold them into one (describe the end state, not the
  history of iterations).
- **The subject of the notes is the diff against the previous release, not the commit history.** Between
  releases a feature can change a great deal, or even appear and disappear entirely. The user jumps from
  the previous release straight to this one — for them only the **difference between those two points**
  exists. So:
  - a feature added and **removed** within one release cycle doesn't go into the notes **at all** — for
    the reader it never existed, and mentioning it only confuses;
  - a feature that got reworked several times is described **as it ships** — intermediate variants aren't
    mentioned, not even as "we first did X, then changed our minds";
  - an option added in `0.75.0` and renamed in `0.75.2` has **one** name in the notes — the final one.

  In practice this means: build the step 0 checklist from `git log`, but **check every item against the
  diff** `git diff <last-tag>..HEAD`, and where the two disagree — the truth is in the diff.

  ```sh
  LAST="$(gh release view --json tagName -q .tagName)"
  git diff --stat "${LAST}..HEAD" -- Sources/    # what actually changed in the end
  ```

**No ticket or PR numbers in the text of the notes.** `(#307)`, `(PR #308)`, links to issues — none of
that appears in the published notes. The reader of a release is a user, not a contributor; the number
tells them nothing, and everyone else has the release's own Commits tab. This applies to the **text of
the notes**, not to the **step 0 checklist** — there the numbers are useful precisely because the
maintainer needs to get to the PR quickly and understand what an item is about.

**Check UI element names against the code, not against memory.** Writing "X was renamed to Y" — open
the file where the caption is defined and quote both names from there. For bar styles that is
`BarStyle.displayName` in `Sources/TokenPaceKit/BarStyle.swift`; for the old name, the same file at
the previous release's tag:

```sh
LAST="$(gh release view --json tagName -q .tagName)"
git show "${LAST}:Sources/TokenPaceKit/BarStyle.swift" | grep -n 'case .*return "'
grep -n 'case .*return "' Sources/TokenPaceKit/BarStyle.swift
```

Getting this wrong is easy and hard to notice: in `v0.76.0` a draft of the notes twice asserted
"`Pace` → `Progress`", when in reality it was `Pace & Time` → `Progress`, and `Pace` → `Pressure`. The
name `Pace` didn't disappear, it "moved" to a different style — so the wrong line would have read as
"my setting was swapped out from under me". Raw values in `UserDefaults` (`pacing`/`simple`) are **not**
UI names and don't go into the notes.

**If you renamed or replaced an option, say that the saved choice migrates by itself.** One line along
the lines of "your saved style choice migrates by itself — there's nothing to re-pick". A rename seen
without that guarantee reads as "my settings may have slipped", and the user goes off to check Settings
for nothing. First **make sure the migration really exists** (for bar styles that is
`PersistedConfig.migrateBarStyleIfNeeded` + **`BarStyle.legacySurfaceStyles(for:)`**) — if it doesn't,
that's not a line in the notes, it's an open bug to fix before the release.

> ⚠️ **`legacyRawValues` is not a complete list of migrations.** That table maps a raw value to **one**
> `BarStyle`, so a value that decomposes into **different** styles for the two surfaces doesn't fit in
> it by construction — and is deliberately absent from it. That is exactly the case with `"mixed"`
> (#329, [ADR-0080](../adr/0080-per-surface-bar-style.md)): it migrates into a Pressure + Progress pair,
> but a check against `legacyRawValues` alone will report "there is no migration" and push you either to
> write a false warning in the notes or to block the release over a non-existent bug. **The source of
> truth is `legacySurfaceStyles(for:)`**, which both consumers read: the `UserDefaults` migration and
> the decoding of an exported config.

**An option disappearing is not a rename, and the notes have to say exactly that.** `grep 'title:'` on
two tags will show a vanished segment the same way it shows a renamed one, so distinguish them
deliberately: in #329 the `Mixed` segment was **deleted**, not renamed — its role was taken over by a
pair of independent controls, and the saved choice is reproduced exactly (menu bar Pressure + dropdown
Progress). The phrasing "Mixed was renamed" would have been untrue here; the correct line is that the
style choice is now separate for each surface, and the old look is preserved automatically.

### How to write an item: one sentence about what changed

**An item is one or two sentences, and they say *what it is now*, not why and how.** Below are four
kinds of "tails" the maintainer cuts every time. They look useful while you're writing and equally
never survive to publication:

- **The cause of the bug.** "The job's state freezes because the daemon pulls the transcript from the
  wrong folder" — cut. The user isn't fixing our bug; it's enough for them to know the bug is gone.
- **Design rationale.** "We show just 'Claude' with no guessing — better nothing than an invention that
  looks like a bug" — cut. Justifying a decision leads nowhere.
- **"While we were at it".** "We also went over Settings a bit", "we tidied up the copy feedback while
  we were at it" — cut along with the item itself.
- **Retelling the bug as a user story** when the heading has already named it: "Claude is doing
  something while the counter says it's waiting on you" after a heading about that very counter.

**Don't enumerate surfaces and don't describe the appearance.** "In the popup — a hand icon in the
section header, bare with one session, with a number when there are several; in the menu bar — the same
icon as the first element on the left" → what was left is `Hold ⌥ (Option) for a per-project breakdown`.
Thirty words about where what is drawn collapsed into six words about what you can do.

**The one thing worth *adding* is where to turn it on.** An option that's off by default, with no path
in Settings, makes the reader hunt for it. This is the opposite of the preceding rules: here it's an
action that's missing, not an explanation.

**Check every statement against the code before showing a draft.** A draft that claimed the popup shows
"a list of sessions that are waiting", when it actually shows a counter, got a one-word answer: "a lie".
A false statement costs more than an omitted one — write from the body of the PR and from the code,
never from memory.

**Tone and structure:**

- **Friendly and concise.** "Added / fixed / now", not "implemented / performed an optimization of".
- **Lead with what matters.** What changed for the user in the first sentence; technical detail below,
  or behind a link to an ADR/PR.
- **Humor homeopathically.** One light phrase per set of notes at most, and only where it fits. No
  emoji spam.
- **Respect the reader.** A geek doesn't need to be told what a menu bar or a reset is.
- **Structure** (flexible): a short feature heading → 1–2 sentences of substance → where needed, a
  compact list of specifics → the section about updating and installing (below).

**The updating section (at the end of the notes):**

- **Recommend turning on auto-updates** in the app (Settings → About → "Check for updates periodically"
  + "Install updates automatically").
- **Leave a short description of manual installation** for anyone installing for the first time or who
  prefers doing it by hand (download the zip → unpack → drag into Applications → launch from
  Launchpad). The full instructions are below.
- **Don't add explanations of why the user would want this.** "So that future releases arrive on their
  own, without downloading them by hand" — that's exactly the tail that got cut from `v0.76.0`. The name
  of the option says everything; the phrase explains to an adult what they've just read. Give the step,
  not the motivation for it.

An example of the right tone: "The widget no longer nags you with the reset time when everything is
calm anyway — it shows it only when it's time to pay attention." An example of the wrong one (too dry):
"Implemented a mechanism for conditionally hiding the countdown element according to the state matrix."

## Instructions for users (in the release body)

> 1. Download `TokenPace-X.Y.Z.zip` and unpack it (double-click).
> 2. Drag **TokenPace.app** into the **Applications** folder.
> 3. Launch it from **Launchpad** or Finder. There will be no Dock icon — the app
>    lives in the menu bar (`LSUIElement`).
>
> **Launch-at-login** only works for a copy in `/Applications`, launched from there.

**Don't mention notarization or Gatekeeper in the release body.** Every build is notarized — that is an
invariant property of the process, not news about a particular version, and it dictates no action to
the reader. The technical notarization check stays as step 3 above; it just doesn't make it into the
text for the user.
