#!/usr/bin/env bash
# Compute the unit-test fingerprint: a hash of exactly the inputs the test
# results depend on. Used as the key for the results cache (fennec-tests-v1-
# <fingerprint>): a HIT means the suite already passed for this exact source
# + version + patch state, so the tests are skipped and the build goes
# straight to compile. A MISS (source changed, version changed, patch tree
# changed) forces the full suite to run BEFORE anything compiles — the tests
# prove themselves first.
#
# Inputs:
#   1. the fennecbuild commit ($GITHUB_SHA) — covers every patch in the repo
#      AND the srclibs pins, which live in release.yml itself (the Clone
#      srclibs step hardcodes the tags/SHAs), so any pin change changes this
#      hash.
#   2. the release version name+code (workflow inputs).
#   3. the patched-tree state of the two test-heavy modules' SOURCES — a
#      belt-and-braces second layer: even if a pin edit forgot to bump
#      anything hashable, the applied source tree is what the tests compile
#      against, so hashing the actual .kt/.java under test catches it.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

VNAME="${1:-155.0.0}"
VCODE="${2:-0}"
SHA="${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"

# The patched tree (paths.sh layout: ../srclib/MozFennec). Optional: if it
# doesn't exist yet (e.g. local prebuild without srclibs) the commit+version
# fingerprint still stands.
TREE=""
if [ -d ../srclib/MozFennec/mobile/android/fenix/app/src ]; then
  TREE=../srclib/MozFennec
fi

{
  printf 'commit=%s\n' "$SHA"
  printf 'version=%s-%s\n' "$VNAME" "$VCODE"
  if [ -n "$TREE" ]; then
    # All android test sources + the sources under test in the two suites.
    ( cd "$TREE" && find \
        mobile/android/geckoview/src/test \
        mobile/android/geckoview/src/main/java/org/mozilla/gecko/ctap2 \
        mobile/android/geckoview/src/main/java/org/mozilla/gecko/util \
        mobile/android/fenix/app/src/test \
        mobile/android/fenix/app/src/main/java/org/mozilla/fenix/components \
        -type f \( -name '*.kt' -o -name '*.java' \) | sort | \
        xargs -r sha256sum )
  fi
} | sha256sum | cut -c1-16
