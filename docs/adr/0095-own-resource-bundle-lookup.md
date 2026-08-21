---
status: accepted
date: 2026-08-14
supersedes: []
superseded_by: []
---

# ADR-0095: We look up the resource bundle ourselves, not through `Bundle.module`

> Added later: **the sole consumer of this decision is gone.**
> [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) switched the bar-style preview to a
> runtime render, so the three PNGs, the resource bundle, and `BarStylePicker.resourceBundle`
> itself were all removed — the app has no resources left at all.
>
> **The rule still stands**, and the ADR isn't superseded: it applies to any **future** resource,
> not just those pictures. The moment resources are needed again, they must be read the way
> described here, not through `Bundle.module` — otherwise the same crash in `.app` repeats. That's
> exactly why the wording in [conventions.md](../reference/conventions.md) is phrased
> conditionally.

## Context

Release 0.94.0 crashed in the installed `.app` when opening `Settings → Appearance`. The crash
report (`EXC_BREAKPOINT`, main thread) points to the line where any investigation ends:

```
0  libswiftCore.dylib  _assertionFailure(_:_:file:line:flags:)
1  TokenPace           closure #1 in variable initialization expression of static NSBundle.module
2  TokenPace           one-time initialization function for module
...
5  TokenPace           closure #1 in variable initialization expression of static BarStylePicker.images
9  TokenPace           closure #1 in closure #1 in closure #2 in BarStylePicker.tile(for:title:)
13 TokenPace           BarStylePicker.tile(for:title:)
```

What crashed wasn't our code but the **SwiftPM-generated accessor** `Bundle.module`, which
`BarStylePicker.images` calls the first time the bar-style picker draws
([ADR-0093](0093-bar-style-picked-by-picture.md)). Here it is, verbatim, from
`.build/…/DerivedSources/resource_bundle_accessor.swift`:

```swift
let mainPath = Bundle.main.bundleURL.appendingPathComponent("TokenPace_TokenPace.bundle").path
let buildPath = "/Users/artem/devel/cc-timer/.build/arm64-apple-macosx/debug/TokenPace_TokenPace.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else {
    Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
}
```

Both candidates are wrong in a real `.app`:

- For an app, `Bundle.main.bundleURL` is `/Applications/TokenPace.app` **itself**, so `mainPath`
  points at `/Applications/TokenPace_TokenPace.bundle` — i.e. **next to** the app. Resources
  cannot live there in a `.app`: their place is `Contents/Resources/`, which is exactly where
  `scripts/build-app.sh` puts them.
- `buildPath` is an absolute path into the `.build/` directory **of the machine that built it**,
  and a `debug` configuration at that. That directory doesn't exist on a user's Mac.

Both missing → `fatalError`. Measurement confirms this directly: `Bundle(path:)` at the SPM path
returns `nil`, while at the real `Contents/Resources/` path it opens the bundle, and all three
PNGs load (`bar-style-{pressure,gauge,progress}`, 54×33).

Why this shipped: under `swift run`, the bundle really does sit right next to the binary, so
`mainPath` hits, and the picker works flawlessly in dev mode. The check "was the bundle copied
into `.app`," added alongside ADR-0093, also passed — the bundle **was** in place. The false
assumption was that `Bundle.module` would look for it there.

## Decision

**Don't use `Bundle.module`.** `BarStylePicker` resolves the bundle itself —
`BarStylePicker.resourceBundle`: `Contents/Resources/` (the `.app` layout), then next to the
`.app`, then next to the executable (the `swift run` layout).

Two consequences of this choice:

- **A miss returns `nil` instead of killing the process.** A decorative preview has no business
  taking the app down: without the pictures the tiles stay clickable, and picking a style still
  works. A `fatalError` in code that runs while drawing the Settings pane is an unacceptable price
  for a missing PNG.
- **The candidate order starts with `Contents/Resources/`** — the layout the app actually ships to
  users in, not the dev-mode one.

On top of that, `scripts/build-app.sh` now checks not just that the bundle directory exists, but
that it holds **at least three PNGs** (one per `BarStyle`). An empty directory gets copied by
`cp -R` without error and would only have shown up in the UI.

## Consequences

**This applies to any future resource**, not just these three pictures: the moment resources are
needed anywhere else, they must be read the same way, not through `Bundle.module`. The convention
is recorded in [conventions.md](../reference/conventions.md).

**The cost is custom code instead of the standard mechanism.** Renaming the target or the package
changes the bundle's name, and the `"TokenPace_TokenPace.bundle"` constant will have to be updated
by hand — `Bundle.module` would have been generated automatically. This is a deliberate trade-off:
an accessor that automatically points at the wrong place and crashes is worse than a constant you
can see.

**The last candidate is `Bundle.main`.** If resources are ever placed flat inside the `.app`
itself, the lookup will still succeed instead of returning `nil`.

**What this doesn't fix:** tests of this class of defect can't catch it in principle — they run in
a layout where the SPM path happens to hit. The only check that catches it is launching the built
`.app`, exactly as [ui-verification.md](../guides/ui-verification.md) requires.
