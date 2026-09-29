#!/bin/bash
# build-app-icon.sh — compile design/app-icon/AppIcon.icon into the two files the bundle ships.
# Needs a full Xcode 26+ (actool). Run it only when the icon changes and commit the output, so
# build-app.sh keeps working on Command Line Tools alone. Assets.car is not byte-reproducible (two
# runs over the same source differ: actool puts per-run identifiers in rendition names — measured),
# so a re-run over an unchanged icon still shows a diff; don't commit one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/design/app-icon/AppIcon.icon"
OUT="${ROOT}/design/app-icon/compiled"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${ROOT}/scripts/Info.plist.in")"

xcrun --find actool >/dev/null 2>&1 \
    || { echo "error: actool not found; compiling a .icon needs a full Xcode 26+, not Command Line Tools" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A deployment target below 26 makes actool emit flattened renditions (16–1024 px) next to the
# layered icon inside Assets.car, plus an AppIcon.icns that carries only 16–256 px: it strips the
# larger sizes because the .car holds them.
#
# The grep drops dyld "symbol … missing from root" warnings about MediaToolbox, which Xcode 26's
# actool prints by the dozen on macOS 15 (measured) and which bury any real error.
xcrun actool "${SRC}" --compile "${TMP}" --app-icon AppIcon \
    --platform macosx --target-device mac --minimum-deployment-target "${MIN_OS}" \
    --include-all-app-icons --enable-on-demand-resources NO --development-region en \
    --output-partial-info-plist "${TMP}/partial.plist" \
    --errors --warnings --output-format human-readable-text \
    2> >(grep -v '^dyld\[' >&2 || true)

for f in Assets.car AppIcon.icns; do
    [ -s "${TMP}/${f}" ] || { echo "error: actool produced no ${f}" >&2; exit 1; }
done
mkdir -p "${OUT}"
cp "${TMP}/Assets.car" "${TMP}/AppIcon.icns" "${OUT}/"
echo "==> wrote ${OUT}/Assets.car and ${OUT}/AppIcon.icns (deployment target ${MIN_OS})"
