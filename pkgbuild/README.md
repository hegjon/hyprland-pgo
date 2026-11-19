# Hyprland

Automatic upstream version bumps are held (`sync: false`) because `omarchy-hyprland-titlebars` requires the exact Hyprland it was built against, and a new Hyprland release can break the plugin's build. 0.57.0 did, so the plugin's rebuild failed and every `pacman -Syu` that offered Arch's 0.57.0 stopped on its `hyprland=0.56.2` dependency. Bump Hyprland by hand, in the same change as a plugin release that builds against it. Hyprland is on the normal ring, so a merge publishes it to edge only, and rc and stable get it by promotion together with the plugin. Aquamarine changes in the official/ALARM repositories are checked by the separate six-hour `sync-rebuilds` job through `rebuild_on`, which proposes a package release bump for rebuilding.

## Output, VRR, and NVIDIA fixes

`wl-output-global-grace.patch` keeps a removed `wl_output` global for five seconds before destroying it, as wlroots does. Without it, an output that comes and goes within a roundtrip, such as a dock's monitor flapping while its tunnel comes up, disconnects every client that has not bound it yet with "global wl_output (N) is unavailable". `monitor-rule-vrr.patch` makes a config reload apply a monitor rule's `vrr`; without it, changing only `vrr` is ignored until the next session. `nvidia-egl-teardown.patch` releases the EGL context before Hyprland terminates the display, which NVIDIA's EGL otherwise crashes on at exit. Two earlier carries, the removed-output session-lock fix and the dmabuf format-table fix, shipped upstream in 0.57.1 and were dropped here. Rebase each patch with `--fuzz=0` on a version bump, and drop each once the selected release carries the fix.

## x86_64

This recipe also builds for x86_64, so PCs take this build instead of Arch's `extra/hyprland`: `[omarchy]` comes before `[extra]` in Omarchy's `pacman.conf`. That gives PCs the patches above and keeps them on the Hyprland the titlebars plugin was built against when Arch moves first. Move both architectures and the plugin to a newer Hyprland in one change, with a `pkgrel` above Arch's for the same version so a machine already on Arch's build moves to this one.

## PGO

The recipe can build Hyprland with profile guided optimization (GCC). It is off by default: without the variables below the build is the plain one, and the published packages stay plain until a profile is trained for the build machine's path.

- `PGO_GENERATE=DIR makepkg` builds an instrumented Hyprland with `pkgrel=0.1`, so it sorts before every real release and `pacman -Syu` replaces it. Hyprland, hyprctl, hyprpm and start-hyprland write their counters into `DIR` when they exit, so `DIR` has to be writable by the session's user (`mkdir -m 1777`). Install it, use a session for the workloads to train, then end the session; Hyprland writes the counters on a clean exit (SIGTERM, `hyprctl dispatch exit`), not when it is killed.
- `PGO_PROFILE=DIR makepkg` builds with the counters in `DIR`. Merge the counters of several machines with `gcov-tool merge -o OUT A B`.

GCC matches a function to its counters by a checksum that contains the absolute path of its source file, and `-fprofile-prefix-map` does not change that. A profile therefore fits only a build in the same `BUILDDIR` as the training's instrumented build: train and build with one fixed `BUILDDIR`. A function whose source or patches changed since the training builds without its profile and warns (`-Wno-error=coverage-mismatch`), so a stale profile never fails the build; retrain on a version bump.
