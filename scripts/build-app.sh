#!/bin/bash
# Builds dist/Pulse.app: the menu bar app with the pulse CLI and the pulsed
# daemon bundled in Contents/Helpers, ad-hoc signed.
#   scripts/build-app.sh
# The version comes from Sources/ProductIdentity/PulseVersion.swift (set it first
# with scripts/set-version.sh for a release); a plain build is 0.0.0-dev.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -gt 0 ]]; then
    echo "error: build-app.sh no longer takes a version; run scripts/set-version.sh $1 first" >&2
    exit 1
fi
VERSION="$("$ROOT/scripts/set-version.sh")"
# CFBundleShortVersionString must be numeric; the full version is shown by the app itself.
SHORT_VERSION="${VERSION%%-*}"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
APP="$ROOT/dist/Pulse.app"
CONTENTS="$APP/Contents"

# SwiftUI's macros (@State, …) ship only with Xcode, not the Command Line Tools.
# Use Xcode for this build if the active developer directory is the CLT.
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" != *.app/Contents/Developer ]]; then
    XCODE="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -n 1)"
    [[ -z "$XCODE" && -d /Applications/Xcode.app ]] && XCODE=/Applications/Xcode.app
    if [[ -z "$XCODE" ]]; then
        echo "error: Pulse needs Xcode 26 or later; the Command Line Tools alone can't build the app." >&2
        echo "       Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
        exit 1
    fi
    export DEVELOPER_DIR="$XCODE/Contents/Developer"
    echo "==> Active developer directory is ${DEV_DIR:-unset}; using $XCODE for this build"
    echo "    (to make it the default: sudo xcode-select -s $DEVELOPER_DIR)"
fi

echo "==> Building pulse and pulsed"
swift build -c release --package-path "$ROOT"
echo "==> Building Pulse"
swift build -c release --package-path "$ROOT/App" --product Pulse

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp "$ROOT/App/.build/release/Pulse" "$CONTENTS/MacOS/Pulse"
cp "$ROOT/.build/release/pulse" "$ROOT/.build/release/pulsed" "$CONTENTS/Helpers/"
# SwiftPM resource bundles, if any target gains resources.
find "$ROOT/App/.build/release" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$CONTENTS/Resources/" \;
sed -e "s/__VERSION__/$SHORT_VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/App/Resources/Info.plist" > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "==> Icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/assets/img/logo.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ROOT/assets/img/logo.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

echo "==> Signing (ad hoc)"
codesign --force --sign - --options runtime "$CONTENTS/Helpers/pulsed"
codesign --force --sign - --options runtime "$CONTENTS/Helpers/pulse"
codesign --force --sign - --options runtime "$APP"
codesign --verify --strict "$APP"

echo "Built $APP ($VERSION, build $BUILD)"
