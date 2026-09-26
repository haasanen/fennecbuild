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

# Sample the job's REAL resource use (top-5 processes by RSS, total RSS of
# rustc/cargo/clang/lld, mem/swap) to the console every 30 s — fine enough
# to catch the geckoservo codegen peak. Console only, no files.
bash "$(dirname "$0")/resource_watch.sh" 30 &
WATCH=$!

# If the runner (or anything else) signals us, say so on STDERR (captured by
# the console), then re-raise with default disposition so the exit code stays
# the true one (143 for TERM).
on_signal() {
    local sig="$1"
    echo "== [$TAG] KILLED by SIG${sig} at $(date -u +%H:%M:%S) UTC (stages='$STAGES') — no build error above this line means the job was interrupted, not failed ==" >&2
    # Snapshot the resource state AT the moment of death to the console
    # (local only, no network — the runner is shutting down). The res_watch
    # 30s samples show the trajectory; this is the final frame.
    bash -c '
      echo "== [$TAG] memory at signal: $(free -h | awk "/Mem:/{print \$3\" used, \"\$7\" free\"}") | swap: $(free -h | awk "/Swap:/{print \$3\" used\"}")"
      echo "== [$TAG] top5 RSS at signal: $(ps -eo rss=,comm= | sort -rn | head -5 | awk "{printf \"%s(%dMiB) \", \$2, \$1/1024}")"
    ' 2>/dev/null >&2 || true
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
    # annotations and the job's memory state right now, while the runner
    # still has network.
    bash "$(dirname "$0")/ci_annotations.sh" || true
    echo "== [$TAG] final memory state (rc=$rc): =="
    bash -c '
      echo "  mem: $(free -h | awk "/Mem:/{print \$3\" used, \"\$7\" free\"}")"
      echo "  swap: $(free -h | awk "/Swap:/{print \$3\" used / \"\$2\" total\"}")"
      echo "  top5 by RSS: $(ps -eo rss=,comm= | sort -rn | head -5 | awk "{printf \"%s(%dMiB) \", \$2, \$1/1024}")"
    ' 2>/dev/null || true
fi
exit "$rc"
