#!/bin/bash
# Writes the product version into Sources/ProductIdentity/PulseVersion.swift,
# or prints the current one. Used by the release build; the result is not committed.
#   scripts/set-version.sh            # print the current version
#   scripts/set-version.sh 1.2.3      # set it
#   scripts/set-version.sh --dev      # back to the development value
set -euo pipefail

FILE="$(cd "$(dirname "$0")/.." && pwd)/Sources/ProductIdentity/PulseVersion.swift"
DEV="0.0.0-dev"

current() { sed -n 's/^ *public static let version = "\(.*\)"$/\1/p' "$FILE"; }

case "${1:-}" in
    "") current; exit 0 ;;
    --dev) VERSION="$DEV" ;;
    *) VERSION="$1" ;;
esac

if [[ "$VERSION" != "$DEV" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: '$VERSION' is not a release version (expected x.y.z)" >&2
    exit 1
fi
sed -i '' "s/^\( *public static let version = \)\".*\"$/\1\"$VERSION\"/" "$FILE"
[[ "$(current)" == "$VERSION" ]] || { echo "error: could not write the version into $FILE" >&2; exit 1; }
echo "$VERSION"
