#!/bin/bash
#
#    Fennec build scripts
#    Copyright (C) 2020-2024  Matías Zúñiga, Andrew Nayenko, Tavi
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public
#    License along with this program.  If not, see
#    <https://www.gnu.org/licenses/>.
#
# ci_heartbeat.sh <workspace-dir> <build-log>
#
# Background heartbeat: every 240 s, push a small state file (disk, memory,
# and the tail of the build log) to the `ci-logs` branch of this repository.
# If a GitHub-hosted runner dies mid-build, the last heartbeat on that branch
# is the only forensics available — the repo PAT cannot download job logs or
# artifacts (no admin scope), so this branch is the readable record.
#
# Forensics (2026-09-21): the original version never pushed (ci-logs branch
# absent after two runs) and failed SILENTLY: clone stderr went to /dev/null,
# a hung credential prompt would hang the loop forever, and a failing
# `checkout -b` exited the script at the `|| break`. Fixed: token via
# GIT_ASKPASS (no prompt possible), clone timeouts + fallback, clone/push
# stderr captured to $WORK/ci_heartbeat_debug.log, and the loop can no longer
# die silently.

WORK="$1"
LOG="$2"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo "ci_heartbeat: no GITHUB_TOKEN — heartbeat disabled"
    exit 0
fi
REPO_URL="https://***@${GITHUB_SERVER_URL:-github.com}/haasanen/fennecbuild.git"

# Git may prompt for credentials if the token in the URL is rejected; on a
# non-interactive runner that HANGS. GIT_ASKPASS makes credential requests
# explicit: they use the token once and fail cleanly instead of hanging.
ASKPASS="$WORK/.git_askpass.sh"
printf '#!/bin/sh\ncase "$1" in *ser*name*) printf %%s "ci-heartbeat" ;; *) printf %%s "%s" ;; esac\n' "$TOKEN" > "$ASKPASS"
chmod 700 "$ASKPASS"

HBD="$WORK/ci_heartbeat_debug.log"
{
    echo "=== heartbeat started $(date -u +%H:%M:%S) UTC run=${GITHUB_RUN_ID} log=$LOG ==="
    df -h / | tail -1
    ls -la "$LOG" 2>&1
} >> "$HBD" 2>&1

n=0
while true; do
    n=$((n + 1))
    TMP=$(mktemp -d)
    if ! git clone -q --timeout=60 --depth 1 --branch ci-logs "$REPO_URL" "$TMP" \
            2>>"$HBD"; then
        # First heartbeat of the run: the branch does not exist yet.
        rm -rf "$TMP"; TMP=$(mktemp -d)
        if ! git clone -q --timeout=60 "$REPO_URL" "$TMP" 2>>"$HBD"; then
            echo "heartbeat#$n $(date -u +%H:%M:%S) clone failed (see $HBD)" >> "$HBD"
            rm -rf "$TMP"
            sleep 240
            continue
        fi
    fi
    if [ ! -d "$TMP/.git" ]; then
        echo "heartbeat#$n $(date -u +%H:%M:%S) clone produced no .git — skipping" >> "$HBD"
        rm -rf "$TMP"
        sleep 240
        continue
    fi
    (
        cd "$TMP" 2>/dev/null || exit 9
        if ! git show-ref --verify --quiet refs/heads/ci-logs 2>>"$HBD"; then
            if ! git checkout -q -b ci-logs 2>>"$HBD"; then
                git checkout -q --track origin/ci-logs 2>>"$HBD" || exit 8
            fi
        fi
        {
            echo "=== $(date -u +%H:%M:%S) UTC  run=${GITHUB_RUN_ID} sha=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null) ==="
            df -h / | tail -1
            free -h | head -2
            echo "--- build log tail (last 60 lines) ---"
            tail -n 60 "$LOG" 2>/dev/null
        } > heartbeat.txt
        git config user.name "fennec-ci"
        git config user.email "fennec-ci@users.noreply.github.com"
        git add heartbeat.txt
        # Self-report: if the push itself is failing, the debug log tells us why —
        # and the job-logs artifact is unreadable (PAT lacks artifact scope), so
        # the branch is the only channel back.
        if [ -s "$HBD" ]; then cp "$HBD" heartbeat_debug.txt; git add heartbeat_debug.txt; fi
        git commit -qm "heartbeat $(date -u +%H:%M:%S) run=${GITHUB_RUN_ID}" 2>>"$HBD"
        # A concurrent run (or a late heartbeat) can make the push fail; that
        # just drops one heartbeat, it must never affect the build.
        if GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 timeout 120 \
                git push -q -f origin ci-logs >>"$HBD" 2>&1; then
            echo "heartbeat#$n $(date -u +%H:%M:%S) pushed OK" >> "$HBD"
        else
            rc=$?
            echo "heartbeat#$n $(date -u +%H:%M:%S) PUSH FAILED rc=$rc" >> "$HBD"
            echo "WARNING: fennec ci-logs heartbeat push failed (rc=$rc) — see ci_heartbeat_debug.log in the build-logs artifact"
        fi
        # Fallback record in the workspace: if the push never works, the
        # build-logs artifact still carries the last known state.
        cp heartbeat.txt "$WORK/heartbeat_state.txt" 2>/dev/null || true
        exit 0
    ) 2>>"$HBD"
    rm -rf "$TMP"
    sleep 240
done
