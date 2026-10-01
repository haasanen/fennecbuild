#!/usr/bin/env python3
"""bump_version.py <NEW_CODE> — bump ALL version sites in release.yml atomically.

2026-10-01: a hand-edit bumped only the workflow_dispatch `default:` line,
leaving the five push-triggered fallbacks (prebuild, fingerprint, SIGNED apk
name, TAG, release notes/title) on the old code — the in-flight run then
shipped as the old version. This script edits every site at once and fails
loudly if the expected old value is not found at every site.

Usage: bump_version.py 1550025 [path/to/release.yml]
"""
import re
import sys

path = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/scripts/android_work/fennecbuild/.github/workflows/release.yml"
new = sys.argv[1]
if not re.fullmatch(r"\d{7}", new):
    sys.exit(f"bad version code {new!r} (want 7 digits, scheme XYZAR)")

t = open(path).read()
old = re.search(r"default: \"(\d{7})\"", t)
if not old:
    sys.exit("no workflow_dispatch default version found — aborting")
old_v = old.group(1)
if old_v == new:
    print(f"already at {new}; nothing to do")
    sys.exit(0)

n = len(re.findall(re.escape(old_v), t))
if n < 6:
    sys.exit(f"expected {old_v} at >= 6 sites, found {n} — inspect manually")

t2 = t.replace(old_v, new)
open(path, "w").write(t2)
print(f"{old_v} -> {new} at {n} sites (default + 5 push fallbacks)")
