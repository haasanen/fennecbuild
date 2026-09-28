#!/bin/bash
# stop_gradle_daemons.sh — free RAM held by lingering Gradle daemon JVMs.
#
# Why: each gradle version in this build (8.14.3 glean/app-services,
# 9.7.0 in-tree geckoview/fenix) runs its OWN daemon JVM, and daemons outlive
# the stage that started them. By Phase 3e (Fenix assembleRelease) three daemons
# were resident (~4.6+3.1+0.7 GiB, run 36335035837 res_watch) leaving <6 GiB
# free — and 3e is the heaviest gradle build in the pipeline. The runner then
# lost communication ("starves it for CPU/Memory", annotation) — the same
# failure class that killed the binaries tier until we stopped daemons there
# (runs 36274687731, 36276000119: java 3.1-3.9 GiB -> 1.3 GiB after the stop).
#
# Stopping an IDLE daemon is free: the next gradle invocation in a later stage
# starts a fresh one (a few seconds). Called before every heavy gradle stage.
set -uo pipefail

rss() {
  # total RSS (MiB) of processes whose command line matches a gradle daemon
  ps -eo rss=,args= 2>/dev/null | awk '/[G]radleDaemon|org\.gradle\.launcher/{s+=$1} END{printf "%d", s/1024}'
}

before=$(rss)
echo "gradle-daemon RSS before: ${before:-0}MiB"

gradle --stop 2>/dev/null || true
# gradle --stop only reaches the version on PATH (9.7.0 via the shim);
# the 8.13/8.14.3 daemons must be killed directly.
for p in $(pgrep -f "GradleDaemon" 2>/dev/null); do
  echo "stopping lingering gradle daemon pid $p"
  kill "$p" 2>/dev/null || true
done
sleep 5

after=$(rss)
echo "gradle-daemon RSS after: ${after:-0}MiB"
free -h | head -2
