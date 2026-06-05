#!/bin/bash
# Build, sign, and (optionally) notarize a release.
#
# Usage:
#   scripts/release.sh                          # build + sign
#   NOTARY_PROFILE=<profile> scripts/release.sh # build + sign + notarize
#
# Notarization expects a notarytool keychain profile created once via:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id 5UAHRS482C --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Zhuhai Zhiwei Network Technology Co., Ltd. (5UAHRS482C)}"
VERSION=$(.build/release/smctl --version 2>/dev/null || true)

echo "==> swift build -c release"
swift build -c release

VERSION=$(.build/release/smctl --version)
ARTIFACT="smctl-${VERSION}-arm64"
DIST="dist/${ARTIFACT}"

echo "==> codesign (hardened runtime + timestamp)"
for bin in smctl smctld; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" ".build/release/${bin}"
  codesign --verify --strict ".build/release/${bin}"
done
codesign --display --verbose=2 .build/release/smctld 2>&1 | grep -E "TeamIdentifier|Authority=Developer"

echo "==> package"
rm -rf "$DIST" && mkdir -p "$DIST"
cp .build/release/smctl .build/release/smctld LICENSE "$DIST/"
ditto -c -k --keepParent "$DIST" "${DIST}.zip"
shasum -a 256 "${DIST}.zip"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> notarize (profile: ${NOTARY_PROFILE})"
  xcrun notarytool submit "${DIST}.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "Note: bare executables inside a zip cannot be stapled; Gatekeeper validates the notarization online."
else
  echo "==> notarization skipped (set NOTARY_PROFILE to enable)"
fi

echo "==> done: ${DIST}.zip"
