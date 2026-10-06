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

# One retry on test failures: upstream unit suites carry order/timing-sensitive
# flakes (e.g. DefaultTabManagerUiStateRepositoryTest shares one process-wide
# DataStore whose @After clear races the previous test's async init write —
# the same test passed in run 37450901182 on a near-identical tree).
# A retry re-runs the whole test task (compilation stays up-to-date), so a
# genuine failure fails again and still fails the run. Only retried when the
# build actually executed tests.
run_suite() {
  local out="$1"
  if [ "$STAGE" = gecko_gv ]; then
    pushd "$mozilla_release" >/dev/null
    read -ra locales < "$root/locales"
    # AGP 9 (onlyEnableUnitTestForTheTestedBuildType=true by default) creates
    # only the test task for the tested build type (testBuildType=debug by
    # default) — testReleaseUnitTest no longer exists in AGP 9 projects.
    MOZ_CHROME_MULTILOCALE="${locales[*]}" gradle :geckoview:testDebugUnitTest 2>&1 | tee "$out"
    local rc=${PIPESTATUS[0]}
    popd >/dev/null
  else
    pushd "$fenix" >/dev/null
    gradle :app:testDebugUnitTest 2>&1 | tee "$out"
    local rc=${PIPESTATUS[0]}
    popd >/dev/null
  fi
  return "$rc"
}

SUITE_LOG="$RUNNER_TEMP/suite-$STAGE.log"
if ! run_suite "$SUITE_LOG"; then
  if grep -q "There were failing tests" "$SUITE_LOG"; then
    grep "TEST-UNEXPECTED-FAIL" "$SUITE_LOG" |
      sed 's/.*TEST-UNEXPECTED-FAIL | \(.*\)\.[^.]* |.*/\1/' |
      sort -u > "$RUNNER_TEMP/flaky-$STAGE.txt" || true
    echo "test gate [$STAGE]: suite failed — retrying the failed tests once (flaky-test guard). Suspect classes:"
    cat "$RUNNER_TEMP/flaky-$STAGE.txt" || true
    if ! run_suite "$RUNNER_TEMP/suite-$STAGE-retry.log"; then
      echo "test gate [$STAGE]: suite FAILED again on retry — genuine failure" >&2
      exit 1
    fi
    echo "test gate [$STAGE]: retry PASSED — treated as flaky"
  else
    echo "test gate [$STAGE]: suite failed WITHOUT executing tests (compile/config failure) — no retry" >&2
    exit 1
  fi
fi

mkdir -p "$MARKER_DIR"
date -u > "$MARKER"
echo "test gate [$STAGE]: suite PASSED — marker written for fingerprint $FINGERPRINT"
