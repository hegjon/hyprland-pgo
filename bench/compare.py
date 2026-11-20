#!/usr/bin/env python3
# compare.py RUN_DIR [NIGHT PREV_NIGHT [rows]] : Omarchy's Hyprland as a PGO build (the hyprland blocks of RUN_DIR/<host>,
# fetched by report.sh) against the stock blocks of Hypoland's night A/B run NIGHT, from the block files themselves.
#   P   = this run: the PGO build, RUN_DIR/<host>/hyprland-N.txt
#   S18 = NIGHT's stock, S17 = PREV_NIGHT's stock (the night-to-night drift of the same binary: the noise floor)
#   H18 = NIGHT's Hypoland, for the reference; HP = RUN's Hypoland blocks, if it alternated (the control when it is the
#         same Hypoland package as NIGHT's)
# Nights are $HYPOLAND_TREE/test-results/<night>/<night>/<host> (default ~/Work/hypoland, night-20261118 and -17).
# Per machine and metric group the median ratio; then the metrics where PGO moved by more than 10% and its median lies
# outside the stock night's per-block range.
import glob, os, re, statistics, sys
RUN = os.path.abspath(sys.argv[1])
NIGHT, PREV = (sys.argv[2], sys.argv[3]) if len(sys.argv) > 3 else ("night-20261118", "night-20261117")
T = os.environ.get("HYPOLAND_TREE", os.path.expanduser("~/Work/hypoland")) + "/test-results"
HOSTS = ["t550", "xps", "chromebook", "t460s", "t490", "samsung-i5", "p14s"]
def blocks(d, prefix):
    """{key: [value per block]} over prefix-N.txt and prefix-N-startup.txt, without the workloads measure.sh marked
    invalid in that block (@ N invalid.<workload> 1: e.g. a client of an earlier workload still running)"""
    vals = {}
    for f in glob.glob(f"{d}/{prefix}-[0-9]*.txt"):
        rows = [l.split() for l in open(f, errors="replace")]
        rows = [p for p in rows if len(p) >= 4 and p[0] == "@"]
        bad = {p[2].split(".", 1)[1] for p in rows if p[2].startswith("invalid.")}
        for p in rows:
            if p[2].startswith("invalid.") or p[2].split(".")[1:2] and p[2].split(".")[1] in bad: continue
            try: v = float(p[3])
            except ValueError: continue
            vals.setdefault(p[2], []).append(v)
    return vals
def med(vals, k, n=2):
    v = vals.get(k)
    return statistics.median(v) if v and len(v) >= n else None
N = {
    "p":   lambda h: blocks(f"{RUN}/{h}", "hyprland"),
    "s18": lambda h: blocks(f"{T}/{NIGHT}/{NIGHT}/{h}", "hyprland"),
    "s17": lambda h: blocks(f"{T}/{PREV}/{PREV}/{h}", "hyprland"),
    "h18": lambda h: blocks(f"{T}/{NIGHT}/{NIGHT}/{h}", "hypoland"),
    "hp":  lambda h: blocks(f"{RUN}/{h}", "hypoland"),
}
GROUPS = [("cpu %", r"^cpu\.[^.]*\.percent$"), ("cpu ms/frame", r"^cpu\..*\.ms_per_frame$"),
          ("latency", r"^latency\..*(?<!p90)_ms$"), ("fps", r"^fps\.[^.]*(\.screen)?$"),
          ("pss start", r"^mem\.start\.Pss_kB$"), ("startup", r"^startup\..*_ms$")]
data = {h: {n: f(h) for n, f in N.items()} for h in HOSTS}
def ratio(h, k, a, b, floor=0.0):
    x, y = med(data[h][a], k), med(data[h][b], k)
    if x is None or y is None or y <= floor or x < 0: return None
    return x / y
def gmed(h, rx, a, b):
    r = [x for k in data[h][a] if re.search(rx, k) for x in [ratio(h, k, a, b, 0.05)] if x]
    return "%.3f (%d)" % (statistics.median(r), len(r)) if r else "-"
cols = [("PGO/stock", "p", "s18"), ("stock 18/17", "s18", "s17"), ("hypoland/stock", "h18", "s18")]
# a run that alternates with Hypoland (ABNIGHT_ORDER="hypoland hyprland"): the same Hypoland package as NIGHT is the
# control for the machines' own drift between NIGHT and this run
if any(data[h]["hp"] for h in HOSTS): cols.insert(1, ("hypoland run/night", "hp", "h18"))
print("blocks per machine (PGO this run / stock 11-18 / stock 11-17):")
for h in HOSTS:
    c = lambda n: max((len(v) for k, v in data[h][n].items() if k.startswith("cpu.")), default=0)
    print("  %-11s %3d / %3d / %3d" % (h, c("p"), c("s18"), c("s17")))
for g, rx in GROUPS:
    print(f"\n### {g}: median ratio over the metrics (count); below 1 is less (better for cpu, latency, pss; worse for fps)")
    print("%-11s" % "" + "".join("%20s" % c[0] for c in cols))
    for h in HOSTS:
        print("%-11s" % h + "".join("%20s" % gmed(h, rx, a, b) for _, a, b in cols))
print("\n### metrics where PGO moved against stock 11-18 by more than 10%, the stock drift 18/17 was less than half")
print("### of that, and PGO's median is outside stock 11-18's per-block range (out=yes)")
print("%-11s %-46s %10s %10s %8s %8s %18s %4s" % ("machine", "metric", "stock", "PGO", "ratio", "drift", "stock range", "out"))
rows = []
for h in HOSTS:
    for k in data[h]["p"]:
        if not re.search(r"ms_per_frame$|^latency\..*(?<!p90)_ms$|^fps\.[^.]*(\.screen)?$|^cpu\.[^.]*\.percent$|^mem\.start\.Pss_kB$|^startup\..*_ms$", k): continue
        r = ratio(h, k, "p", "s18", 0.3)
        if r is None or 0.91 < r < 1.10: continue
        s = ratio(h, k, "s18", "s17", 0.05)
        if s is not None and abs(s - 1) > abs(r - 1) / 2: continue
        old = data[h]["s18"][k]
        m = med(data[h]["p"], k)
        out = m < min(old) or m > max(old)
        rows.append((out, abs(r - 1), h, k, med(data[h]["s18"], k), m, r, s, min(old), max(old)))
for out, _, h, k, x, y, r, s, lo, hi in sorted(rows, reverse=True)[:int(sys.argv[4]) if len(sys.argv) > 4 else 60]:
    f = lambda v: "%.3f" % v if v is not None else "-"
    print("%-11s %-46s %10.2f %10.2f %8s %8s %8.2f..%-8.2f %4s" % (h, k[:46], x, y, f(r), f(s), lo, hi, "yes" if out else "no"))
