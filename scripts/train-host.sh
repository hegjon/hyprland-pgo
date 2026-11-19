#!/bin/bash
# train-host.sh OUT RESTORE_PKG "HYPRLAND_PKG TITLEBARS_PKG" [pr]
# One PGO training of Omarchy's Hyprland on this machine, as root, detached (scripts/pgo.sh starts it):
#   setsid -f nohup bash train-host.sh OUT RESTORE_PKG "PKGS" [pr] >/dev/null 2>&1 </dev/null
# Installs the instrumented Hyprland (built with PGO_GENERATE=/var/tmp/hyprland-pgo) and Omarchy's titlebar plugin in
# place of Hypoland, runs one round of every workload of measure.sh (bench/ next to this script) and the session
# checks in a fresh SDDM session, then ends the session, which writes the counters into /var/tmp/hyprland-pgo, and puts
# RESTORE_PKG back. The stock files are the night runs' (pr/ next to this script): pr/stock-quirks.lua always, with pr
# the GLES 3 override of the X200. Writes OUT/log, OUT/measure.txt and OUT/check.txt, and OUT/done at the end.
set -u
OUT=$1 RESTORE=$2 PKGS=$3 PR=${4:-}
D=$(dirname "$(readlink -f "$0")")
O=/usr/share/omarchy
PROF=/var/tmp/hyprland-pgo
mkdir -p "$OUT"
exec >>"$OUT/log" 2>&1
log() { echo "$(date '+%F %T') $*"; }
compositor() { pgrep -x 'hypoland|Hyprland'; }
cp $O/default/hypr/envs.lua "$OUT/envs.lua.orig"

ready() { # the instance lock file names the compositor and the shell is up
    local p
    for _ in $(seq 1 240); do
        p=$(compositor)
        [ -n "$p" ] && grep -qx "$p" /run/user/*/hypr/*/hyprland.lock 2>/dev/null && pgrep -x quickshell >/dev/null && return 0
        sleep 0.5
    done
    return 1
}

stock_files() { # on|off, as abnight.sh
    if [ "$1" = on ]; then
        install -m 644 "$D/pr/stock-quirks.lua" $O/default/hypr/
        grep -q stock-quirks $O/default/hypr/envs.lua ||
            sed -i 's/^require("default.hypr.nvidia")$/&\nrequire("default.hypr.stock-quirks")/' $O/default/hypr/envs.lua
        grep -q stock-quirks $O/default/hypr/envs.lua || { log "envs.lua not patched for the quirks"; return 1; }
        [ -n "$PR" ] || return 0
        install -m 755 "$D/pr/omarchy-hw-intel-gles2" $O/bin/
        install -m 644 "$D/pr/intel-gles2.lua" $O/default/hypr/
        grep -q intel-gles2 $O/default/hypr/envs.lua ||
            sed -i 's/^require("default.hypr.nvidia")$/&\nrequire("default.hypr.intel-gles2")/' $O/default/hypr/envs.lua
        grep -q intel-gles2 $O/default/hypr/envs.lua || { log "envs.lua not patched"; return 1; }
    else
        rm -f $O/default/hypr/intel-gles2.lua $O/bin/omarchy-hw-intel-gles2 $O/default/hypr/stock-quirks.lua
        cp "$OUT/envs.lua.orig" $O/default/hypr/envs.lua
    fi
}

session() { # a new SDDM session; the compositor of the old one exits and writes its counters
    systemctl stop sddm
    for _ in $(seq 1 100); do compositor >/dev/null || break; sleep 0.2; done
    systemctl --user -M "$USERNAME@" stop graphical-session.target graphical-session-pre.target 2>/dev/null
    sleep 2
    rm -rf /run/user/*/quickshell/by-id/* /run/user/*/quickshell/by-pid/*
    [ "${1:-}" = stop ] && return 0
    systemctl start sddm
    ready
}

restore() {
    trap - EXIT
    log "back to $RESTORE"
    pgrep -x Hyprland >/dev/null && session stop
    pacman -U --noconfirm --ask=4 "$RESTORE" >>"$OUT/pacman.log" 2>&1 || log "installing $RESTORE failed"
    stock_files off
    systemctl start sddm
    ready && log "up: $(pacman -Q hypoland 2>/dev/null || pacman -Q hyprland)" || log "no session after the restore"
    log "done: $(find $PROF -name '*.gcda' | wc -l) counter files"
    touch "$OUT/done"
}
trap restore EXIT
trap 'exit 1' HUP INT TERM

USERNAME=$(ps -o user= -p "$(compositor | head -1)")
log "on $(uname -n), user $USERNAME, training $PKGS${PR:+ (with the GLES 3 override)}, restoring $RESTORE"
[ -f "$RESTORE" ] || { log "no $RESTORE"; exit 1; }
# the session runs as the user: every user may write the counters, the default ACL keeps them writable for the next
rm -rf $PROF && mkdir -m 1777 $PROF && setfacl -d -m u::rw,g::rw,o::rw $PROF || exit 1

pacman -U --noconfirm --ask=4 $PKGS >>"$OUT/pacman.log" 2>&1 || { log "installing $PKGS failed"; exit 1; }
stock_files on || exit 1
session || { log "no session with the instrumented Hyprland"; exit 1; }
pgrep -x Hyprland >/dev/null || { log "Hyprland is not what runs"; exit 1; }
log "up: $(pacman -Q hyprland)"
# the shell's start and Omarchy's autostart have run
sleep 60

env=()
[ -n "$PR" ] && env=(--env MESA_GLES_VERSION_OVERRIDE=3.0 --env MESA_GLSL_VERSION_OVERRIDE=300)
rm -rf /tmp/hyprland-pgo-measure
timeout -k 30 3600 bash "$D/bench/measure.sh" --rounds 1 --out /tmp/hyprland-pgo-measure \
    ${TRAIN_WORKLOADS:+--workloads "$TRAIN_WORKLOADS"} "${env[@]}" >"$OUT/measure.txt" 2>&1
rc=$?
log "measure: $(grep -c '^@' "$OUT/measure.txt") values, rc $rc"
# a hung compositor writes no counters: the training of this machine is lost
if [ $rc = 124 ] || [ $rc = 137 ]; then log "the round took an hour, killing Hyprland"; pkill -9 -x Hyprland; exit 1; fi
# the session checks reach code the workloads do not (config reloads, monitors, special workspaces...)
if [ -z "${TRAIN_NO_CHECK:-}" ]; then
    timeout -k 30 1800 bash "$D/bench/measure.sh" --mode check "${env[@]}" >"$OUT/check.txt" 2>&1
    log "check: $(grep -c '^PASS' "$OUT/check.txt") passed, $(grep -c '^FAIL' "$OUT/check.txt") failed"
fi
session stop
log "Hyprland ended: $(find $PROF -name '*.gcda' | wc -l) counter files"
