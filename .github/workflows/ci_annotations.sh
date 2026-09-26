#!/bin/bash
# ci_annotations.sh — print the job's check-run annotations (GitHub's official
# failure record) to the console.
#
# Runner-level failures (e.g. "The hosted runner lost communication with the
# server. Anything in your workflow that terminates the runner process,
# starves it for CPU/Memory, or blocks its network access can cause this
# error.") are recorded by GitHub in the job's check-run annotations, NOT in
# the step log. A runner that loses communication can also lose the log blob
# entirely (API: BlobNotFound), so the annotations are the durable surface
# for the real error. Console only, no files.
set -u
RUN="${GITHUB_RUN_ID:-}"
REPO="${GITHUB_REPOSITORY:-}"
TOK="${GITHUB_TOKEN:-}"
if [ -z "$RUN" ] || [ -z "$REPO" ] || [ -z "$TOK" ]; then
    echo "ci_annotations: GITHUB_RUN_ID/GITHUB_REPOSITORY/GITHUB_TOKEN missing — skipping"
    exit 0
fi
JIDS=$(curl -s -H "Authorization: token ***" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/actions/runs/$RUN/jobs?per_page=100")
JID=$(printf '%s' "$JIDS" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    jobs = d.get('jobs', [])
except Exception:
    sys.exit(0)
for j in jobs:
    if j.get('conclusion') in ('failure', 'cancelled') or j.get('status') != 'completed':
        print(j['id']); break
if jobs:
    print(jobs[0]['id'])
")
[ -z "$JID" ] && { echo "ci_annotations: could not resolve the job id"; exit 0; }
echo "ci_annotations: job=$JID run=$RUN — check-run annotations:"
curl -s -H "Authorization: token ***" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/check-runs/$JID/annotations" | python3 -c "
import json, sys
try:
    a = json.load(sys.stdin)
except Exception:
    print('  (annotations not parseable)')
    raise SystemExit(0)
if not isinstance(a, list):
    print('  (unexpected response)', str(a)[:200]); raise SystemExit(0)
for x in a:
    print('  [' + str(x.get('annotation_level')) + '] ' + str(x.get('message','')))
"
