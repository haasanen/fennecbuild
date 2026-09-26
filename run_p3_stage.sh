#!/bin/bash
# run_p3_stage.sh "<stage names>" <tag>
#
# Runs one Phase-3 slice of build-rest.sh (STAGES filter, see that file).
# All output goes to STDOUT/STDERR and is captured by the console as usual.
# The exit code is the build's, so a real compile error fails the step
# (and the job) exactly like the old single Phase-3 step did.
set -o pipefail
STAGES="$1"
TAG="$2"
export STAGES
WS="$GITHUB_WORKSPACE"
echo "== [$TAG] start $(date -u +%H:%M:%S) UTC stages='$STAGES' df: $(df -h / | tail -1) =="

# If the runner (or anything else) signals us, say so on STDERR (captured by
# the console), then re-raise with default disposition so the exit code stays
# the true one (143 for TERM).
on_signal() {
    local sig="$1"
    echo "== [$TAG] KILLED by SIG${sig} at $(date -u +%H:%M:%S) UTC (stages='$STAGES') — no build error above this line means the job was interrupted, not failed ==" >&2
    trap - "$sig"
    kill -s "$sig" $$
}
trap 'on_signal TERM' TERM
trap 'on_signal INT'  INT
trap 'on_signal HUP'  HUP

# Output goes straight to the console (STDOUT/STDERR), captured normally.
bash "$(dirname "$0")/build-rest.sh"
rc=$?
echo "== [$TAG] rc=$rc $(date -u +%H:%M:%S) UTC df: $(df -h / | tail -1) =="
exit "$rc"
