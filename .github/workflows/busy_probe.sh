#!/bin/bash
# busy_probe.sh <minutes>
#
# Diagnostic probe (diagnostic, remove after the experiment): burn CPU on
# every core for <minutes> while logging disk/memory/load to STDOUT every
# 30 s. No log files, no background state — the console IS the record.
#
# Purpose: test whether the hosted runner terminates the job after a
# finite, roughly fixed job lifetime regardless of what the job is doing.
# A plain sleep would not separate "time" from "load", so real work is done
# (one busy worker per core). If the runner sends the same SIGTERM/shutdown
# signal in the middle of this step, the lifetime hypothesis holds. If the
# step completes, job lifetime is not the trigger and something about the
# build (memory, disk I/O, network, ...) must be.
set -u
MIN="${1:-30}"
END=$(( $(date +%s) + MIN * 60 ))

# Real memory ceiling of THIS job (cgroup), sampled to the console every 30 s.
# `free -h` shows host RAM; the runner may enforce a cgroup limit the build
# can cross without the host-wide numbers ever moving. If the probe dies,
# these lines show exactly how close memory got to its ceiling.
bash "$(dirname "$0")/cgroup_watch.sh" 30 &
WATCH=$!

NCPU=$(nproc)
PIDS=()
for _ in $(seq 1 "$NCPU"); do
    yes > /dev/null 2>&1 &
    PIDS+=($!)
done
trap 'for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done; kill "$WATCH" 2>/dev/null || true' EXIT

echo "busy_probe: start $(date -u +%H:%M:%S) UTC — $NCPU busy workers (pids: ${PIDS[*]}), $MIN min"
echo "busy_probe: df at start: $(df -h / | tail -1)"
echo "busy_probe: mem at start: $(free -h | awk '/Mem:/{print $3" used, "$7" free"}') load: $(cut -d" " -f1-3 /proc/loadavg)"

while [ "$(date +%s)" -lt "$END" ]; do
    sleep 30
    REM=$(( END - $(date +%s) ))
    [ "$REM" -lt 0 ] && REM=0
    echo "busy_probe $(date -u +%H:%M:%S) UTC: ${REM}s remaining | df: $(df -h / | tail -1 | awk '{print $3" used, "$4" free"}') | mem: $(free -h | awk '/Mem:/{print $3" used, "$7" free"}') | load: $(cut -d" " -f1-3 /proc/loadavg)"
done

echo "busy_probe: COMPLETED after $MIN min at $(date -u +%H:%M:%S) UTC — no shutdown signal during the probe window"
