#!/usr/bin/env python3
# generate_rust_waves.py <topsrcdir> <wave-count> <max-minutes> [log-dir]
#
# Splits gkrust's Rust build into <wave-count> ordered waves.
# Each wave is a set of in-tree packages such that every package's resolved
# feature set is identical to the full gkrust build's. Wave N only depends
# on waves < N (topological depth), so waves can be built one cargo
# invocation at a time and each completed wave is checkpointable.
#
# Costs come from real CI logs when <log-dir>/r*.log exists (per-crate
# seconds from mach's progress lines); unknown crates get the median.
import json
import os
import re
import subprocess
import sys

topsrcdir = os.path.abspath(sys.argv[1])
wave_count = int(sys.argv[2])
max_minutes = float(sys.argv[3])
logdir = sys.argv[4] if len(sys.argv) > 4 else ""

LINE_RE = re.compile(
    r"^\s+(\d+):(\d{2})\.(\d+)\s+(Compiling|Fresh|Checking)\s+(\S+)"
)


def log_costs():
    costs = {}
    if not logdir or not os.path.isdir(logdir):
        return costs
    for lp in sorted(
        os.path.join(logdir, f)
        for f in os.listdir(logdir)
        if re.match(r"r\d+\.log$", f)
    ):
        try:
            lines = open(lp, errors="replace").read().splitlines()
        except OSError:
            continue
        prev = None
        for ln in lines:
            m = LINE_RE.match(ln)
            if not m:
                continue
            mm, ss, frac, verb, crate = m.groups()
            t = int(mm) * 60 + int(ss) + int(frac) / 100
            if verb != "Compiling":
                continue
            if prev is None:
                prev = t
                continue
            dt = t - prev
            if 0 < dt <= 180:
                costs[crate] = max(costs.get(crate, 0), dt)
            prev = t
    return costs


def cargo_metadata(args):
    p = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--frozen", *args],
        cwd=topsrcdir,
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        sys.stderr.write(p.stderr)
        raise SystemExit("cargo metadata failed")
    return json.loads(p.stdout)


def main():
    costs = log_costs()
    full = cargo_metadata(
        [
            "--manifest-path",
            os.path.join(topsrcdir, "toolkit/library/rust/Cargo.toml"),
            "--features",
            "for_xul,glean_with_gecko",
        ]
    )
    pkgs = {p["id"]: p for p in full["packages"]}

    def norm(pid):
        m = re.match(r"^([A-Za-z0-9_+-]+) ([^ ]+) ", pid)
        return (m.group(1), m.group(2))

    inv = {}
    for p in pkgs.values():
        inv.setdefault(norm(p["id"]), []).append(p["id"])

    def in_tree(pid):
        return pkgs[pid]["manifest_path"].startswith(topsrcdir)

    # edges: dep -> set of (dependent, features the dependent enables)
    edges = {}
    for p in pkgs.values():
        if not in_tree(p["id"]):
            continue
        for d in p["dependencies"]:
            for target in inv.get(d["name"], []):
                if in_tree(target):
                    edges.setdefault(target, set()).add(
                        (p["id"], frozenset(d.get("features", [])))
                    )

    # feats[pid] = features the FULL build enables on pid
    feats = {pid: set() for pid in inv}
    changed = True
    while changed:
        changed = False
        for dep_id, edgeset in edges.items():
            new = set()
            for _src, f in edgeset:
                new |= f
            if new - feats[dep_id]:
                feats[dep_id] |= new
                changed = True

    depth = {}

    def dep_depth(pid):
        if pid in depth:
            return depth[pid]
        depth[pid] = 0
        d = 0
        for pdep in pkgs[pid]["dependencies"]:
            for t in inv.get(pdep["name"], []):
                if in_tree(t):
                    d = max(d, dep_depth(t) + 1)
        depth[pid] = d
        return d

    for pid in inv:
        dep_depth(pid)

    median = sorted(costs.values())[len(costs) // 2] if costs else 60

    def cost(pid):
        nm = norm(pid)[0]
        return costs.get(nm, median)

    by_depth = {}
    for pid in inv:
        by_depth.setdefault(depth[pid], []).append(pid)

    max_cost = max_minutes * 60
    waves = []
    cur = set()
    cur_cost = 0
    for d in sorted(by_depth):
        pk = by_depth[d]
        dcost = sum(cost(p) for p in pk)
        if cur and cur_cost + dcost > max_cost:
            waves.append(cur)
            cur = set()
            cur_cost = 0
        cur |= set(pk)
        cur_cost += dcost
    if cur:
        waves.append(cur)

    while len(waves) > wave_count:
        best_i, best = 0, None
        for i in range(len(waves) - 1):
            c = sum(cost(p) for p in waves[i]) + sum(cost(p) for p in waves[i + 1])
            if best is None or c < best:
                best = c
                best_i = i
        waves[best_i] = waves[best_i] | waves[best_i + 1]
        del waves[best_i + 1]

    real = {norm(pid)[0] for pid in inv}
    out = {"waves": []}
    for i, w in enumerate(waves, 1):
        feats_needed = set()
        for pid in w:
            feats_needed |= feats[pid]
        feats_needed &= real
        out["waves"].append(
            {
                "n": i,
                "packages": sorted(norm(p)[0] for p in w),
                "features": sorted(feats_needed),
                "est_seconds": int(sum(cost(p) for p in w)),
            }
        )
    dest = os.path.join(topsrcdir, "obj", "rust_waves.json")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    json.dump(out, open(dest, "w"), indent=1)
    for w in out["waves"]:
        print(
            f"wave {w['n']}: {len(w['packages'])} pkgs, est {w['est_seconds']}s, "
            f"{len(w['features'])} features"
        )
    print("wrote", dest)


if __name__ == "__main__":
    main()
