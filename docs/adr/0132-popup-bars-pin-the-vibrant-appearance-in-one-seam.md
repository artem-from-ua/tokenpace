---
status: accepted
date: 2026-09-27
supersedes: [0097]
---

# ADR-0132: Popup bars pin the vibrant appearance in one seam shared by the live bar and every specimen

> **Supersedes §2 of [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md)** in the part that
> reads "For the dropdown this will be different… The two surfaces deliberately follow different
> rules — this is not an overlooked asymmetry." The asymmetry is now gone: both surfaces resolve
> through one function. **The rest of §2 still stands in full** — the menu-bar specimen keeps its
> hardcoded `.vibrantDark`, for the reasons that section gives (its plate is black in both themes,
> and the menu bar stays dark under a light theme), and drawing still happens *inside*
> `performAsCurrentDrawingAppearance`.

## Context

The popup's bars draw their neutrals from the system `tertiaryLabelColor` and `quaternaryLabelColor`
(`Palette.monochromeGrey`). Those two colours mean **different things in the two appearance
families**, which is not a detail of alpha but of the value itself. Measured on macOS 27, in sRGB:

| appearance | `monochromeGrey` |
|---|---|
| `aqua` | `0,0,0` @ 0.178 |
| `darkAqua` | `255,255,255` @ 0.173 |
| `vibrantLight` | `211,211,211` opaque |
| `vibrantDark` | `51,51,51` opaque |

The time-indicator marker's ring is that grey blended into the marker's own colour, so the family
decides whether the ring reads *lighter* or *darker* than the strip it separates from. The tone was
calibrated against the vibrant family, because that is what an `NSMenu` was.

It stopped being that. Probed live on macOS 27 with an `NSLog` inside `PopupBarView.draw(_:)`, the
menu-hosted bar runs with `NSAppearance.currentDrawing()` **and** the view's own
`effectiveAppearance` both `darkAqua` — where macOS 15 handed it a vibrant one. Nothing in the app
changed. The ring inverted with the theme: light on dark, dark on light.

The Settings style tile beside it looked correct throughout, because
`DropdownBarStylePreviewRenderer` chose its appearance explicitly — the vibrant variant of the
current theme — while the live bar inherited whatever the host offered. Two code paths, one of which
was right by accident and the other wrong by accident.

That split was deliberate once. [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) §2 set the
menu-bar specimen to a fixed `.vibrantDark` and said the dropdown "will be different", since its
tile does not sit on black and follows the system theme. What that reasoning did not anticipate is
that the *live* surface would stop supplying the family its own palette was tuned for — at which
point "each surface picks its own appearance" stops being an asymmetry and becomes a way for the
preview and the thing it previews to disagree.

## Decision

### D1. One function decides the appearance for every popup bar

`PopupBarView.withBarAppearance(matching:)` takes an appearance, keeps only its **light/dark side**,
and runs the body in the *vibrant* variant of that side. Every popup-bar render goes through it: the
live `draw(_:)`, the dropdown style tile
([`DropdownBarStylePreviewRenderer`](../../Sources/TokenPace/Settings/DropdownBarStylePreviewRenderer.swift)),
and the Legend specimen ([`LegendRenderer`](../../Sources/TokenPace/Settings/LegendRenderer.swift)).

### D2. The family is pinned; the light/dark side is not

The bar still follows the system's light/dark setting — that is read from the caller's appearance.
What the bar no longer takes from its host is the appearance *family*, because the palette's
calibration depends on it and the host is not a reliable source of it.

### D3. A specimen may choose its side, never its family

`DropdownBarStylePreviewRenderer` and `LegendRenderer` keep their `appearance` parameter, so a caller
can bake a specific theme in one process (`NSApp.appearance` does not take effect until the run loop
turns). They pass it *through* D1 rather than applying it directly.

## Consequences

A tile can no longer advertise a tone the dropdown does not draw, which is the only property that
makes the preview worth having ([ADR-0083](0083-live-dropdown-preview-in-settings.md) states the
same requirement for the live dropdown preview: a preview reading lighter than the live menu "is the
one thing a preview must never do").

**The popup bar is now insulated from its host's appearance, and that cuts both ways.** If Apple
later gives `NSMenu` content a vibrant appearance again, or moves the popup to a surface where the
flat family is genuinely the right one, this seam will keep pinning vibrant and will have to be
revisited deliberately. The measured table above is what a future reader needs to re-derive the
decision; the alternative — inheriting the host's family — is what just broke.

**A real menu is a vibrant surface and the pin matches it**, so this is not a cosmetic override of
the platform. But it is a claim about a platform behaviour, and it is pinned in code rather than
observed at runtime. Observing it was the previous design.

**Three call sites must keep going through one function**, and nothing enforces that. A fourth
renderer added later can call `performAsCurrentDrawingAppearance` itself and silently reintroduce
the split. The seam's doc comment says so; there is no test.

## Alternatives considered

**Correct the ring's colour instead.** Rejected: the ring is not the only thing built from
`monochromeGrey` — the bar's own track is too. Fixing the ring would leave the track resolving in
whichever family the host supplied, so the two would drift apart in a way nobody is looking at.

**Have the live bar pass its host's appearance to the specimens.** This equalises the two surfaces
without pinning anything, and it was the shape the code already had. Rejected: it equalises them on
whatever the host gives, so both surfaces would have inverted together on macOS 27 and the bug would
have been invisible rather than fixed.

**Build `monochromeGrey` from `labelColor` with an explicit alpha**, as `zeroTick` and `barTrack`
already do, so the tone no longer depends on the family. Rejected for now: it changes the shipped
track tone on every surface, which is a calibration change needing its own measurement pass against
Digital Color Meter ([CLAUDE.md](../../CLAUDE.md) — no screenshot is a source of colour). It remains
the cleaner long-term shape.

## Verification

Cause and fix were both measured on a live process, not read off the source:

- `NSLog` inside `draw(_:)` on the `screenshot` stub reported
  `currentDrawing=NSAppearanceNameDarkAqua effective=NSAppearanceNameDarkAqua grey=255,255,255 a=0.173`.
- The per-appearance table above came from a standalone AppKit probe resolving the same expression
  under all four appearances.
- The maintainer confirmed the live dropdown after the change.

## Related

- [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) — the style tiles are rendered at
  runtime by the real bar code; §2 is partially superseded here.
- [ADR-0083](0083-live-dropdown-preview-in-settings.md) — the live dropdown preview in Settings, and
  the rule that a preview must not read lighter than the surface it previews.
- [ADR-0093](0093-bar-style-picked-by-picture.md) — the picker's shape.
