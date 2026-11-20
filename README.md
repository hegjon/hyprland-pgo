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
scripts/pgo.sh build profiles/hyprland-0.57.2-2-pgo-7hosts.tar.zst   # from a committed profile, no training
```

The training runs on the machines by itself (`scripts/train-host.sh`, started detached). If the desktop goes away while it runs, `scripts/pgo.sh collect results/pgo-<date>` waits for the machines, then fetches, merges and packs as `train` would have done.

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

`start.sh` copies `scripts/bench` of the Hypoland tree and `bench/pr` to `/root/abnight` on every machine and runs the stock blocks with the PGO package. By default it runs only those (`ABNIGHT_ORDER=hyprland`). With `ABNIGHT_ORDER="hypoland hyprland"` it alternates with Hypoland, as the night runs do. Pass the same Hypoland package as the night you compare against, so its blocks become the control column in `compare.py`. Hypoland comes back when the run ends.

`compare.py` leaves out the workloads that `measure.sh` marked invalid in a block, for example a client of an earlier workload that was still running. To stop one machine of a run, `touch /root/abnight/<run>/stop` there, then restart it as `<run>b` with `HOSTS=<host>`. `status.sh` reads `<run>b`.

## Runs

| Run (`results/`) | What |
|---|---|
| `pgo-hyprland-20261119` | Training on t490: one bench round (717 values) and the session checks, 526 counter files. `profiles/hyprland-0.57.2-2-pgo-t490.tar.zst`, release `v0.57.2-2-pgo-t490`. `Hyprland` 13.4 MB against 17.2 MB for Omarchy's 0.57.2-2. |
| `pgo-hyprland-bench-20261119` | That package on t550, xps, chromebook, t460s, t490, samsung-i5 and p14s, 11-19 13:06 until 14:45: 2 blocks each, stock blocks only, against night-20261118's stock. |
| `pgo-hyprland-20261119-7hosts` | Training on the same 7 machines in parallel, 14:56 until 15:37 (the desktop lost power at 15:22, `collect` finished it). `profiles/hyprland-0.57.2-2-pgo-7hosts.tar.zst`, release `v0.57.2-2-pgo-7hosts`. `Hyprland` 13.8 MB. |
| `night-hyprland-pgo-20261119` | The 7-machine package alternating with Hypoland r1030 (night-20261118's package), 11-19 15:42 until 11-20 09:00: 14 to 20 blocks each, p14s 29 with the PGO Hyprland only. `summary.txt` and `compare.txt` are in the run's folder. |

Results against stock 0.57.2-2 (median ratio over the metrics of a group, range over the 7 machines; below 1 is less):

| | t490 profile (2 blocks) | 7-machine profile (night) | control: Hypoland, night / night |
|---|---|---|---|
| compositor CPU % | 0.940 – 0.970 | 0.943 – 0.966 | 0.983 – 1.005 |
| compositor CPU ms per frame | 0.944 – 0.972 | 0.945 – 0.966 | 0.983 – 1.006 |
| Pss at the start | 0.975 – 0.980 | 0.979 – 0.982 | 0.983 – 1.008 |
| fps | 1.000 | 1.000 | 1.000 |
| latencies | 0.952 – 1.009 | 0.969 – 1.006 | 0.970 – 1.014 |
| startup times | 0.985 – 1.045 | 0.989 – 1.007 | 0.999 – 1.016 |

PGO uses 3 to 6 % less compositor CPU and about 2 % less memory at the start, with the same fps. Training on 7 machines is not measurably faster on these machines than training on the t490 alone. The session checks fail as with stock: the damage-tracking checks have two modes on t460s, t490, t550, xps and p14s (8 or about 38 FAILs on the T490) under stock too.

Lab problems seen in these runs, not the build:
- p14s: Hypoland r1030 aborts in the video workload and comes back in safe mode, so run p14s with `ABNIGHT_ORDER=hyprland`.
- xps: from the night's round 2 on, Xonotic did not start its demo, and its leftover client invalidated the ElectroBench workloads after it, under both compositors.
