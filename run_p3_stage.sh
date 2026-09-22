#!/bin/bash
# run_p3_stage.sh "<stage names>" <tag>
#
# Runs one Phase-3 slice of build-rest.sh (STAGES filter, see that file) and
# tees its output to build_full.log (heartbeat + 'Locate unsigned APK'
# expect it) and to build_<tag>.log (uploaded as a build-logs artifact).
# The exit code is the build's, so a real compile error fails the step (and
# the job) exactly like the old single Phase-3 step did.
set -o pipefail
STAGES="$1"
TAG="$2"
export STAGES
WS="$GITHUB_WORKSPACE"
echo "== [$TAG] start $(date -u +%H:%M:%S) UTC stages='$STAGES' df: $(df -h / | tail -1) =="
bash "$(dirname "$0")/build-rest.sh" 2>&1 | tee -a "$WS/build_full.log" "$WS/build_$TAG.log"
rc=${PIPESTATUS[0]}
echo "== [$TAG] rc=$rc $(date -u +%H:%M:%S) UTC df: $(df -h / | tail -1) =="
exit "$rc"
