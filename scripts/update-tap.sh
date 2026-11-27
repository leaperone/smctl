#!/bin/bash
# Writes Casks/pulse.rb and Formula/pulse-cli.rb for <version> into a clone of
# the Homebrew tap (fstormacq/homebrew-tap), from packaging/homebrew/*.rb.in and
# the checksums in dist/release/SHA256SUMS. Committing and pushing is left to
# the caller.
#   scripts/update-tap.sh <x.y.z> <tap-directory>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: scripts/update-tap.sh <x.y.z> <tap-directory>}"
TAP="${2:?usage: scripts/update-tap.sh <x.y.z> <tap-directory>}"
SUMS="$ROOT/dist/release/SHA256SUMS"

checksum() {
    local sum
    sum="$(awk -v file="$1" '$2 == file { print $1 }' "$SUMS")"
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { echo "error: no checksum for $1 in $SUMS" >&2; exit 1; }
    echo "$sum"
}
APP_SUM="$(checksum "Pulse-$VERSION.zip")"
CLI_SUM="$(checksum "pulse-cli-$VERSION-arm64.tar.gz")"

render() {
    sed -e "s/__VERSION__/$VERSION/g" -e "s/__SHA256_APP__/$APP_SUM/g" -e "s/__SHA256_CLI__/$CLI_SUM/g" "$1"
}
mkdir -p "$TAP/Casks" "$TAP/Formula"
cp "$ROOT/packaging/homebrew/README.md" "$TAP/README.md"
render "$ROOT/packaging/homebrew/pulse.rb.in" > "$TAP/Casks/pulse.rb"
render "$ROOT/packaging/homebrew/pulse-cli.rb.in" > "$TAP/Formula/pulse-cli.rb"
if grep -q "__" "$TAP/Casks/pulse.rb" "$TAP/Formula/pulse-cli.rb"; then
    echo "error: a placeholder was left unreplaced" >&2
    exit 1
fi
echo "Updated $TAP to $VERSION"
