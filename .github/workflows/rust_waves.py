#!/usr/bin/env python3
# rust_waves.py <topsrcdir> <topobjdir> <wave-count> <max-minutes>
#
# Splits gkrust's Rust build into ordered waves, each a set of in-tree
# packages built by one `cargo build` invocation that COMPLETES inside a
# reclaimed-runner's lifetime. Wave N only depends on waves < N (topological
# depth), so each completed wave is checkpointable and the final `mach build
# binaries` gkrust invocation finds the wave artifacts (feature-exact where
# possible) and only does the remainder.
#
# Per-crate costs come from CI logs when $FENNEC_LOGS/r*.log exist
# (per-crate seconds from mach's progress lines); unknown crates get the
# median. Outputs <topobjdir>/rust_waves.json.
import json
import os
import re
import subprocess
import sys

topsrcdir = os.path.abspath(sys.argv[1])
topobjdir = os.path.abspath(sys.argv[2])
wave_count = int(sys.argv[3])
max_minutes = float(sys.argv[4])
logdir = os.environ.get("FENNEC_LOGS", "")

LINE_RE = re.compile(
    r"^\s+(\d+):(\d{2})\.(\d+)\s+(Compiling|Fresh|Checking)\s+(\S+)"
)


def log_costs():
    costs = {}
    if not logdir or not os.path.isdir(logdir):
        return costs
    for name in sorted(os.listdir(logdir)):
        if not re.match(r"r\d+\.log$", name):
            continue
        try:
            lines = open(os.path.join(logdir, name), errors="replace").read().splitlines()
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


def cargo_metadata():
    p = subprocess.run(
        [
            "cargo", "metadata", "--format-version", "1",
            "--manifest-path", os.path.join(topsrcdir, "toolkit/library/rust/Cargo.toml"),
            "--features", "for_xul,glean_with_gecko",
        ],
        cwd=topsrcdir,
        capture_output=True,
        text=True,
    )
    if p.returncode != 0:
        sys.stderr.write(p.stderr[-4000:])
        raise SystemExit("cargo metadata failed")
    return json.loads(p.stdout)


def main():
    costs = log_costs()
    meta = cargo_metadata()
    pkgs = {p["id"]: p for p in meta["packages"]}

    def norm(pid):
        m = re.match(r"^([A-Za-z0-9_+-]+) ([^ ]+) ", pid)
        return m.group(1), m.group(2)

    inv = {}
    for p in pkgs.values():
        inv.setdefault(norm(p["id"])[0], []).append(p["id"])

    def in_tree(pid):
        return pkgs[pid]["manifest_path"].startswith(topsrcdir)

    # resolved features per package in the FULL gkrust graph
    resolve = {}
    for node in meta.get("resolve", {}).get("nodes", []):
        resolve[node["id"]] = set(node.get("features", []))

    # full-build features on an in-tree crate = union of its resolved
    # features and the features its dependents enable (the resolve nodes
    # already carry the resolved set; use that directly)
    feats = {pid: resolve.get(pid, set()) for pid in inv if in_tree(pid)}

    # topological depth (0 = leaf)
    depth = {}

    def dep_depth(pid):
        if pid in depth:
            return depth[pid]
        depth[pid] = 0  # cycle guard
        d = 0
        for pdep in pkgs[pid]["dependencies"]:
            for t in inv.get(pdep["name"], []):
                if in_tree(t):
                    d = max(d, dep_depth(t) + 1)
        depth[pid] = d
        return d

    for pid in inv:
        if in_tree(pid):
            dep_depth(pid)

    vals = sorted(costs.values())
    median = vals[len(vals) // 2] if vals else 60

    def cost(pid):
        nm = norm(pid)[0]
        return costs.get(nm, median)

    by_depth = {}
    for pid in inv:
        if in_tree(pid):
            by_depth.setdefault(depth[pid], []).append(pid)

    # greedy: pack depths (deepest first is not required; keep natural order)
    # into waves of <= max_minutes, then merge smallest adjacent pairs to
    # reach at most wave_count.
    max_cost = max_minutes * 60
    waves = []
    cur, cur_cost = set(), 0
    for d in sorted(by_depth):
        pk = by_depth[d]
        dcost = sum(cost(p) for p in pk)
        if cur and cur_cost + dcost > max_cost:
            waves.append(cur)
            cur, cur_cost = set(), 0
        cur |= set(pk)
        cur_cost += dcost
    if cur:
        waves.append(cur)

    while len(waves) > wave_count:
        best_i, best = 0, None
        for i in range(len(waves) - 1):
            c = sum(cost(p) for p in waves[i]) + sum(cost(p) for p in waves[i + 1])
            if best is None or c < best:
                best, best_i = c, i
        waves[best_i] = waves[best_i] | waves[best_i + 1]
        del waves[best_i + 1]

    out = {"waves": []}
    for i, w in enumerate(waves, 1):
        pkgs_out = []
        for pid in w:
            nm = norm(pid)[0]
            pkgs_out.append({"name": nm, "features": sorted(feats.get(pid, set()))})
        pkgs_out.sort(key=lambda p: p["name"])
        out["waves"].append(
            {
                "n": i,
                "packages": pkgs_out,
                "est_seconds": int(sum(cost(p) for p in w)),
            }
        )
    dest = os.path.join(topobjdir, "rust_waves.json")
    os.makedirs(topobjdir, exist_ok=True)
    json.dump(out, open(dest, "w"), indent=1)
    for w in out["waves"]:
        print(
            f"wave {w['n']}: {len(w['packages'])} pkgs, est {w['est_seconds']}s"
        )
    print("wrote", dest)
    print(f"total in-tree crates: {sum(len(w['packages']) for w in out['waves'])}")


if __name__ == "__main__":
    main()
