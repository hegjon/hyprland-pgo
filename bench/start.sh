#!/bin/bash
# HYPR_PGO=PKG start.sh NAME UNTIL PKG_X86 [workloads] : Omarchy's Hyprland as a PGO build (HYPR_PGO) in the stock blocks of
# Hypoland's night A/B kit, by default only those (ABNIGHT_ORDER=hyprland; ABNIGHT_ORDER="hypoland hyprland" alternates): copies abnight.sh, pr/ and scripts/bench of this tree to /root/abnight on
# the machines in HOSTS, installs the Hypoland package under test and starts abnight.sh detached, writing
# /root/abnight/NAME. PKG_X86 is the x86_64 package file on the desktop; the Galaxy Book takes GALAXY_PKG (a path on the
# machine, built there), macmini-m1 M1_PKG the same way. Stock Hyprland 0.57.2-2 and omarchy-hyprland-titlebars 0.4.0-1 (the omarchy repository) must be
# in each machine's pacman cache (pacman -Sw hyprland omarchy-hyprland-titlebars).
NAME=$1 UNTIL=$2 PKG=$3 WL=${4:-}
# both packages relative to where this is started, before the cd into the Hypoland tree
HYPR_PGO=$(readlink -e "${HYPR_PGO:?the PGO package: HYPR_PGO=results/<run>/pgo/hyprland-...pkg.tar.zst}") || { echo "no package $HYPR_PGO"; exit 1; }
PKG=$(readlink -e "$PKG") || { echo "no package $3"; exit 1; }
C=/var/cache/pacman/pkg
D=$(dirname "$(readlink -f "$0")")
cd "${HYPOLAND_TREE:-$HOME/Work/hypoland}" && [ -d scripts/bench ] || { echo "no Hypoland tree (HYPOLAND_TREE)"; exit 1; }
echo "scripts/bench from $(pwd) at $(git log --oneline -1 | cut -c1-60)"
set -o pipefail
for h in ${HOSTS:-t550 xps chromebook t460s t490 samsung-i5 p14s}; do
    case $h in x200|galaxybook|macmini-m1) echo "$h: not in this run (GLES 2 or aarch64)"; continue ;; esac
    case $h in
        x200) HYP=/root/abnight/${PKG##*/}; HYPR="$C/hyprland-0.57.2-2-x86_64.pkg.tar.zst $C/omarchy-hyprland-titlebars-0.4.0-1-x86_64.pkg.tar.zst"; PR=pr ;;
        galaxybook) HYP=${GALAXY_PKG:?}; HYPR="$C/hyprland-0.57.2-2-aarch64.pkg.tar.zst $C/omarchy-hyprland-titlebars-0.4.0-1-aarch64.pkg.tar.zst"; PR="" ;;
        macmini-m1) HYP=${M1_PKG:?}; HYPR="$C/hyprland-0.57.2-2-aarch64.pkg.tar.zst $C/omarchy-hyprland-titlebars-0.4.0-1-aarch64.pkg.tar.zst"; PR="" ;;
        *) HYP=/root/abnight/${PKG##*/}; HYPR="/root/abnight/pgo/${HYPR_PGO##*/} $C/omarchy-hyprland-titlebars-0.4.0-1-x86_64.pkg.tar.zst"; PR="" ;;
    esac
    printf '%-14s ' $h
    tar -C scripts -cz bench | ssh -o BatchMode=yes root@$h "rm -rf /root/abnight/bench /root/abnight/pr && mkdir -p /root/abnight && tar -xz -C /root/abnight" || { echo "copy failed"; continue; }
    scp -q "$D/abnight.sh" root@$h:/root/abnight/ && scp -q -r "$D/pr" root@$h:/root/abnight/ || { echo "copy failed"; continue; }
    if [ $h != galaxybook ] && [ $h != macmini-m1 ]; then
        scp -q "$PKG" root@$h:/root/abnight/ || { echo "package copy failed"; continue; }
        ssh -o BatchMode=yes root@$h "rm -rf /root/abnight/pgo && mkdir -p /root/abnight/pgo" && scp -q "$HYPR_PGO" root@$h:/root/abnight/pgo/ || { echo "PGO package copy failed"; continue; }
    fi
    ssh -o BatchMode=yes root@$h "pacman -U --noconfirm --ask=4 $HYP >/dev/null 2>&1 && pacman -Q hypoland | tr '\n' ' '" || { echo "install failed"; continue; }
    ssh -o BatchMode=yes root@$h "ls $HYP $HYPR >/dev/null || exit 1; ABNIGHT_CHECK=${ABNIGHT_CHECK-1} ABNIGHT_NO_STARTUP=${ABNIGHT_NO_STARTUP-} ABNIGHT_WORKLOADS='$WL' ABNIGHT_ORDER='${ABNIGHT_ORDER-hyprland}' setsid -f nohup bash /root/abnight/abnight.sh /root/abnight/$NAME '$UNTIL' $HYP '$HYPR' $PR >/dev/null 2>&1 </dev/null; sleep 2; tail -1 /root/abnight/$NAME/log"
done
