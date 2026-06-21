#!/bin/bash
# build-app.sh — assemble cc-timer.app from a release SwiftPM build.
# CLT-only friendly; no full Xcode required.
# Signs with Developer ID when available; produces an unsigned app otherwise.
# Output: ./build/cc-timer.app  (already covered by .gitignore)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="cc-timer"
OUT_DIR="${ROOT}/build"
APP="${OUT_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"
PLIST_IN="${ROOT}/scripts/Info.plist.in"

# Version from VERSION file (strip whitespace); build number from git commit count.
VERSION="$(tr -d ' \t\n\r' < "${ROOT}/VERSION")"
BUILD="$(git -C "${ROOT}" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> swift build -c release (this may take a while on first run)"
swift build --package-path "${ROOT}" -c release 2>&1 | tee /tmp/cc-timer-build.log

BIN_DIR="$(swift build --package-path "${ROOT}" -c release --show-bin-path)"
BIN="${BIN_DIR}/${APP_NAME}"
[ -x "${BIN}" ] || { echo "error: built binary not found at ${BIN}" >&2; exit 1; }

echo "==> assembling ${APP}  (version ${VERSION}, build ${BUILD})"
rm -rf "${APP}"
mkdir -p "${MACOS_DIR}" "${RES_DIR}"
cp "${BIN}" "${MACOS_DIR}/${APP_NAME}"

# Info.plist with version/build substituted from template.
sed -e "s/__VERSION__/${VERSION}/g" -e "s/__BUILD__/${BUILD}/g" \
    "${PLIST_IN}" > "${CONTENTS}/Info.plist"

# PkgInfo — legacy but harmless; content is APPL + four question marks.
printf 'APPL????' > "${CONTENTS}/PkgInfo"

# Validate the generated plist (fail fast on malformed XML).
plutil -lint "${CONTENTS}/Info.plist"

# --- Optional code signing (only when a Developer ID Application identity exists) ---
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -oE '"Developer ID Application: [^"]+"' | head -1 | tr -d '"' || true)"

if [ -n "${IDENTITY}" ]; then
    echo "==> codesign --options runtime  (identity: ${IDENTITY})"
    codesign --force --options runtime --timestamp \
             --sign "${IDENTITY}" "${APP}"
    codesign --verify --strict --verbose=2 "${APP}"

    # --- Optional notarization (requires a stored notarytool keychain profile) ---
    # Create the profile once with:
    #   xcrun notarytool store-credentials cc-timer-notary --apple-id <id> --team-id <TEAMID>
    if xcrun notarytool history --keychain-profile cc-timer-notary >/dev/null 2>&1; then
        echo "==> notarize (notarytool submit --wait); this can take several minutes"
        ZIP="${OUT_DIR}/${APP_NAME}.zip"
        ditto -c -k --keepParent "${APP}" "${ZIP}"
        xcrun notarytool submit "${ZIP}" \
              --keychain-profile cc-timer-notary --wait
        xcrun stapler staple "${APP}"
        rm -f "${ZIP}"
        echo "==> notarization complete"
    else
        echo "==> notarization skipped (no 'cc-timer-notary' notarytool profile found)"
    fi
else
    echo "==> signing skipped (no Developer ID identity found) — producing UNSIGNED app"
    echo "    Gatekeeper tip: right-click -> Open, or:"
    echo "    xattr -dr com.apple.quarantine \"${APP}\""
fi

echo ""
echo "==> done: ${APP}  (version ${VERSION}, build ${BUILD})"
