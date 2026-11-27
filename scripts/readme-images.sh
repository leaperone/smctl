#!/bin/bash
# Regenerates the README's screenshots (assets/img/*-{light,dark}.png) from the
# current code, with PulseSnapshots' sample data: run it after a visible change.
#   scripts/readme-images.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHOTS="$(mktemp -d)"
trap 'rm -rf "$SHOTS"' EXIT

swift run --package-path "$ROOT/App" PulseSnapshots "$SHOTS" >/dev/null

# README image ← PulseSnapshots output
MAPPING=(
    "popover:popover"
    "menubar-stacked:menubar-stacked-cpu-fan"
    "menubar-heartbeat:menubar-heartbeat-stacked"
    "menubar-pulse:menubar-pulse-only"
    "menubar-beats:beats"
    "curves:curves"
    "editor:settings-curves-points"
    "stress-test:stress-test"
)
for pair in "${MAPPING[@]}"; do
    target="${pair%%:*}" source="${pair#*:}"
    for scheme in light dark; do
        cp "$SHOTS/$source-$scheme.png" "$ROOT/assets/img/$target-$scheme.png"
    done
    echo "assets/img/$target-{light,dark}.png ← $source"
done

# Every image the README shows must exist in both appearances.
missing=0
for image in $(grep -o 'assets/img/[a-z-]*-light\.png' "$ROOT/README.md" | sort -u); do
    [[ -f "$ROOT/${image/-light/-dark}" ]] || { echo "error: ${image/-light/-dark} is missing" >&2; missing=1; }
done
exit $missing
