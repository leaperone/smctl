#!/bin/bash
# Builds the release assets for one version into dist/release/:
#   Pulse-<version>.zip                 the app, with pulse and pulsed in Contents/Helpers
#   pulse-cli-<version>-arm64.tar.gz    pulse and pulsed alone (Homebrew formula pulse-cli)
#   SHA256SUMS
#   scripts/package.sh <x.y.z>
# The version is written into the sources for the build and set back to the
# development value afterwards, even on failure: it is never committed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/package.sh <x.y.z>}"
OUT="$ROOT/dist/release"

"$ROOT/scripts/set-version.sh" "$VERSION" >/dev/null
trap '"$ROOT/scripts/set-version.sh" --dev >/dev/null' EXIT

"$ROOT/scripts/build-app.sh"

APP="$ROOT/dist/Pulse.app"
BUILT="$("$APP/Contents/Helpers/pulse" --version)"
[[ "$BUILT" == "$VERSION" ]] || { echo "error: the app's pulse reports $BUILT, expected $VERSION" >&2; exit 1; }

echo "==> Packaging $VERSION into $OUT"
rm -rf "$OUT" && mkdir -p "$OUT"
# ditto keeps the bundle's signatures and extended attributes intact.
ditto -c -k --keepParent "$APP" "$OUT/Pulse-$VERSION.zip"

CLI="pulse-cli-$VERSION"
STAGE="$(mktemp -d)"
mkdir "$STAGE/$CLI"
# The signed copies from the app bundle: the same binaries in both assets.
cp "$APP/Contents/Helpers/pulse" "$APP/Contents/Helpers/pulsed" "$ROOT/LICENSE" "$STAGE/$CLI/"
tar -C "$STAGE" -czf "$OUT/$CLI-arm64.tar.gz" "$CLI"
rm -rf "$STAGE"

(cd "$OUT" && shasum -a 256 "Pulse-$VERSION.zip" "$CLI-arm64.tar.gz" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
