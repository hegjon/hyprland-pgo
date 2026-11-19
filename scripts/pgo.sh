#!/bin/bash
# Profile guided build of Omarchy's Hyprland (pkgbuild/, whose PKGBUILD takes PGO_GENERATE and PGO_PROFILE), trained
# with Hypoland's benchmark (scripts/bench/measure.sh of the Hypoland tree) on lab machines (x86_64). DIR is relative
# to this repository, e.g. results/pgo-<date>:
#
#   scripts/pgo.sh train DIR HOST...  build the instrumented package; on every HOST install it with Omarchy's titlebar
#                                     plugin in place of Hypoland, run one round of every workload and the session
#                                     checks (scripts/train-host.sh), put Hypoland back; then merge the machines'
#                                     counters into DIR/profile
#                                     and pack it into profiles/ (as pack)
#   scripts/pgo.sh collect DIR [HOST...] wait for a training that runs on the machines (after the desktop went away),
#                                     then fetch, merge and pack as train does (default: the hosts train was given)
#   scripts/pgo.sh build DIR          build the package with DIR/profile into DIR/pgo
#   scripts/pgo.sh build FILE.tar.zst build with a packed profile (profiles/): unpacked into results/<its name>/
#   scripts/pgo.sh pack DIR           DIR/profile with its recipe sums and metadata as
#                                     profiles/hyprland-<pkgver>-<pkgrel>-pgo-<hosts>.tar.zst, for git
#
# HYPOLAND_TREE       the Hypoland checkout whose scripts/bench runs on the machines (default ~/Work/hypoland)
# HYPRLAND_PKGBUILD   the recipe (default pkgbuild/ of this repository)
# MAKEPKG_ARGS        more makepkg arguments, e.g. -s or -d
# TITLEBARS           the plugin version in the machines' pacman cache (default 0.4.0-1)
# STOCK_FILES         the stock blocks' files for Omarchy's config (default bench/pr)
# TRAIN_WORKLOADS     fewer workloads, for a quick try; TRAIN_NO_CHECK=1 leaves out the session checks
#
# Both builds use one BUILDDIR (~/.cache/hyprland-pgo/build, HYPRLAND_PGO_BUILDDIR): GCC matches a function to its
# counters by a checksum with the absolute path of its source in it, so a profile only fits a build in the same place.
# Claim the machines first (lab claim), a training takes about 30 to 45 minutes.
set -u
cd "$(dirname "$(readlink -f "$0")")/.." || exit 1
ROOT=$PWD
CMD=${1:-}; DIR=${2:-}
[ -n "$DIR" ] || { sed -n '2,28p' "$0"; exit 1; }
TARBALL=""
if [ "$CMD" = build ] && [[ $DIR == *.tar.zst ]]; then
    TARBALL=$(readlink -f "$DIR") && [ -f "$TARBALL" ] || { echo "no profile $DIR"; exit 1; }
    DIR=results/$(basename "$TARBALL" .tar.zst)
fi
mkdir -p "$DIR" && DIR=$(readlink -f "$DIR") || exit 1
RECIPE=${HYPRLAND_PKGBUILD:-$ROOT/pkgbuild}
HYPOLAND=${HYPOLAND_TREE:-$HOME/Work/hypoland}
CACHE=${HYPRLAND_PGO_BUILDDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/hyprland-pgo/build}
TITLEBARS=${TITLEBARS:-0.4.0-1}
[ -f "$RECIPE/PKGBUILD" ] && grep -q PGO_GENERATE "$RECIPE/PKGBUILD" || { echo "$RECIPE has no PKGBUILD with PGO"; exit 1; }

# the recipe's files, to tell whether a profile was trained on what is built now
recipe_sum() { (cd "$RECIPE" && sha256sum PKGBUILD *.patch); }

# pack: DIR/profile, DIR/recipe and DIR/meta in a reproducible tarball under profiles/
pack() {
    local hosts name out
    compgen -G "$DIR/profile/*.gcda" >/dev/null || { echo "$DIR has no profile"; exit 1; }
    [ -s "$DIR/meta" ] || { echo "$DIR has no meta (train writes it)"; exit 1; }
    hosts=$(sed -n 's/^hosts: //p' "$DIR/meta" | tr ' ' '+')
    [ "$(echo "$hosts" | tr '+' '\n' | wc -l)" -gt 3 ] && hosts="$(echo "$hosts" | tr '+' '\n' | wc -l)hosts"
    name=hyprland-$(sed -n 's/^pkgver: //p' "$DIR/meta")-pgo-$hosts.tar.zst
    mkdir -p profiles
    out=profiles/$name
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -C "$DIR" -c profile recipe meta | zstd -19 -T0 -q -f -o "$out" || exit 1
    echo "packed $out ($(du -h --apparent-size "$out" | cut -f1), $(ls "$DIR/profile" | wc -l) counter files)"
}

# meta HOST...: what a packed profile needs to say about its training
meta() {
    printf 'pkgver: %s\nhosts: %s\ntrained: %s\nbuilddir: %s\ngcc: %s\n' "$(cd "$RECIPE" && bash -c 'source PKGBUILD; echo "$pkgver-$pkgrel"')" \
        "$*" "$(date +%F)" "$CACHE" "$(gcc --version | head -n 1)"
}

# makepkg_in LOG PKGDEST [VAR=value...]: a build in the profile builds' directory, its packages listed in DIR/packages
makepkg_in() {
    local log=$1 dest=$2; shift 2
    mkdir -p "$dest"
    (cd "$RECIPE" && env BUILDDIR="$CACHE" PKGDEST="$dest" "$@" nice -n 19 makepkg -Cf --noconfirm ${MAKEPKG_ARGS:-}) >"$log" 2>&1 ||
        { tail -n 20 "$log"; echo "build failed, see $log"; exit 1; }
    (cd "$RECIPE" && env BUILDDIR="$CACHE" PKGDEST="$dest" "$@" makepkg --packagelist) >"$DIR/packages" 2>/dev/null
}

start_host() {
    local h=$1 pkg=$2 c=/var/cache/pacman/pkg before restore pr=""
    [ "$(ssh -o BatchMode=yes "root@$h" uname -m)" = x86_64 ] || { echo "$h: not reachable or not x86_64"; return 1; }
    before=$(ssh "root@$h" 'pacman -Q hypoland' | tr ' ' '-') || { echo "$h: no hypoland installed"; return 1; }
    restore=$(ssh "root@$h" "ls $c/$before-x86_64.pkg.tar.zst /root/abnight/$before-x86_64.pkg.tar.zst 2>/dev/null | head -n 1")
    [ -n "$restore" ] || { echo "$h: no package of $before to put back, not trained"; return 1; }
    ssh "root@$h" "ls $c/omarchy-hyprland-titlebars-$TITLEBARS-x86_64.pkg.tar.zst" >/dev/null ||
        { echo "$h: no titlebar plugin $TITLEBARS in its cache (pacman -Sw omarchy-hyprland-titlebars)"; return 1; }
    [ "$h" = x200 ] && pr=pr
    tar -C "$HYPOLAND/scripts" -cz bench | ssh "root@$h" 'rm -rf /root/hyprland-pgo && mkdir -p /root/hyprland-pgo && tar -xz -C /root/hyprland-pgo' &&
        scp -q -r "$STOCK" "root@$h:/root/hyprland-pgo/pr" && scp -q scripts/train-host.sh "$pkg" "root@$h:/root/hyprland-pgo/" ||
        { echo "$h: copy failed"; return 1; }
    ssh "root@$h" "TRAIN_WORKLOADS='${TRAIN_WORKLOADS:-}' TRAIN_NO_CHECK='${TRAIN_NO_CHECK:-}' setsid -f nohup bash /root/hyprland-pgo/train-host.sh \
        /root/hyprland-pgo/out $restore '/root/hyprland-pgo/${pkg##*/} $c/omarchy-hyprland-titlebars-$TITLEBARS-x86_64.pkg.tar.zst' $pr >/dev/null 2>&1 </dev/null"
}

# collect_host HOST: waits for the training on HOST to end (it runs on the machine on its own, so this can be run again
# after the desktop went away), then fetches its logs and counters
collect_host() {
    local h=$1
    ssh "root@$h" 'test -d /root/hyprland-pgo/out' || { echo "$h: no training there"; return 1; }
    # an hour for the round, half an hour for the checks
    for _ in $(seq 1 120); do
        ssh "root@$h" 'test -e /root/hyprland-pgo/out/done' 2>/dev/null && break
        sleep 60
    done
    for f in log measure.txt check.txt pacman.log; do scp -q "root@$h:/root/hyprland-pgo/out/$f" "$DIR/train-$h-$f" 2>/dev/null; done
    rm -rf "$DIR/prof-$h"; scp -q -r "root@$h:/var/tmp/hyprland-pgo" "$DIR/prof-$h"
    echo "$h: $(ls "$DIR/prof-$h" 2>/dev/null | wc -l) counter files, $(tail -n 3 "$DIR/train-$h-log" 2>/dev/null | tr '\n' ' ')"
}

# merge_pack HOST...: the hosts' counters merged into DIR/profile, its meta, packed into profiles/
merge_pack() {
    local dirs=() h d
    for h in "$@"; do [ -n "$(ls "$DIR/prof-$h" 2>/dev/null)" ] && dirs+=("$DIR/prof-$h"); done
    [ ${#dirs[@]} -gt 0 ] || { echo "no machine gave a profile"; exit 1; }
    rm -rf "$DIR/profile"; cp -r "${dirs[0]}" "$DIR/profile"
    for d in "${dirs[@]:1}"; do gcov-tool merge -o "$DIR/merged" "$DIR/profile" "$d" && rm -rf "$DIR/profile" && mv "$DIR/merged" "$DIR/profile"; done
    echo "profile of ${#dirs[@]} machines in $DIR/profile: $(ls "$DIR/profile" | wc -l) counter files"
    meta "${dirs[@]##*/prof-}" >"$DIR/meta"
    pack
}

case $CMD in
train)
    shift 2; [ $# -gt 0 ] || { echo "train needs machines"; exit 1; }
    STOCK=${STOCK_FILES:-$ROOT/bench/pr}
    [ -f "$HYPOLAND/scripts/bench/measure.sh" ] || { echo "no Hypoland tree with scripts/bench in $HYPOLAND (HYPOLAND_TREE)"; exit 1; }
    [ -f "$STOCK/stock-quirks.lua" ] || { echo "no stock files (STOCK_FILES)"; exit 1; }
    echo "building the instrumented package..."
    makepkg_in "$DIR/build-generate.log" "$DIR/generate" PGO_GENERATE=/var/tmp/hyprland-pgo
    pkg=$(grep -m1 '/hyprland-[0-9]' "$DIR/packages")
    recipe_sum >"$DIR/recipe"
    echo "$*" >"$DIR/hosts"
    for h in "$@"; do start_host "$h" "$pkg"; done
    for h in "$@"; do collect_host "$h" & done; wait
    merge_pack "$@"
    ;;
collect)
    shift 2; set -- ${*:-$(cat "$DIR/hosts" 2>/dev/null)}; [ $# -gt 0 ] || { echo "collect needs machines"; exit 1; }
    for h in "$@"; do collect_host "$h" & done; wait
    merge_pack "$@"
    ;;
pack)
    pack
    ;;
build)
    if [ -n "$TARBALL" ]; then
        rm -rf "$DIR/profile" && tar -C "$DIR" -xf "$TARBALL" || exit 1
        echo "profile $(basename "$TARBALL") in $DIR: $(sed -n 's/^hosts: //p' "$DIR/meta"), trained $(sed -n 's/^trained: //p' "$DIR/meta")"
    fi
    [ ! -s "$DIR/meta" ] || [ "$(sed -n 's/^builddir: //p' "$DIR/meta")" = "$CACHE" ] ||
        echo "warning: the profile was trained from a build in $(sed -n 's/^builddir: //p' "$DIR/meta"), this one is in $CACHE: GCC will not match it (HYPRLAND_PGO_BUILDDIR)"
    compgen -G "$DIR/profile/*.gcda" >/dev/null || { echo "$DIR has no profile, train first"; exit 1; }
    [ "$(recipe_sum)" = "$(cat "$DIR/recipe" 2>/dev/null)" ] ||
        echo "note: the recipe changed since the training, functions that changed are built without a profile"
    echo "building with the profile..."
    makepkg_in "$DIR/build-use.log" "$DIR/pgo" PGO_PROFILE="$DIR/profile"
    grep -c 'profile data may be out of date\|coverage mismatch' "$DIR/build-use.log" | sed 's/^/stale-profile warnings: /'
    grep -v -- -debug- "$DIR/packages"
    ;;
*) sed -n '2,28p' "$0"; exit 1 ;;
esac
