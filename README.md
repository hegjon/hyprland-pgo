# hyprland-pgo

Profile guided optimization (GCC PGO) for Omarchy's Hyprland package, trained and measured on the lab machines with Hypoland's benchmark.

| Path | What |
|------|------|
| `pkgbuild/` | Omarchy's `hyprland` recipe (omacom/omarchy-pkgs `pkgbuilds/hyprland`, 0.57.2-2) with PGO support. The first commit is the unchanged recipe and the second the PGO change, so the PGO diff against upstream stays one commit. See `pkgbuild/README.md`, "PGO". |
| `scripts/pgo.sh` | `train DIR HOST...`: build the instrumented package, train on the machines, merge the counters into `DIR/profile`. `build DIR`: build with that profile into `DIR/pgo`. |
| `scripts/train-host.sh` | The training on one machine (as root, started by `pgo.sh`): instrumented Hyprland in place of Hypoland, one round of every workload and the session checks, then Hypoland back. |
| `bench/` | Hypoland's night A/B kit (`abnight.sh`, `start.sh`, `status.sh`, `report.sh`, `pr/`), set up to run the PGO package in the stock blocks, and `compare.py` against a night's stock Hyprland. |
| `profiles/` | Trained profiles in git: `hyprland-<pkgver>-<pkgrel>-pgo-<hosts>.tar.zst` with the merged counters (`profile/*.gcda`), the recipe's checksums (`recipe`) and `meta` (hosts, date, build directory, GCC). About 0.6 MB each, 12 MB unpacked. |
| `results/` | Trainings, unpacked profiles, packages and fetched benchmark runs. Not in git (packages are large). |

Needs a Hypoland checkout for `scripts/bench` (`HYPOLAND_TREE`, default `~/Work/hypoland`), whose night runs in `test-results/` are the stock baseline.

## Train and build

Claim the machines first (`lab claim`). The training takes about 40 minutes per machine (x86_64 only).

```sh
scripts/pgo.sh train results/pgo-<date> t490 [more hosts]    # ends with the profile packed into profiles/
scripts/pgo.sh build results/pgo-<date>
scripts/pgo.sh build profiles/hyprland-0.57.2-2-pgo-t490.tar.zst   # from the committed profile, no training
```

Commit a new `profiles/*.tar.zst` after a training; `scripts/pgo.sh pack DIR` packs one again. The tarball is reproducible (sorted, fixed time and owner), so packing the same profile twice gives the same file and git sees no change. `build` warns when the recipe changed since the training (functions that changed lose their profile) and when the profile was trained from another build directory (then GCC matches none of it).

The desktop has no `glaze` installed, so the builds there use `MAKEPKG_ARGS=-d CMAKE_PREFIX_PATH=~/.cache/hyprland-pgo/deps/root/usr` (glaze's package unpacked there).

Both builds run in one `BUILDDIR` (`~/.cache/hyprland-pgo/build`). GCC matches a function to its counters by a checksum that includes the absolute path of its source, and `-fprofile-prefix-map` does not change that with GCC 16. A profile only fits a build in the same place. Omarchy's builders compile in `/src/hyprland`, so a profile for them has to be trained from a build at that path.

Hyprland's `make release` reads the compiler flags from the environment only when CMake configures a new build directory. The PKGBUILD removes `build` for PGO builds and `pgo.sh` runs `makepkg -C`. Check `build/CMakeCache.txt` for `-fprofile-use` when in doubt.

## Benchmark against stock

```sh
HYPR_PGO=results/pgo-<date>/pgo/hyprland-0.57.2-2-x86_64.pkg.tar.zst \
  bench/start.sh <run> <HH:MM until> ~/Work/hypoland/test-results/night-<date>/hypoland-<ver>-x86_64.pkg.tar.zst
bench/status.sh <run> "<start time>"
cd results && ../bench/report.sh <run> && python3 ../bench/compare.py <run> night-<date> night-<previous date>
```

`start.sh` copies `scripts/bench` of the Hypoland tree and `bench/pr` to `/root/abnight` on every machine, and runs only the stock blocks with the PGO package (`ABNIGHT_ORDER=hyprland`). Hypoland comes back when the run ends.

## Runs

- `results/pgo-hyprland-20261119`: trained on t490 (one bench round, 717 values, and the session checks), 526 counter files. Hyprland binary 13.4 MB against 17.2 MB for Omarchy's 0.57.2-2.
- `results/pgo-hyprland-bench-20261119`: that package on t550, xps, chromebook, t460s, t490, samsung-i5 and p14s, 13:06 until 14:45, against night-20261118's stock blocks.
