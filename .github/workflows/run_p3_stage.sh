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

# Sample the job's REAL memory ceiling (cgroup) to the console every 60 s.
# The host-wide `free` never shows a cgroup limit, so without this a build
# that crosses its own memory ceiling dies with no trace in the log.
bash "$(dirname "$0")/cgroup_watch.sh" 60 &
WATCH=$!

# If the runner (or anything else) signals us, say so on STDERR (captured by
# the console), then re-raise with default disposition so the exit code stays
# the true one (143 for TERM).
on_signal() {
    local sig="$1"
    echo "== [$TAG] KILLED by SIG${sig} at $(date -u +%H:%M:%S) UTC (stages='$STAGES') — no build error above this line means the job was interrupted, not failed ==" >&2
    kill "$WATCH" 2>/dev/null || true
    trap - "$sig"
    kill -s "$sig" $$
}
trap 'on_signal TERM' TERM
trap 'on_signal INT'  INT
trap 'on_signal HUP'  HUP

# Output goes straight to the console (STDOUT/STDERR), captured normally.
bash "$(dirname "$0")/build-rest.sh"
rc=$?
kill "$WATCH" 2>/dev/null || true
echo "== [$TAG] rc=$rc $(date -u +%H:%M:%S) UTC df: $(df -h / | tail -1) =="
if [ "$rc" -ne 0 ]; then
    # Surface GitHub's own failure record for this job on the console.
    # Runner-level failures (lost communication / CPU-mem starvation) are
    # recorded in the job's check-run annotations, not the step log — and a
    # run whose runner died can lose the log blob entirely. Print both the
    # annotations and the job's cgroup memory state right now, while the
    # runner still has network.
    bash "$(dirname "$0")/ci_annotations.sh" || true
    echo "== [$TAG] final cgroup memory state (rc=$rc): =="
    bash -c '
      [ -r /sys/fs/cgroup/memory.max ] && {
        echo "  cg2 max=$(cat /sys/fs/cgroup/memory.max) cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null) peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null)"
      }
      [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && {
        echo "  cg1 limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes) usage=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)"
      }
      echo "  swap: $(free -h | awk "/Swap:/{print \$3\" used / \"\$2\" total\"}")"
    ' 2>/dev/null || true
fi
exit "$rc"
