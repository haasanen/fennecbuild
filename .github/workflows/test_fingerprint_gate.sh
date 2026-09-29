#!/usr/bin/env bash
# Fingerprint gate for the unit-test stages.
#
#   run_p3_stage_test.sh "gecko_gv|fenix" <fingerprint>
#
# The unit tests only run when the RESULT CACHE for this fingerprint is
# missing (i.e. this exact source+version+patch state has never passed the
# suite here). On a cache hit the step exits 0 immediately — no test
# compilation, no suite, straight on to the compile stage. On a miss the
# full suite runs BEFORE anything compiles; a test failure fails the run at
# the gate (minutes into the build, not 2.5 h into it). A passing suite
# writes the marker that the workflow's cache-save step then stores under
# the fingerprint key.
#
# The marker lives in a path the cache step restores+saves, PER STAGE (a
# passing geckoview suite must not make the fenix gate skip):
#   ~/.fennec-tests/<fingerprint>/<stage>/passed
set -euo pipefail
STAGE="$1"
FINGERPRINT="$2"
source "$(dirname "$0")/../../paths.sh"
# paths.sh has no 'root' (build-rest.sh defines it locally): the locales
# list lives at the fennecbuild repo root, two levels above this script.
root="$(cd "$(dirname "$0")/../.." && pwd)"

MARKER_DIR="$HOME/.fennec-tests/$FINGERPRINT/$STAGE"
MARKER="$MARKER_DIR/passed"
if [ -f "$MARKER" ]; then
  echo "test gate [$STAGE]: fingerprint $FINGERPRINT has a passing marker — skipping the suite"
  exit 0
fi

echo "test gate [$STAGE]: fingerprint $FINGERPRINT has NO result cache — running the full suite (before any compile)"
case "$STAGE" in
  gecko_gv)
    pushd "$mozilla_release"
    read -ra locales < "$root/locales"
    MOZ_CHROME_MULTILOCALE="${locales[*]}" gradle :geckoview:testReleaseUnitTest
    popd
    ;;
  fenix)
    pushd "$fenix"
    gradle :app:testReleaseUnitTest
    popd
    ;;
  *)
    echo "test gate: unknown stage '$STAGE'" >&2
    exit 2
    ;;
esac

mkdir -p "$MARKER_DIR"
date -u > "$MARKER"
echo "test gate [$STAGE]: suite PASSED — marker written for fingerprint $FINGERPRINT"
