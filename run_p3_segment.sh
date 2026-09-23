#!/usr/bin/env bash
# run_p3_segment.sh "<stages>" <tag> [timeout_seconds]
#
# Time-boxed run of one build-rest.sh slice for the P3b1 segmented
# `mach build` (see release.yml). Plain timeout(1) would only signal its
# DIRECT child (the bash wrapper); the real workers (mach -> ninja -> rustc)
# live in that child's process group and would survive as orphans still
# writing into obj/ while the NEXT segment starts a second build on the same
# tree — a two-writer race that corrupts nothing (the FS is safe) but makes
# both builds wrong and burns the whole checkpoint. So: run the slice as its
# own session/process group (setsid) and deadline-kill the WHOLE group.
#
#   setsid note: the child forked by `&` is not a group leader, so setsid
#   execs bash in place -> $! is the new group id (kill -- -PGID works).
#
# Exit: build's rc on natural finish; 124 (timeout(1) convention) if the
# deadline killed it; teardown escalates TERM -> KILL after 45 s.
set -u
STAGES="$1"
TAG="$2"
SECS="${3:-360}"
WS="${GITHUB_WORKSPACE:-$(pwd)}"
FLAG="$WS/.p3_segment_deadline.$$"
rm -f "$FLAG"

setsid bash "$(dirname "$0")/run_p3_stage.sh" "$STAGES" "$TAG" &
pg=$!
(
    sleep "$SECS"
    if kill -0 "$pg" 2>/dev/null; then
        : > "$FLAG"
        echo "run_p3_segment: deadline ${SECS}s reached -> killing process group $pg (mach/ninja/rustc)"
        kill -TERM -"$pg" 2>/dev/null
        sleep 45
        kill -KILL -"$pg" 2>/dev/null
    fi
) &
watchdog=$!

rc=0
wait "$pg" || rc=$?
kill "$watchdog" 2>/dev/null
wait "$watchdog" 2>/dev/null

if [ -f "$FLAG" ]; then
    rm -f "$FLAG"
    echo "run_p3_segment [$TAG]: expired at ${SECS}s (group killed; build rc was $rc) -> rc=124"
    exit 124
fi
exit "$rc"
