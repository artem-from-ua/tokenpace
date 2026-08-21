---
status: accepted
date: 2026-08-20
supersedes: []
superseded_by: []
---

# ADR-0114: "Extra usage" — one name across every surface

> Supersedes the "**The hint emphasizes present tense**" item in the "Related decisions" section of
> [ADR-0068](0068-credits-in-use-marker-anatomy.md) — specifically the clause "The wording `Extra
> Usage Credit` is aligned with the existing notification." The rest of 0068 still stands: the
> marker's anatomy, `KnockoutGlyphBadge`, narrowing `PillView` to the blocking-reset badge, the
> currency glyph's three colors.
> Changes nothing in [ADR-0050](0050-extra-usage-notification.md) (when the notification fires) —
> only **how** it names the thing it's notifying about.

## Context

The app called one feature by two names, and both were "correct" per their own ADR.

The dropdown section is called **`Extra usage`** — sentence case, sourced from
`PopupViewController.extraUsageTitle`, marked there as a localization seam
([ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md)). The notification and the marker's
tooltips wrote **`Extra Usage Credit`** — Title Case, and that too was a deliberate decision: 0068
explicitly aligned the hint with the banner's title, "so the app doesn't call the same thing two
different things."

Each decision was locally consistent; together, they contradict each other. It showed up worst in
Settings, which inherited **both** spellings at once: `AppearancePanes` refers to the section as
`*Extra usage*` (with a rule comment "this is the section's name, hence the italics"), while
`NotificationsPane`, on the neighboring pane, wrote "Switching to Extra Usage." The user sees two
names with no way to tell they're the same thing.

The divergence also survived because the banner's title existed **twice**: `ExtraUsageOnset.bannerTitle`
(Kit) and a literal in `BackToWorkNotifier.postExtraUsage`. They matched by coincidence — any wording
edit on one side would have drifted silently, since there are no tests on these strings.

## Decision

**One name — `Extra usage`** — on every surface: the popup, Settings, the notification, tooltips,
accessibility labels.

1. **Case — sentence case.** The section's side won, not the billing term's side. The section is
   what the user sees constantly and clicks on; the notification title is seen a few times a month.
   The name in the interface should lead, not the term from the receipt.
2. **The word `credits` — lowercase and plural**, when referring to money: `Now using Extra usage
   credits`, `Currently spending Extra usage credits`. It stays, because dropping the word
   "credits" from spending-related text would make the phrase ambiguous; but it's no longer part of
   the name, so it's no longer capitalized. The plural requires matching the verb: `Extra usage
   credits **are** spent`.
3. **Italics — only when the string names the section**, not when it describes spending.
   `Switching to *Extra usage*` — italic; `on paid Extra usage credits` — not.
4. **The name's source — `PopupViewController.extraUsageTitle`.** The notification title is read
   from `ExtraUsageOnset.bannerTitle`, rather than duplicated as a literal in
   `BackToWorkNotifier`.

Why this doesn't contradict 0068 but continues it: the motive there and here is **the same** — the
app shouldn't call one thing two different things. 0068 couldn't see it through, because it only
looked at the "notification ↔ marker hint" pair and didn't see the popup section as a third
participant. What changes isn't the principle — it's which side got picked as canon.

## Consequences

- **The notification text changes for existing users.** The banner now reads `Now using Extra usage
  credits`. The cost is accepted deliberately: one name is worth a one-time change to a familiar
  string.
- **`SettingsDisabledLabel` renders through `Text(.init(_:))`** — otherwise the italics asterisks
  print literally. The `Toggle`'s hidden label stays a plain string, on the other hand: VoiceOver
  speaks it aloud, and it would read the markup out loud too.
- **The notification seam became one-directional** — `BackToWorkNotifier` reads the Kit constant.
  One line instead of two that only looked synchronized.
- **There's nothing to catch a regression with.** There were no tests on these strings before, and
  there still aren't: `Tests/` covers only `TokenPaceKit`, while Settings and the popup live in the
  executable target with no tests. The current protection is the rule in
  [conventions.md](../reference/conventions.md#case-of-user-facing-strings--sentence-case-and-one-name-per-thing)
  and the fact that the name now has a single source. Lifting `extraUsageTitle` into the Kit and
  closing it with a test is the obvious next step, deliberately not done here so as not to drag a
  refactor into a text change.
- **`Extra Usage Credit` remains in comments and doc comments** wherever it refers to Anthropic's
  billing product as an external entity. That's not UI, and the unification doesn't touch it.

## Alternatives considered

- **Unify the other way** — rename the popup section to `Extra Usage Credit`. Rejected: the section
  name is longer than the column, duplicates the word "credit" right next to a euro amount, and
  would make the interface look like a billing statement instead of a landmark.
- **Keep both names and document both** as legitimate (section ≠ product). Formally defends 0068,
  but the user doesn't read ADRs — they see two strings and have no way to know it's one thing.
- **Drop the word `credits` entirely** (`Now using Extra usage`). The shortest option and matches
  the section name exactly, but in a sentence about spending money, it loses track of what's
  actually being spent.

## References

- [#416](https://github.com/artem-from-ua/tokenpace/issues/416) — the ticket this decision grew out of.
- [#156](https://github.com/artem-from-ua/tokenpace/issues/156) — Settings parity, where the divergence was spotted.
- [ADR-0068](0068-credits-in-use-marker-anatomy.md) — partially superseded by this ADR.
- [ADR-0050](0050-extra-usage-notification.md) — the notification itself.
- [ADR-0009](0009-statusitemview-pure-layout-and-thin-shell.md) — the popup's localization seam.
