#!/bin/bash
# Writes the release notes for <version> (Markdown) on stdout:
#   docs/release-notes/<version>.md when it exists, then the commits since the
#   previous release tag grouped by type, then how to install and update.
#   scripts/release-notes.sh <x.y.z>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release-notes.sh <x.y.z>}"
REPO="fstormacq/pulse"
last="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true)"

if [[ -f "docs/release-notes/$VERSION.md" ]]; then
    cat "docs/release-notes/$VERSION.md"
    echo
fi

# "feat(app): label the axis" → "- **app**: label the axis (abc1234)"
section() {
    local title="$1" pattern="$2" lines
    lines="$(git log --no-merges --format='%s%x09%h' "$last..HEAD" | grep -E "^($pattern)(\([^)]*\))?!?:" \
        | sed -E 's/^[a-z]+\(([^)]*)\)!?: (.*)\t(.*)$/- **\1**: \2 (\3)/; s/^[a-z]+!?: (.*)\t(.*)$/- \1 (\2)/' || true)"
    [[ -n "$lines" ]] || return 0
    printf '## %s\n\n%s\n\n' "$title" "$lines"
}

if [[ -n "$last" ]]; then
    section "New" "feat"
    section "Fixes" "fix"
    section "Performance" "perf"
    echo "**Full changelog**: https://github.com/$REPO/compare/$last...v$VERSION"
    echo
fi

cat <<NOTES
## Install

\`\`\`sh
brew tap fstormacq/tap && brew trust fstormacq/tap
brew install --cask fstormacq/tap/pulse     # the menu bar app, with the pulse CLI
brew install fstormacq/tap/pulse-cli        # or: the pulse CLI and its daemon only (SSH, headless Macs)
\`\`\`

Or download \`Pulse-$VERSION.zip\` below and move Pulse to Applications. Pulse is not notarized:
the first time, open it from **System Settings › Privacy & Security › Open Anyway**.

## Update

\`brew upgrade --cask fstormacq/tap/pulse\` or \`brew upgrade fstormacq/tap/pulse-cli\`. The fan control service updates itself:
Pulse asks for your password once when it starts, or \`pulse\` does on its next command.

Requires an Apple silicon Mac; the app needs macOS 26 or later, the CLI macOS 14 or later.
NOTES
