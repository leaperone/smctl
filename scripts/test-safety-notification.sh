#!/bin/bash
# Hardware test: trips the daemon's safety guard on purpose to check Pulse's
# notifications ("Temperature limit reached", then "Temperatures back to
# normal" with a Resume button). Run with sudo, with Pulse.app open:
#   sudo scripts/test-safety-notification.sh [profile] [path/to/pulse]
# The CLI defaults to `pulse` on the PATH (sudo's PATH has /usr/local/bin).
# The config is restored on exit, even after Ctrl-C.
set -euo pipefail

CONFIG=/etc/pulse/config.toml
PROFILE="${1:-$(sed -n -E 's/^profile = "(.*)"/\1/p' "$CONFIG" | head -1)}"
[[ -n "$PROFILE" && "$PROFILE" != auto ]] || PROFILE=balanced
PULSE="${2:-pulse}"
BACKUP="$(mktemp /tmp/pulse-config.XXXXXX)"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
cp "$CONFIG" "$BACKUP"

restore() {
    cp "$BACKUP" "$CONFIG"
    rm -f "$BACKUP"
    "$PULSE" daemon restart >/dev/null
    echo "Config restored, daemon restarted (the guard is released: expect the all-clear notification)."
}
trap restore EXIT

echo "1. Activating $PROFILE so fans are under Pulse's control…"
"$PULSE" fan profile "$PROFILE" >/dev/null
# A fixed ceiling fails on a cool Mac (a Mac mini idles near 35 °C), so it sits
# 3 °C below the hottest reading right now. Tp* hot-spots get +10 °C on top of
# the ceiling, so they count 10 °C lower.
CEILING="$("$PULSE" status --json | python3 -c '
import json, sys
temps = json.load(sys.stdin)["temperatures"]
hottest = max(t["celsius"] - (10 if t["key"].startswith("Tp") else 0) for t in temps)
print(max(int(hottest) - 3, 20))')"
echo "2. Lowering the safety ceiling to $CEILING °C (any sensor above it trips the guard)…"
sed -i '' -E "s/^temp_ceiling = .*/temp_ceiling = $CEILING.0/" "$CONFIG"
"$PULSE" daemon restart >/dev/null
"$PULSE" fan profile "$PROFILE" >/dev/null

echo "3. Waiting for the guard (about 2 s)…"
for _ in $(seq 1 20); do
    if "$PULSE" status 2>/dev/null | grep -qi "latched"; then break; fi
    sleep 1
done
"$PULSE" status | grep -i -E "safety|latch|profile" || true
echo
echo "→ A 'Temperature limit reached' notification should be on screen."
read -r -p "Press Return to restore the config…"
