#!/bin/bash
# Hardware test: trips the daemon's safety guard on purpose to check Pulse's
# notifications ("Temperature limit reached", then "Temperatures back to
# normal" with a Resume button). Run with sudo, with Pulse.app open:
#   sudo scripts/test-safety-notification.sh [profile]
# The config is restored on exit, even after Ctrl-C.
set -euo pipefail

CONFIG=/etc/pulse/config.toml
PROFILE="${1:-$(sed -n -E 's/^profile = "(.*)"/\1/p' "$CONFIG" | head -1)}"
[[ -n "$PROFILE" && "$PROFILE" != auto ]] || PROFILE=balanced
BACKUP="$(mktemp /tmp/pulse-config.XXXXXX)"

[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
cp "$CONFIG" "$BACKUP"

restore() {
    cp "$BACKUP" "$CONFIG"
    rm -f "$BACKUP"
    pulse daemon restart >/dev/null
    echo "Config restored, daemon restarted (the guard is released: expect the all-clear notification)."
}
trap restore EXIT

echo "1. Activating $PROFILE so fans are under Pulse's control…"
pulse fan profile "$PROFILE" >/dev/null
echo "2. Lowering the safety ceiling to 45 °C (any sensor above it trips the guard)…"
sed -i '' -E 's/^temp_ceiling = .*/temp_ceiling = 45.0/' "$CONFIG"
pulse daemon restart >/dev/null
pulse fan profile "$PROFILE" >/dev/null

echo "3. Waiting for the guard (about 2 s)…"
for _ in $(seq 1 20); do
    if pulse status 2>/dev/null | grep -qi "latched"; then break; fi
    sleep 1
done
pulse status | grep -i -E "safety|latch|profile" || true
echo
echo "→ A 'Temperature limit reached' notification should be on screen."
read -r -p "Press Return to restore the config…"
