#!/bin/bash
# Logs what macOS publishes while Game Mode turns on/off. Launch a game in
# full screen, wait for "Game Mode on", quit it, then press Ctrl-C.
LOG="${1:-$HOME/Desktop/gamemode-probe.log}"
: > "$LOG"
for name in com.apple.gamepolicy.game-mode-session com.apple.gamepolicy.game-session \
            com.apple.gamepolicy.fullscreenStateChanged com.apple.gamepolicy.GameExited; do
  (while true; do notifyutil -1 "$name" >/dev/null 2>&1 && echo "$(date +%T) notify $name" >> "$LOG"; done) &
done
trap 'kill $(jobs -p) 2>/dev/null; echo "Saved to $LOG"; exit' INT
while true; do
  keys=$(printf 'list .*[Gg]ame.*\n' | scutil | grep -v "no keys")
  [ -n "$keys" ] && { echo "$(date +%T) scutil:"; echo "$keys"; for k in $(echo "$keys" | awk '{print $NF}'); do printf 'show %s\n' "$k" | scutil; done; } >> "$LOG"
  echo "$(date +%T) front: $(lsappinfo info -only bundleid "$(lsappinfo front)" 2>/dev/null)" >> "$LOG"
  sleep 3
done
