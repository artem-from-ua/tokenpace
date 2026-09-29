---
status: accepted
date: 2026-09-29
---

# ADR-0134: The app icon ships as a committed `actool` build of an Icon Composer source, with Liquid Glass off

## Context

The bundle had no icon, so Finder, Spotlight, notifications, About and the Dock (while Settings is
open) showed the generic app. [#163](https://github.com/artem-from-ua/tokenpace/issues/163) asked
for an `.icns` assembled from an iconset with `iconutil`. The artwork — the widget itself at its own
proportions, calm white over ahead-of-pace orange, flat on a near-black squircle — came out of that
issue's concept round. This record is about how it is built and shipped, not the design.

Three forces pushed against the `.icns` plan:

- **macOS 26 treats an `.icns`-only icon as legacy.** It renders smaller than native icons, and on a
  grey backplate unless the artwork matches the system shape exactly
  ([Michael Tsai](https://mjtsai.com/blog/2025/08/08/separate-icons-for-macos-tahoe-vs-earlier/),
  [9to5Mac](https://9to5mac.com/2025/08/08/macos-tahoe-fix-gray-box-icons/)). A layered icon in
  `Assets.car`, named by `CFBundleIconName`, gets native size and the light, dark, tinted and clear
  appearances.
- **Compiling a layered icon needs `actool` from a full Xcode 26+.** The release build runs on
  Command Line Tools alone ([ADR-0004](0004-build-system.md)), and the maintainer's release machine
  has no Xcode.
- **Icon Composer's default Liquid Glass changes the art.** It bevels the bars into the glossy 3D look
  the concept round dropped, and dulls the orange to mustard (seen in `ictool` renders).

The icon is also a resource, which [conventions.md](../reference/conventions.md#resources-images-and-the-like)
asks to draw in code where possible. That rule covers images the app reads. The system reads this one
from `Info.plist`, including for an app that is not running, so there is no code to draw it in.

## Decision

### D1. An Icon Composer source, shipped as `Assets.car` plus an `.icns` fallback

[`design/app-icon/AppIcon.icon`](../../design/app-icon/AppIcon.icon/icon.json) holds three
full-bleed 1024×1024 SVG layers (tracks, pacing gaps, time markers) with no mask, since the system
applies the squircle, and a solid `#161618` fill in `icon.json`. `actool`, given the deployment
target from `Info.plist.in` (15.0), compiles it into:

- `Assets.car`, read through `CFBundleIconName`: the layered icon for macOS 26+, plus flattened
  16–1024 px renditions that macOS 15 uses.
- `AppIcon.icns`, read through `CFBundleIconFile`: a fallback holding only 16–256 px, because
  `actool` leaves the larger sizes to the `.car`.

The `.car` is the complete icon. The `.icns` alone has nothing above 256 px, so dropping the `.car`
"to keep it simple" loses the large sizes on every macOS version.

### D2. Compiled once, output committed

[`scripts/build-app-icon.sh`](../../scripts/build-app-icon.sh) runs `actool` and writes both files
to `design/app-icon/compiled/`, which is committed.
[`scripts/build-app.sh`](../../scripts/build-app.sh) only copies them into `Contents/Resources/`
before `codesign` and fails if either is missing or empty. Only changing the icon needs Xcode.

`Assets.car` is not byte-reproducible: `actool` puts per-run identifiers in rendition names
(measured), so two runs over the same source differ. Recompile only when the source changed, and
commit `design/app-icon/` as one unit.

### D3. Liquid Glass off on every layer

Each layer in `icon.json` carries `"glass": false`. The bars stay flat and keep the widget's
colours; the system still draws the squircle rim and the edge shadow.

## Consequences

**Binaries live in git, and their diff says nothing.** A reviewer cannot tell from a `.car` diff
whether it matches the source. The check is `assetutil --info` against `icon.json`: the background
colour, `PlatformVersion`, and the Xcode that built it.

**An SVG edit without a recompile ships the old icon, silently.** `build-app.sh` asserts the
compiled files exist, not that they are current.

**The Xcode that compiles it matters.** The committed build comes from Xcode 26.3. There are
unverified reports that icons from the Xcode 27 tools do not read on macOS 26, so a recompile with 27
has to be checked on a 26 machine.

**The icon is a second drawing of the widget, and nothing ties the two together.** If the bar anatomy
changes, the icon keeps the old one until someone redraws it — the silent divergence conventions.md
warns about, accepted here because the system renders this image, not the app.

## Verification

- **macOS 15.7.9, Xcode 26.3.** `assetutil --info` lists the layered stack (`NSAppearanceNameAqua`,
  `NSAppearanceNameDarkAqua`, `ISAppearanceTintable`), the three vector layers and flattened
  renditions from 16 to 1024. A probe bundle holding only the `.car` and `CFBundleIconName` returned
  the icon from `NSWorkspace.icon(forFile:)` at every size up to 1024@2x, so macOS 15 reads it from
  the `.car` alone. `ictool` renders `Default`, `Dark`, `TintedLight` and `ClearDark` legibly.
- **macOS 27.0.1, Command Line Tools only**
  ([maintainer's check](https://github.com/artem-from-ua/tokenpace/pull/552#issuecomment-5893593203)).
  `build-app.sh` end to end: signed, notarized, stapled, `spctl` accepting it as
  `Notarized Developer ID`. The opaque squircle measures 1648×1648 on a 2048 canvas, inset 200 on
  every side, identical to `Notes.app` to the pixel, and the same at 512 and 32 px; no grey backplate.
  Finder, Spotlight, Get Info, the Dock with Settings open, and About all show it. The committed
  `.car` carries `#161618`, `PlatformVersion 15.0`, and Xcode 26.3 as its builder.
- **Not verified live:** the tinted and clear appearances on macOS 26+, only as `ictool` renders.

## Related

- [ADR-0004](0004-build-system.md) — SwiftPM plus a build script; why the release build cannot call
  `actool`.
- [ADR-0097](0097-bar-style-preview-rendered-at-runtime.md) — the case behind the draw-in-code rule
  that this icon cannot follow.
- [building.md § The app icon](../guides/building.md#the-app-icon) — editing, recompiling and
  rendering it.
