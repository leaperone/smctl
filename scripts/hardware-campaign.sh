#!/bin/bash
# Hardware test campaign (step 4e). Run in Terminal, on each Mac, with Pulse.app
# open and the service installed:
#
#   scripts/hardware-campaign.sh             all tests, in order
#   scripts/hardware-campaign.sh 3 5 9       only these tests
#   scripts/hardware-campaign.sh --list      list the tests
#   scripts/hardware-campaign.sh --after-reboot   second half of the reboot test
#
# Automatic checks run on their own; the script asks when a step needs you
# (a click, unplugging the charger, the password for sudo). Results go to
# docs/campaign/<model>-<date>.md, one row per test, with measurements.
# The profile and sensor intervals are restored on exit, even after Ctrl-C.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The running app (it may live in /Applications rather than dist/), and its
# CLI unless `pulse` is on the PATH.
APP="$(ps -o comm= -p "$(pgrep -x Pulse | head -1)" 2>/dev/null | sed -n 's|\(.*\.app\)/Contents/MacOS/Pulse$|\1|p')"
[[ -n "$APP" ]] || APP="$ROOT/dist/Pulse.app"
PULSE="$(command -v pulse || echo "$APP/Contents/Helpers/pulse")"
MODEL="$(sysctl -n hw.model)"
CHIP="$(sysctl -n machdep.cpu.brand_string)"
MACOS="$(sw_vers -productVersion)"
HAS_BATTERY=false
pmset -g batt | grep -q InternalBattery && HAS_BATTERY=true
HAS_FANS=true   # set from the daemon at start (MacBook Air: no fan)
RESULTS_DIR="$ROOT/docs/campaign"
RESULTS="${RESULTS:-$RESULTS_DIR/$MODEL-$(date +%Y-%m-%d).md}"
STATE="$HOME/Library/Caches/pulse-campaign-state"
LOAD_SECONDS="${LOAD_SECONDS:-90}"
COOL_SECONDS="${COOL_SECONDS:-90}"
IDLE_OFF_MINUTES="${IDLE_OFF_MINUTES:-30}"
CURVE="${CURVE:-balanced}"
CAMPAIGN_START="$(date '+%Y-%m-%d %H:%M:%S')"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ask() { printf '\n\033[1;34m→ %s\033[0m\n' "$*"; read -r -p "  Press Return when done (s to skip)… " REPLY; [[ "$REPLY" != s ]]; }
yesno() { local a; read -r -p "  $1 [y/n] " a; [[ "$a" == y* ]]; }

# JSON helpers: `status 'd["profile"]'` evaluates a Python expression on
# `pulse status --json` (d is the decoded object).
status() { "$PULSE" status --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print($1)" 2>/dev/null; }
profile() { status 'd.get("profile")'; }
DAEMON_PATH=/Library/PrivilegedHelperTools/com.stormacq.pulse.daemon
daemon_pid() { pgrep -f "^$DAEMON_PATH" | head -1; }
app_running() { pgrep -x Pulse >/dev/null; }
fan_modes() { status '",".join(f["mode"] for f in d["fans"])'; }
fan_rpms() { status '",".join(str(round(f.get("actualRPM") or 0)) for f in d["fans"])'; }
cpu_max() { status 'round(max([g["maximumCelsius"] for g in d["groups"] if g["label"]=="CPU"] or [0]),1)'; }
daemon_running() { [[ "$(status 'd["daemon"]["running"]')" == True ]]; }
latched() { status 'd["safety"]["latched"] if d.get("safety") else False'; }

# Wait up to $1 seconds for `$2` (a command) to succeed.
wait_for() { local t=$1; shift; for _ in $(seq 1 "$t"); do "$@" && return 0; sleep 1; done; return 1; }
is_profile() { [[ "$(profile)" == "$1" ]]; }

# Tests that drive fans are skipped on fanless Macs: `needs_fans 5 || return`.
needs_fans() {
    $HAS_FANS && return 0
    record "$1" "${TITLES[$(($1 - 1))]}" skip "Mac sans ventilateur"
    return 1
}

# MARK: Results

init_results() {
    mkdir -p "$RESULTS_DIR"
    if [[ ! -f "$RESULTS" ]]; then
        cat > "$RESULTS" <<EOF
# Campagne de tests matériels : $MODEL

- **Mac** : $MODEL, $CHIP, macOS $MACOS, batterie : $HAS_BATTERY, ventilateurs : $(status 'len(d["fans"])')
- **Pulse** : $("$PULSE" --version 2>/dev/null || echo "?"), daemon $(status 'd["daemon"].get("version")')
- **Début** : $CAMPAIGN_START

| # | Test | Résultat | Mesures et notes |
|---|---|---|---|
EOF
    fi
}

# record <id> <name> <pass|fail|skip|info> <notes>
record() {
    local mark
    case "$3" in pass) mark="✅ réussi";; fail) mark="❌ échec";; skip) mark="⏭️ sauté";; *) mark="ℹ️ $3";; esac
    printf '| %s | %s | %s | %s |\n' "$1" "$2" "$mark" "${4//|/\\|}" >> "$RESULTS"
    printf '  %s  %s\n' "$mark" "$4"
}

# MARK: Restore

ORIGINAL_PROFILE=""
ORIGINAL_INTERVAL=""
ORIGINAL_BATTERY_INTERVAL=""
LOAD_PIDS=()
FAKE_PID=""

save_state() {
    ORIGINAL_PROFILE="$(profile)"
    ORIGINAL_INTERVAL="$(status 'd.get("samplingInterval")')"
    ORIGINAL_BATTERY_INTERVAL="$("$PULSE" fan interval 2>/dev/null | sed -n -E 's/.*every ([0-9]+) s on battery.*/\1/p')"
}

restore() {
    for pid in "${LOAD_PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
    [[ -n "$FAKE_PID" ]] && kill "$FAKE_PID" 2>/dev/null
    rm -rf "${FAKE_DIR:-/nonexistent}" "${LOAD_DIR:-/nonexistent}"
    if [[ -n "$ORIGINAL_PROFILE" && "$ORIGINAL_PROFILE" != None ]]; then
        "$PULSE" fan profile "$ORIGINAL_PROFILE" >/dev/null 2>&1
    fi
    if [[ -n "$ORIGINAL_INTERVAL" && "$ORIGINAL_INTERVAL" != None ]]; then
        "$PULSE" fan interval "$ORIGINAL_INTERVAL" >/dev/null 2>&1
        "$PULSE" fan interval "${ORIGINAL_BATTERY_INTERVAL:-same}" --on-battery >/dev/null 2>&1
    fi
    app_running || open "$APP" --args -menuBarHeartbeat off
    echo
    bold "Restored: profile ${ORIGINAL_PROFILE:-?}, interval ${ORIGINAL_INTERVAL:-?} s. Results: $RESULTS"
}

# MARK: Tests

TESTS=(doctor profile_cli profile_app interval app_quit kill9 sleep_wake load conflict safety install idle_off reboot)
TITLES=(
    "Diagnostic et test d'écriture des ventilateurs"
    "Changement de profil par la CLI"
    "Changement de profil depuis l'app (et en SSH)"
    "Intervalle de collecte (et bascule sur batterie)"
    "Fermeture de l'app"
    "kill -9 du daemon"
    "Veille et réveil"
    "Charge soutenue (CPU et GPU)"
    "Outil concurrent"
    "Garde-fou provoqué et notifications"
    "Désinstallation et réinstallation du service"
    "Ventilateurs arrêtés, essai prolongé (Mac de bureau)"
    "Redémarrage du Mac"
)

t_doctor() {
    local json problems
    if $HAS_FANS; then
        info "pulse doctor --test-fans: each fan to 40 %, then the profile is restored."
        json="$("$PULSE" doctor --test-fans --json 2>/dev/null)"
    else
        info "pulse doctor (no fan: no write test)."
        json="$("$PULSE" doctor --json 2>/dev/null)"
    fi
    problems="$(echo "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("; ".join(c["name"]+": "+c["detail"] for c in d["checks"] if c["level"] in ("problem","warning")))')"
    local fans
    fans="$(echo "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); t=d.get("fanTest") or {}; print(", ".join("ventilateur %d : %d → %d RPM en %s s" % (f["index"], f["targetRPM"], f["reachedRPM"] or 0, round(f["secondsToSettle"], 1) if f.get("secondsToSettle") is not None else "—") for f in t.get("fans", [])) or "aucun ventilateur")')"
    local unlock
    unlock="$(echo "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["smc"]["expectedUnlockPath"])')"
    [[ -z "$problems" ]] && record 1 "${TITLES[0]}" pass "déblocage : $unlock ; $fans" \
                         || record 1 "${TITLES[0]}" fail "$problems ; $fans"
}

t_profile_cli() {
    needs_fans 2 || return
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    if wait_for 10 is_profile "$CURVE"; then
        sleep 4
        record 2 "${TITLES[1]}" pass "$CURVE actif ; ventilateurs : $(fan_modes) à $(fan_rpms) RPM ; CPU max $(cpu_max) °C"
    else
        record 2 "${TITLES[1]}" fail "profil resté sur $(profile)"
    fi
}

t_profile_app() {
    needs_fans 3 || return
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    if ask "Dans le popover de Pulse, clique sur le profil Silent."; then
        if wait_for 30 is_profile silent; then local app=ok; else local app="profil lu : $(profile)"; fi
    else
        local app=sauté
    fi
    local ssh_note
    if ssh -o BatchMode=yes -o ConnectTimeout=3 localhost true 2>/dev/null; then
        ssh localhost "$PULSE fan profile performance" >/dev/null 2>&1
        if wait_for 10 is_profile performance; then ssh_note="SSH ok"; else ssh_note="SSH : profil $(profile)"; fi
    else
        ssh_note="SSH non testé (Session à distance désactivée ou clé absente)"
    fi
    [[ "$app" == ok ]] && record 3 "${TITLES[2]}" pass "app ok ; $ssh_note" \
                       || record 3 "${TITLES[2]}" "$( [[ $app == sauté ]] && echo skip || echo fail )" "app : $app ; $ssh_note"
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
}

t_interval() {
    "$PULSE" fan interval 3 >/dev/null 2>&1
    local read_back; read_back="$(status 'd.get("samplingInterval")')"
    local notes="3 s relu : $read_back"
    local result=pass
    [[ "$read_back" == 3 ]] || result=fail
    if $HAS_BATTERY; then
        "$PULSE" fan interval 1 >/dev/null 2>&1
        "$PULSE" fan interval 5 --on-battery >/dev/null 2>&1
        if ask "Débranche le chargeur."; then
            if wait_for 15 sh -c "'$PULSE' fan interval | grep -q 'on battery now'"; then
                notes+=" ; bascule batterie ok (5 s, pulse status : every $(status 'd.get("samplingInterval")') s)"
            else
                notes+=" ; bascule batterie non vue : $("$PULSE" fan interval)"; result=fail
            fi
            ask "Rebranche le chargeur." || true
            if wait_for 15 sh -c "'$PULSE' fan interval | grep -q 'on the adapter now'"; then
                notes+=" ; retour secteur ok"
            else
                notes+=" ; retour secteur non vu"; result=fail
            fi
        else
            notes+=" ; bascule batterie sautée"
        fi
    fi
    record 4 "${TITLES[3]}" "$result" "$notes"
}

t_app_quit() {
    needs_fans 5 || return
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    osascript -e 'quit app "Pulse"' >/dev/null 2>&1
    wait_for 10 sh -c '! pgrep -x Pulse >/dev/null'
    sleep 10
    local p; p="$(profile)"
    local curve; curve="$(status 'len(d["curve"])')"
    open "$APP" --args -menuBarHeartbeat off
    local back=no; wait_for 10 app_running && back=yes
    if [[ "$p" == "$CURVE" && "$curve" -gt 0 && "$back" == yes ]]; then
        record 5 "${TITLES[4]}" pass "app fermée 10 s : profil $p conservé, courbe active ($curve ventilateur·s) ; app relancée"
    else
        record 5 "${TITLES[4]}" fail "profil $p, courbes $curve, app relancée : $back"
    fi
}

t_kill9() {
    needs_fans 6 || return
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    local before; before="$(daemon_pid)"
    info "sudo kill -9 $before (mot de passe demandé)…"
    sudo kill -9 "$before" || { record 6 "${TITLES[5]}" skip "sudo refusé"; return; }
    local start=$SECONDS
    if wait_for 30 sh -c "p=\$(pgrep -f com.stormacq.pulse.daemon | head -1); [ -n \"\$p\" ] && [ \"\$p\" != $before ]"; then
        sleep 3
        local p; p="$(profile)"
        [[ "$p" == "$CURVE" && "$(latched)" == False ]] \
            && record 6 "${TITLES[5]}" pass "relancé par launchd en $((SECONDS - start)) s ; profil $p conservé ; ventilateurs $(fan_modes)" \
            || record 6 "${TITLES[5]}" fail "relancé, mais profil $p, verrou $(latched)"
    else
        record 6 "${TITLES[5]}" fail "pas relancé en 30 s"
    fi
}

t_sleep_wake() {
    needs_fans 7 || return
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    local before; before="$(daemon_pid)"
    local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
    if ! ask "Mets le Mac en veille (menu Pomme › Suspendre activité), attends au moins 30 s, puis réveille-le."; then
        record 7 "${TITLES[6]}" skip ""; return
    fi
    sleep 5
    local after; after="$(daemon_pid)"
    local errors; errors="$(/usr/bin/log show --start "$since" --predicate 'subsystem == "com.stormacq.pulse" AND messageType == error' 2>/dev/null | grep -c 'com.stormacq.pulse')"
    local age; age="$(status 'round(__import__("time").time() - __import__("datetime").datetime.fromisoformat(d["timestamp"].replace("Z","+00:00")).timestamp())')"
    local p; p="$(profile)"
    if [[ "$p" == "$CURVE" && "$before" == "$after" && "${age:-99}" -lt 10 ]]; then
        record 7 "${TITLES[6]}" pass "même daemon, profil conservé, télémétrie fraîche (${age} s) ; $errors erreur·s dans les journaux"
    else
        record 7 "${TITLES[6]}" fail "daemon $before → $after, profil $p, télémétrie de ${age} s, $errors erreur·s"
    fi
}

t_load() {
    needs_fans 8 || return
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    info "Compiling the heat load (CPU + GPU)…"
    LOAD_DIR="$(mktemp -d)"
    swiftc -O "$ROOT/scripts/campaign/pulse-stress.swift" -o "$LOAD_DIR/pulse-stress" 2>/dev/null \
        || { record 8 "${TITLES[7]}" skip "swiftc indisponible"; return; }
    info "Load on every CPU core and the GPU for $LOAD_SECONDS s, then $COOL_SECONDS s to cool down."
    local start_rpm start_temp start_max
    start_rpm="$(fan_rpms)"; start_temp="$(cpu_max)"
    start_max="$(status 'max([round(f.get("actualRPM") or 0) for f in d["fans"]] or [0])')"
    "$LOAD_DIR/pulse-stress" >/dev/null 2>&1 & LOAD_PIDS=($!)
    local peak_temp=0 peak_gpu=0 peak_rpm=0 peak_power=0 fans_at="" tripped=no
    for step in $(seq 1 $((LOAD_SECONDS / 5))); do
        sleep 5
        local line t g r w
        line="$(status '"%s %s %s %s" % (round(max([x["maximumCelsius"] for x in d["groups"] if x["label"]=="CPU"] or [0]),1), round(max([x["maximumCelsius"] for x in d["groups"] if x["label"]=="GPU"] or [0]),1), max([round(f.get("actualRPM") or 0) for f in d["fans"]] or [0]), round(next((p["value"] for p in d["power"] if p["key"]=="PDTR"), 0),1))')"
        read -r t g r w <<< "$line"
        printf '  %3d s  CPU %s °C  GPU %s °C  fan %s RPM  %s W\n' $((step * 5)) "$t" "$g" "$r" "$w"
        python3 -c "import sys; sys.exit(0 if float('$t') > float('$peak_temp') else 1)" && peak_temp="$t"
        python3 -c "import sys; sys.exit(0 if float('$g') > float('$peak_gpu') else 1)" && peak_gpu="$g"
        python3 -c "import sys; sys.exit(0 if float('$w') > float('$peak_power') else 1)" && peak_power="$w"
        [[ "${r:-0}" -gt "$peak_rpm" ]] && peak_rpm="$r"
        # "Speed up": 300 RPM above where the fans were when the load began.
        [[ -z "$fans_at" && "${r:-0}" -gt $((${start_max:-0} + 300)) ]] && fans_at="$((step * 5)) s à $t °C"
        [[ "$(latched)" == True ]] && tripped=yes
    done
    kill "${LOAD_PIDS[@]}" 2>/dev/null; wait "${LOAD_PIDS[@]}" 2>/dev/null; LOAD_PIDS=()
    rm -rf "$LOAD_DIR"
    sleep "$COOL_SECONDS"
    local end_rpm end_temp; end_rpm="$(fan_rpms)"; end_temp="$(cpu_max)"
    local notes="puissance max $peak_power W ; CPU $start_temp → $peak_temp °C, GPU max $peak_gpu °C ; ventilateurs $start_rpm → pic $peak_rpm RPM, accélèrent à ${fans_at:-jamais} ; $COOL_SECONDS s après : $end_rpm RPM, CPU $end_temp °C ; garde-fou : $tripped"
    if [[ "$tripped" == yes ]]; then record 8 "${TITLES[7]}" fail "$notes"
    elif [[ "$peak_rpm" -gt 0 ]]; then record 8 "${TITLES[7]}" pass "$notes"
    else record 8 "${TITLES[7]}" info "$notes (la rampe de la courbe n'a pas été atteinte)"
    fi
}

t_conflict() {
    FAKE_DIR="$(mktemp -d)"
    # A copy of /bin/sleep is killed (platform binary outside /bin) and a
    # symlink keeps the name "sleep": compile a tiny stand-in instead.
    printf '#include <unistd.h>\nint main(void){sleep(600);return 0;}\n' | clang -x c - -o "$FAKE_DIR/Macs Fan Control" 2>/dev/null \
        || { record 9 "${TITLES[8]}" skip "clang indisponible"; rm -rf "$FAKE_DIR"; return; }
    "$FAKE_DIR/Macs Fan Control" & FAKE_PID=$!
    local seen=no
    wait_for 10 sh -c "'$PULSE' status --json | grep -q 'Macs Fan Control'" && seen=yes
    local popover=""
    if [[ $seen == yes ]] && yesno "Le popover de Pulse affiche-t-il l'avertissement « Macs Fan Control » ? (ouvre-le)"; then popover=" ; avertissement visible dans le popover"; fi
    kill "$FAKE_PID" 2>/dev/null; FAKE_PID=""; rm -rf "$FAKE_DIR"
    local gone=no
    wait_for 10 sh -c "! '$PULSE' status --json | grep -q 'Macs Fan Control'" && gone=yes
    [[ $seen == yes && $gone == yes ]] && record 9 "${TITLES[8]}" pass "faux processus détecté puis oublié$popover" \
                                       || record 9 "${TITLES[8]}" fail "détecté : $seen, oublié : $gone"
}

t_safety() {
    needs_fans 10 || return
    info "Le plafond passe 3 °C sous la température actuelle pour déclencher le garde-fou, puis la config est restaurée."
    sudo "$ROOT/scripts/test-safety-notification.sh" "$CURVE" "$PULSE" || { record 10 "${TITLES[9]}" skip "script interrompu"; return; }
    local engaged released
    yesno "As-tu vu la notification « Temperature limit reached » ?" && engaged=yes || engaged=no
    sleep 5
    yesno "Et la notification de retour à la normale ?" && released=yes || released=no
    [[ $engaged == yes && $released == yes ]] && record 10 "${TITLES[9]}" pass "déclenchement et retour notifiés ; profil après : $(profile)" \
                                              || record 10 "${TITLES[9]}" fail "déclenchement : $engaged, retour : $released"
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
}

t_install() {
    # Two paths: "Reinstall" (install over a running service, as the app's
    # button does) keeps the profile; uninstall hands the fans back to macOS
    # for good and saves "auto", so a later install starts on Auto.
    local keep="$CURVE"; $HAS_FANS || keep=auto
    $HAS_FANS && "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    sleep 3
    info "1/2 Réinstallation par-dessus le service (sudo pulse daemon install)…"
    local install_error
    install_error="$(sudo "$PULSE" daemon install 2>&1 >/dev/null)" || { record 11 "${TITLES[10]}" fail "réinstallation : ${install_error:-sudo refusé}"; return; }
    local over=no; wait_for 15 daemon_running && over=yes
    sleep 2
    local p_over; p_over="$(profile)"

    info "2/2 Désinstallation puis installation…"
    sudo "$PULSE" daemon uninstall >/dev/null || { record 11 "${TITLES[10]}" skip "sudo refusé"; return; }
    sleep 2
    local modes; modes="$(fan_modes)"
    local stopped=yes; [[ -n "$(daemon_pid)" ]] && stopped=no
    install_error="$(sudo "$PULSE" daemon install 2>&1 >/dev/null)"
    local back=no; wait_for 15 daemon_running && back=yes
    if [[ $back == no ]]; then
        # Never leave the Mac without its service: retry with the app's own CLI.
        sudo "$APP/Contents/Helpers/pulse" daemon install >/dev/null 2>&1 && wait_for 15 daemon_running && install_error+=" (réinstallé via l'app)"
    fi
    sleep 2
    local p_after; p_after="$(profile)"
    $HAS_FANS && "$PULSE" fan profile "$CURVE" >/dev/null 2>&1

    local notes="réinstallation : relancé $over, profil $p_over conservé ; désinstallation : arrêté $stopped, ventilateurs $modes ; installation : relancé $back, profil $p_after"
    if [[ $over == yes && $p_over == "$keep" && $stopped == yes && $modes != *manual* && $back == yes && $p_after == auto ]]; then
        record 11 "${TITLES[10]}" pass "$notes"
    else
        record 11 "${TITLES[10]}" fail "$notes ; erreur : ${install_error:-aucune}"
    fi
}

t_idle_off() {
    needs_fans 12 || return
    if $HAS_BATTERY; then record 12 "${TITLES[11]}" skip "Mac de bureau seulement"; return; fi
    if ! yesno "Lancer l'essai ventilateurs arrêtés pendant $IDLE_OFF_MINUTES min ? (config modifiée puis restaurée, sudo)"; then
        record 12 "${TITLES[11]}" skip ""; return
    fi
    local backup; backup="$(mktemp)"
    sudo cp /etc/pulse/config.toml "$backup"
    sudo sed -i '' -E 's/^allow_below_minimum = .*/allow_below_minimum = true/' /etc/pulse/config.toml
    sudo "$PULSE" daemon restart >/dev/null
    "$PULSE" fan curve set campaign-off --from silent --at-zero off --activate >/dev/null
    local stopped_minutes=0 peak=0 tripped=no
    for minute in $(seq 1 "$IDLE_OFF_MINUTES"); do
        sleep 60
        local t r; t="$(cpu_max)"; r="$(fan_rpms)"
        printf '  %2d min  CPU max %s °C  fan %s RPM\n' "$minute" "$t" "$r"
        [[ "$r" == 0 ]] && stopped_minutes=$((stopped_minutes + 1))
        python3 -c "import sys; sys.exit(0 if float('$t') > float('$peak') else 1)" && peak="$t"
        [[ "$(latched)" == True ]] && tripped=yes
    done
    "$PULSE" fan profile "$CURVE" >/dev/null 2>&1
    "$PULSE" fan curve delete campaign-off >/dev/null 2>&1
    sudo cp "$backup" /etc/pulse/config.toml && rm -f "$backup"
    sudo "$PULSE" daemon restart >/dev/null
    local notes="arrêtés $stopped_minutes/$IDLE_OFF_MINUTES min, pic CPU $peak °C, garde-fou : $tripped"
    [[ $tripped == no ]] && record 12 "${TITLES[11]}" pass "$notes" || record 12 "${TITLES[11]}" fail "$notes"
}

t_reboot() {
    # Put the user's own settings back first (the script exits here, before
    # its usual restore), then check after the reboot that they survived.
    restore >/dev/null
    printf 'PROFILE=%s\nINTERVAL=%s\nRESULTS=%s\n' "$(profile)" "$(status 'd.get("samplingInterval")')" "$RESULTS" > "$STATE"
    bold "Redémarre le Mac, ouvre ta session, attends 30 s, puis lance :"
    info "scripts/hardware-campaign.sh --after-reboot"
    record 13 "${TITLES[12]}" info "en attente de --after-reboot"
    trap - EXIT
    exit 0
}

after_reboot() {
    [[ -f "$STATE" ]] || { echo "No reboot test in progress." >&2; exit 1; }
    # shellcheck disable=SC1090
    source "$STATE"
    sed -i '' '/en attente de --after-reboot/d' "$RESULTS"
    local app=no daemon=no
    wait_for 60 app_running && app=yes
    wait_for 30 sh -c "[ -n \"\$(pgrep -f com.stormacq.pulse.daemon)\" ]" && daemon=yes
    sleep 3
    local p; p="$(profile)"
    local i; i="$(status 'd.get("samplingInterval")')"
    if [[ $app == yes && $daemon == yes && "$p" == "$PROFILE" && "$i" == "$INTERVAL" ]]; then
        record 13 "${TITLES[12]}" pass "app relancée à l'ouverture de session, daemon actif, profil $p et intervalle $i s conservés"
    else
        record 13 "${TITLES[12]}" fail "app : $app, daemon : $daemon, profil $p (attendu $PROFILE), intervalle $i (attendu $INTERVAL)"
    fi
    rm -f "$STATE"
    echo "Results: $RESULTS"
}

# MARK: Main

case "${1:-}" in
    --list)
        for i in "${!TESTS[@]}"; do printf '%2d  %s\n' $((i + 1)) "${TITLES[$i]}"; done; exit 0;;
    --after-reboot)
        after_reboot; exit 0;;
    -h|--help)
        sed -n '2,13p' "$0"; exit 0;;
esac

python3 -c 'import json' 2>/dev/null || { echo "python3 is required (xcode-select --install)." >&2; exit 1; }
[[ -x "$PULSE" ]] || { echo "pulse CLI not found (looked on the PATH and in $APP)." >&2; exit 1; }
[[ -n "$(daemon_pid)" ]] || { echo "The Pulse service is not running: install it first (Settings › Service)." >&2; exit 1; }
app_running || { echo "Open Pulse.app first." >&2; exit 1; }

[[ "$(status 'len(d["fans"])')" == 0 ]] && HAS_FANS=false
command -v swiftc >/dev/null || info "swiftc not found: test 8 (heat load) will be skipped."
command -v clang >/dev/null || info "clang not found: test 9 (competing tool) will be skipped."

SELECTED=("$@")
[[ ${#SELECTED[@]} -gt 0 ]] || SELECTED=($(seq 1 ${#TESTS[@]}))

bold "Pulse hardware campaign on $MODEL ($CHIP, macOS $MACOS, battery: $HAS_BATTERY, fans: $HAS_FANS)"
info "Curve under test: $CURVE · results: $RESULTS"
init_results
save_state
trap restore EXIT
trap 'exit 130' INT

for n in "${SELECTED[@]}"; do
    index=$((n - 1))
    [[ $index -ge 0 && $index -lt ${#TESTS[@]} ]] || { echo "No test $n (see --list)." >&2; continue; }
    echo
    bold "$n. ${TITLES[$index]}"
    "t_${TESTS[$index]}"
done
