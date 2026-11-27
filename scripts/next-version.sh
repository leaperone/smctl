#!/bin/bash
# Prints the version the next release should have, from the commit messages
# since the last release tag (vX.Y.Z), or nothing when no release is due.
#   feat        → minor        fix, perf          → patch
#   type!: …    → major        BREAKING CHANGE:   → major
#   docs, ci, test, chore, refactor, style, build alone → no release
# With no release tag yet, the first version is $INITIAL_VERSION (1.0.0).
set -euo pipefail
cd "$(dirname "$0")/.."

INITIAL_VERSION="${INITIAL_VERSION:-1.0.0}"
last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"
if [[ -z "$last" ]]; then
    echo "$INITIAL_VERSION"
    exit 0
fi

# Merge commits ("Merge pull request #…") carry no type; the merged commits do.
subjects="$(git log --no-merges --format='%s' "$last..HEAD")"
bodies="$(git log --no-merges --format='%b' "$last..HEAD")"
type='[a-z]+(\([^)]*\))?'
if grep -Eq "^$type!:" <<<"$subjects" || grep -Eq '^BREAKING[ -]CHANGE:' <<<"$bodies"; then
    bump=major
elif grep -Eq '^feat(\([^)]*\))?:' <<<"$subjects"; then
    bump=minor
elif grep -Eq '^(fix|perf)(\([^)]*\))?:' <<<"$subjects"; then
    bump=patch
else
    exit 0
fi

IFS=. read -r major minor patch <<<"${last#v}"
case "$bump" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
esac
