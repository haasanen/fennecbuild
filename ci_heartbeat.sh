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

WORK="$1"
LOG="$2"

TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ]; then
    echo "ci_heartbeat: no GITHUB_TOKEN — heartbeat disabled"
    exit 0
fi
REPO_URL="https://x-acce...OKEN}@${GITHUB_SERVER_URL:-github.com}/haasanen/fennecbuild.git"

while true; do
    TMP=$(mktemp -d)
    if git clone -q --depth 1 --branch ci-logs "$REPO_URL" "$TMP" 2>/dev/null; then
        :
    else
        # First heartbeat of the run: create the branch from the repo.
        git clone -q --depth 1 "$REPO_URL" "$TMP" 2>/dev/null || break
        git -C "$TMP" checkout -q -b ci-logs
    fi
    {
        echo "=== $(date -u +%H:%M:%S) UTC  run=${GITHUB_RUN_ID} sha=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null) ==="
        df -h / | tail -1
        free -h | head -2
        echo "--- build log tail (last 60 lines) ---"
        tail -n 60 "$LOG" 2>/dev/null
    } > "$TMP/heartbeat.txt"
    git -C "$TMP" config user.name "fennec-ci"
    git -C "$TMP" config user.email "fennec-ci@users.noreply.github.com"
    git -C "$TMP" add heartbeat.txt
    git -C "$TMP" commit -qm "heartbeat $(date -u +%H:%M:%S) run=${GITHUB_RUN_ID}"
    # A concurrent run (or a late heartbeat) can make the push fail; that just
    # drops one heartbeat, it must never affect the build.
    git -C "$TMP" push -q origin ci-logs 2>/dev/null || true
    rm -rf "$TMP"
    sleep 240
done
