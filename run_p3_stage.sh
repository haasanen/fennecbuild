#!/bin/bash
# run_p3_stage.sh "<stage names>" <tag>
#
# Runs one Phase-3 slice of build-rest.sh (STAGES filter, see that file).
# The exit code is the build's, so a real compile error fails the step
# (and the job) exactly like the old single Phase-3 step did.
set -o pipefail
STAGES="$1"
TAG="$2"
export STAGES
WS="$GITHUB_WORKSPACE"
LOG="$WS/build_$TAG.log"
echo "== [$TAG] start $(date -u +%H:%M:%S) UTC stages='$STAGES' df: $(df -h / | tail -1) =="

# If the runner (or anything else) signals us, say so IN THE LOG before dying:
# console + per-tag log (uploaded as the build-logs artifact), then re-raise
# with default disposition so the exit code stays the true one (143 for TERM).
on_signal() {
    local sig="$1"
    echo "== [$TAG] KILLED by SIG${sig} at $(date -u +%H:%M:%S) UTC (stages='$STAGES') — last stage marker above; no build error if nothing precedes this line ==" | tee -a "$WS/build_full.log" "$LOG" >&2
    trap - "$sig"
    kill -s "$sig" $$
}
trap 'on_signal TERM' TERM
trap 'on_signal INT'  INT
trap 'on_signal HUP'  HUP

# stdbuf: line-buffer tee's FILE writes. Without this, tee (a stdio program)
# file-buffers, and a mid-build SIGTERM kills it with up to 64 KB of the last
# lines still in its buffer — lost from every log, i.e. swallowed. With it,
# the on-disk log is at most one line behind the console at any moment.
bash "$(dirname "$0")/build-rest.sh" 2>&1 | stdbuf -oL -eL tee -a "$WS/build_full.log" "$LOG"
rc=${PIPESTATUS[0]}
echo "== [$TAG] rc=$rc $(date -u +%H:%M:%S) UTC df: $(df -h / | tail -1) =="
exit "$rc"
