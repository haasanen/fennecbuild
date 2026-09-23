#!/usr/bin/env bash
# midstage_cache_saver.sh — checkpoint a live build tree into the GitHub
# Actions cache service from INSIDE a running step. actions/cache can only
# run at step boundaries, so a runner reclaimed mid-step (SIGTERM, exit 143)
# otherwise loses every byte of in-progress build state.
#
# Protocol (identical to actions/toolkit packages/cache, legacy cache v1 —
# see src/internal/cacheHttpClient.ts + cache.ts saveCacheV1 in
# https://github.com/actions/toolkit):
#   POST  ${ACTIONS_CACHE_URL}_apis/artifactcache/caches
#         {"key":K,"version":V,"cacheSize":N}                 -> {"cacheId":I}
#   PATCH ${ACTIONS_CACHE_URL}_apis/artifactcache/caches/I
#         Content-Range: bytes <start>-<end>/*                (32 MiB chunks)
#   POST  ${ACTIONS_CACHE_URL}_apis/artifactcache/caches/I
#         {"size":N}                                          (commit)
# Auth: "Authorization: Bearer $ACTIONS_RUNTIME_TOKEN" (job-scoped JWT the
# runner injects into every step's env; this script never prints it).
#
# Wire-format parity with actions/cache/save (so ANY actions/cache/restore
# step restores these archives unchanged):
#   * archive = tar --posix -cf ... -P -C "$GITHUB_WORKSPACE" --files-from
#     <manifest> streamed through the detected compression program
#     (internal/tar.ts create args),
#   * cache version = sha256("<path1>|<path2>|<method>|1.0") — cacheUtils.ts
#     getCacheVersion(paths, method, false) on linux; PATHS must be passed to
#     this script EXACTLY as the paired restore step lists them (same order,
#     same absolute strings, no trailing slashes),
#   * method detection mirrors cacheUtils.ts getCompressionMethod(): zstd
#     present -> 'zstd-without-long', else 'gzip'.
#
# Usage:
#   midstage_cache_saver.sh <cache-key> <abs-path> [<abs-path> ...]
# Env (runner-provided): ACTIONS_CACHE_URL (or ACTIONS_RESULTS_URL),
#   ACTIONS_RUNTIME_TOKEN, GITHUB_WORKSPACE
# Env (knobs):
#   MIDSTAGE_MAX_GB     refuse above this archive size (default 9.5; the
#                       actions/cache 10 GB per-entry cap is a hard error)
#   MIDSTAGE_MIN_FREE_GB refuse if RUNNER_TEMP free < this (default 2)
#   MIDSTAGE_CHUNK_MB   upload chunk MiB (default 32 = toolkit default)
#   MIDSTAGE_ZSTD_LEVEL zstd -N (default 1: cheap while a build co-runs)
#   MIDSTAGE_LOG        heartbeat log (default $GITHUB_WORKSPACE/midstage_saver.log)
#   DRY_RUN=1           build the archive, log the exact API calls, POST nothing
# Exit codes: 0 saved | 10 benign skip (env absent / too big / key exists)
#             20 real failure. NEVER a mystery: every path logs to the log.
#
# Copyright (C) 2026 fennecbuild contributors — same AGPLv3 terms as the
# other CI scripts in this repo.
set -u -o pipefail

WS="${GITHUB_WORKSPACE:?GITHUB_WORKSPACE is required}"
LOG="${MIDSTAGE_LOG:-$WS/midstage_saver.log}"
MAX_GB="${MIDSTAGE_MAX_GB:-9.5}"
MIN_FREE_GB="${MIDSTAGE_MIN_FREE_GB:-2}"
CHUNK_MB="${MIDSTAGE_CHUNK_MB:-32}"
ZSTD_LEVEL="${MIDSTAGE_ZSTD_LEVEL:-1}"
DRY_RUN="${DRY_RUN:-0}"

log() { # one line per event, heartbeat-visible (build_full.log tailers see it)
    local line
    line="midstage-saver $(date -u +%H:%M:%S) $*"
    echo "$line" | tee -a "$LOG"
}

if [ $# -lt 2 ]; then
    echo "usage: midstage_cache_saver.sh <cache-key> <abs-path> [...]" >&2
    exit 20
fi
KEY="$1"; shift
PATHS=("$@")

# ---- env / capability checks (never fail the build: benign skips) --------
BASE="${ACTIONS_CACHE_URL:-${ACTIONS_RESULTS_URL:-}}"
if [ -z "$BASE" ] || [ -z "${ACTIONS_RUNTIME_TOKEN:-}" ]; then
    log "SKIP: ACTIONS_CACHE_URL/ACTIONS_RESULTS_URL or ACTIONS_RUNTIME_TOKEN absent (not on a runner?)"
    exit 10
fi
BASE="${BASE%/}/"
if [ -n "${ACTIONS_CACHE_SERVICE_V2:-}" ]; then
    # v2 (twirp) uses ${ACTIONS_RESULTS_URL}twirp/InternalCacheService/v1/…
    # Not implemented here; re-check the toolkit before relying on it.
    log "WARN: ACTIONS_CACHE_SERVICE_V2 is set — this script speaks v1 only; verify v1 endpoint acceptance on a live runner"
fi
for p in "${PATHS[@]}"; do
    case "$p" in
        /*) ;;
        *) log "SKIP: paths must be absolute (got '$p') — version-hash parity with actions/cache/restore requires exact strings"; exit 10 ;;
    esac
done

# ---- compression method (mirror cacheUtils.getCompressionMethod) ---------
if command -v zstd >/dev/null 2>&1; then
    METHOD="zstd-without-long"; EXT="tzst"; TARBALL="cache.$EXT"
else
    METHOD="gzip"; EXT="tgz"; TARBALL="cache.$EXT"
fi

# ---- cache version hash (mirror cacheUtils.getCacheVersion, linux) -------
# components = paths..., compressionMethod, salt '1.0'   joined by '|'
ver_input="$(IFS='|'; echo -n "${PATHS[*]}")|${METHOD}|1.0"
VERSION="$(printf '%s' "$ver_input" | sha256sum | cut -d' ' -f1)"

# ---- archive into RUNNER_TEMP (one extra copy of the tree, compressed) ---
TMPD="${RUNNER_TEMP:-/tmp}"
FREE_GB="$(df -BG "$TMPD" | awk 'NR==2{gsub("G","",$4); print $4}')"
if awk -v f="$FREE_GB" -v m="$MIN_FREE_GB" 'BEGIN{exit !(f < m)}'; then
    log "SKIP: only ${FREE_GB}G free on $TMPD (< ${MIN_FREE_GB}G) — no room for a checkpoint archive"
    exit 10
fi
STAGEDIR="$TMPD/midstage-$$"
mkdir -p "$STAGEDIR"
ARCHIVE="$STAGEDIR/$TARBALL"
MANIFEST="$STAGEDIR/manifest.txt"
printf '%s\n' "${PATHS[@]}" > "$MANIFEST"

t0=$(date +%s)
# Same tar invocation shape as toolkit internal/tar.ts create (GNU tar on
# linux): --posix -cf <out> --exclude <out> -P -C $GITHUB_WORKSPACE
# --files-from manifest.txt. --warning=no-file-changed + exit-code tolerance:
# GNU tar exits 1 on 'file changed as we read it' / 'file removed' — with a
# LIVE build writing into the tree that is normal; the archive still contains
# every file (changed ones as-read-at-open). rc>=2 = real failure.
if [ "$METHOD" = "gzip" ]; then
    COMPRESSOR="gzip -1 > \"$ARCHIVE\""
else
    COMPRESSOR="zstd -$ZSTD_LEVEL -T2 -q -o \"$ARCHIVE\""
fi
set +e
nice -n 19 ionice -c3 tar --posix -cf - \
    --warning=no-file-changed --warning=no-file-removed \
    -P -C "$WS" --files-from "$MANIFEST" \
  | nice -n 19 ionice -c3 sh -c "$COMPRESSOR"
pipe_rc=("${PIPESTATUS[@]}")
set -e
tar_rc="${pipe_rc[0]:-2}"; comp_rc="${pipe_rc[1]:-2}"
if [ "$tar_rc" -ge 2 ] || [ "$comp_rc" -ne 0 ]; then
    log "FAIL: tar rc=$tar_rc compressor rc=$comp_rc (>=2 means real error, not file-changed race)"
    rm -rf "$STAGEDIR"; exit 20
fi
SIZE_BYTES=$(stat -c %s "$ARCHIVE")
SIZE_GB=$(awk -v b="$SIZE_BYTES" 'BEGIN{printf "%.2f", b/1073741824}')
log "archive ${SIZE_GB} GB in $(( $(date +%s) - t0 ))s (tar rc=$tar_rc, method=$METHOD, key=$KEY)"
if awk -v g="$SIZE_GB" -v m="$MAX_GB" 'BEGIN{exit !(g >= m)}'; then
    log "SKIP: archive ${SIZE_GB} GB >= MIDSTAGE_MAX_GB ($MAX_GB)"
    rm -rf "$STAGEDIR"; exit 10
fi

if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN: POST ${BASE}_apis/artifactcache/caches  {\"key\":\"$KEY\",\"version\":\"$VERSION\",\"cacheSize\":$SIZE_BYTES}"
    log "DRY_RUN: PATCH ${BASE}_apis/artifactcache/caches/{cacheId} x$(( (SIZE_BYTES + CHUNK_MB*1048576 - 1) / (CHUNK_MB*1048576) )) chunks of ${CHUNK_MB}MiB (Content-Range bytes s-e/*)"
    log "DRY_RUN: POST ${BASE}_apis/artifactcache/caches/{cacheId} {\"size\":$SIZE_BYTES}"
    log "DRY_RUN: version-hash input was '${ver_input}'"
    rm -rf "$STAGEDIR"; exit 0
fi

# ---- HTTP (curl; responses to files — no curl|python pipes) --------------
H_AUTH="Authorization: Bearer $ACTIONS_RUNTIME_TOKEN"
H_ACC="Accept: application/json;api-version=6.0-preview.1"
RETRY() { # <desc> <cmd...> — 3 tries, short sleeps
    local desc="$1"; shift; local i
    for i in 1 2 3; do
        if "$@"; then return 0; fi
        log "WARN: $desc attempt $i failed"; sleep $(( i * 5 ))
    done
    return 1
}

RJSON="$STAGEDIR/reserve.json"
reserve_ok() {
    curl -sS -o "$RJSON" -w "%{http_code}" -X POST \
        -H "$H_AUTH" -H "$H_ACC" -H "Content-Type: application/json" \
        -d "{\"key\":\"$KEY\",\"version\":\"$VERSION\",\"cacheSize\":$SIZE_BYTES}" \
        "${BASE}_apis/artifactcache/caches" > "$STAGEDIR/reserve.code" 2>>"$LOG"
}
if ! RETRY "reserve cache" reserve_ok; then
    log "FAIL: reserve unreachable"; rm -rf "$STAGEDIR"; exit 20
fi
CODE=$(cat "$STAGEDIR/reserve.code")
CACHE_ID=$(grep -o '"cacheId"[": ]*[0-9]*' "$RJSON" | grep -o '[0-9]*' | head -1)
if [ -z "$CACHE_ID" ]; then
    # 400/409: key already exists or another save is mid-reserve for this key
    # (actions/toolkit#537). Keys here embed ts+pid so collisions ~never
    # happen; either way a failed reserve is a benign skip, never a build fail.
    log "SKIP: reserve HTTP $CODE body=$(head -c 300 "$RJSON" | tr -d '\n')"
    rm -rf "$STAGEDIR"; exit 10
fi

i=0; total=$((SIZE_BYTES))
chunk_up() {
    local start=$1 end=$2 idx=$3
    curl -sS -o "$STAGEDIR/up.$idx" -w "%{http_code}" -X PATCH \
        -H "$H_AUTH" -H "Content-Type: application/octet-stream" \
        -H "Content-Range: bytes ${start}-${end}/*" \
        --data-binary "@$STAGEDIR/chunk.$idx" \
        "${BASE}_apis/artifactcache/caches/$CACHE_ID" > "$STAGEDIR/up.$idx.code"
    [ "$(cat "$STAGEDIR/up.$idx.code")" = "200" ] || [ "$(cat "$STAGEDIR/up.$idx.code")" = "204" ]
}
off=0; idx=0
while [ "$off" -lt "$total" ]; do
    sz=$(( CHUNK_MB * 1048576 )); [ $((off + sz)) -gt "$total" ] && sz=$((total - off))
    dd if="$ARCHIVE" of="$STAGEDIR/chunk.$idx" bs=1M skip="$i" count="$(( (sz + 1048575) / 1048576 ))" status=none
    if ! RETRY "upload chunk $idx" chunk_up "$off" "$((off + sz - 1))" "$idx"; then
        log "FAIL: chunk $idx unreachable"; rm -rf "$STAGEDIR"; exit 20
    fi
    rm -f "$STAGEDIR/chunk.$idx"
    off=$((off + sz)); i=$((i + 1)); idx=$((idx + 1))
done

CJSON="$STAGEDIR/commit.json"
commit_ok() {
    curl -sS -o "$CJSON" -w "%{http_code}" -X POST \
        -H "$H_AUTH" -H "$H_ACC" -H "Content-Type: application/json" \
        -d "{\"size\":$SIZE_BYTES}" \
        "${BASE}_apis/artifactcache/caches/$CACHE_ID" > "$STAGEDIR/commit.code"
    [ "$(cat "$STAGEDIR/commit.code")" = "200" ] || [ "$(cat "$STAGEDIR/commit.code")" = "204" ]
}
if ! RETRY "commit cache" commit_ok; then
    log "FAIL: commit HTTP $(cat "$STAGEDIR/commit.code" 2>/dev/null) body=$(head -c 200 "$CJSON" 2>/dev/null)"
    rm -rf "$STAGEDIR"; exit 20
fi
log "SAVED key=$KEY id=$CACHE_ID ${SIZE_GB} GB chunks=$idx total=$(( $(date +%s) - t0 ))s"
rm -rf "$STAGEDIR"
exit 0
