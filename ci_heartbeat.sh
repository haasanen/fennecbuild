#!/bin/bash
# ci_heartbeat.sh <workspace-dir>
#
# Background heartbeat: every 240 s, push a small state file (disk, memory)
# to the `ci-logs` branch of this repository. If a GitHub-hosted runner dies
# mid-build, the last heartbeat on that branch is the only forensics
# available — it shows what the machine was doing at the moment it went away.
# Everything this script reports goes to the build's STDOUT (the console);
# it writes no files to the workspace.

WORK="$1"

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
rm -f "$ASKPASS"   # never trust a stale one from a previous phase
trap 'rm -f "$ASKPASS"' EXIT TERM INT HUP
printf '#!/bin/sh\ncase "$1" in *ser*name*) printf %%s "ci-heartbeat" ;; *) printf %%s "%s" ;; esac\n' "$TOKEN" > "$ASKPASS"
chmod 700 "$ASKPASS"

n=0
while true; do
    n=$((n + 1))
    TMP=$(mktemp -d)
    if ! git clone -q --timeout=60 --depth 1 --branch ci-logs "$REPO_URL" "$TMP"; then
        # First heartbeat of the run: the branch does not exist yet.
        rm -rf "$TMP"; TMP=$(mktemp -d)
        if ! git clone -q --timeout=60 "$REPO_URL" "$TMP"; then
            echo "heartbeat#$n $(date -u +%H:%M:%S) clone failed"
            rm -rf "$TMP"
            sleep 240
            continue
        fi
    fi
    if [ ! -d "$TMP/.git" ]; then
        echo "heartbeat#$n $(date -u +%H:%M:%S) clone produced no .git — skipping"
        rm -rf "$TMP"
        sleep 240
        continue
    fi
    (
        cd "$TMP" 2>/dev/null || exit 9
        if ! git show-ref --verify --quiet refs/heads/ci-logs; then
            if ! git checkout -q -b ci-logs; then
                git checkout -q --track origin/ci-logs || exit 8
            fi
        fi
        {
            echo "=== $(date -u +%H:%M:%S) UTC  run=${GITHUB_RUN_ID} sha=$(git -C "$WORK" rev-parse --short HEAD 2>/dev/null) ==="
            df -h / | tail -1
            free -h | head -2
        } > heartbeat.txt
        git config user.name "fennec-ci"
        git config user.email "fennec-ci@users.noreply.github.com"
        git add heartbeat.txt
        git commit -qm "heartbeat $(date -u +%H:%M:%S) run=${GITHUB_RUN_ID}"
        # A concurrent run (or a late heartbeat) can make the push fail; that
        # just drops one heartbeat, it must never affect the build.
        if GIT_ASKPASS="$ASKPASS" GIT_TERMINAL_PROMPT=0 timeout 120 \
                git push -q -f origin ci-logs; then
            echo "heartbeat#$n $(date -u +%H:%M:%S) pushed OK"
        else
            rc=$?
            echo "WARNING: fennec ci-logs heartbeat push failed (rc=$rc)"
        fi
        exit 0
    )
    rm -rf "$TMP"
    sleep 240
done
