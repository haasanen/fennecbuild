#!/bin/bash
# resource_watch.sh <interval_s>
#
# Samples the job's real resource use to the console every <interval> s:
# top-5 processes by RSS (name + MiB), total RSS of all rustc/cargo/gcc/lld
# processes, host memory/swap, and an attempt to read the job's cgroup
# memory ceiling (v2 then v1; on Hosted Compute Agent runners the cgroup
# filesystem is not exposed, in which case the per-process RSS is the record).
# Console only, no files. The question it answers: at the moment a build
# step dies, what process is using the most memory, and is total memory
# near the machine's 15 GiB?
set -u
IV="${1:-30}"

cgroup_line() {
    local out=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        local max cur peak
        max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
        peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo "?")
        [ "$max" = "max" ] && max="unlimited"
        out="cg2 max=${max} cur=${cur} peak=${peak}"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local lim used
        lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)
        [ "${lim:-0}" -ge 9223372036854771712 ] 2>/dev/null && lim="unlimited"
        out="cg1 limit=${lim} usage=${used}"
    else
        # find where the cgroup fs actually is (layout varies)
        local cg
        cg=$(cat /proc/self/cgroup 2>/dev/null | head -1)
        out="cgroup fs not readable at v1/v2 paths (self: ${cg:-unreadable})"
    fi
    echo "$out"
}

miB() { awk '{s+=$1} END {printf "%d", s/1024}'; }

sample() {
    # top 5 processes by RSS, named (comm), in MiB
    top=$(ps -eo rss=,comm= 2>/dev/null | sort -rn | head -5 | awk '{printf "%s(%dMiB) ", $2, $1/1024}')
    # total RSS of the heavy build processes
    heavy=$(ps -eo rss=,comm= 2>/dev/null | awk '$2 ~ /rustc|cargo|rustc_wrapper|clang|lld|cc1plus/ {s+=$1} END {printf "%dMiB", s/1024}')
    mem=$(free -h 2>/dev/null | awk '/Mem:/{print $3" used, "$7" free"}')
    swap=$(free -h 2>/dev/null | awk '/Swap:/{print $3" used"}')
    echo "res_watch $(date -u +%H:%M:%S) UTC: mem=${mem} | swap=${swap} | heavy_build=${heavy} | top5: ${top:-n/a}"
}

echo "res_watch: start $(date -u +%H:%M:%S) interval=${IV}s"
echo "res_watch: cgroup: $(cgroup_line)"
echo "res_watch: /sys/fs/cgroup exists: $([ -d /sys/fs/cgroup ] && echo yes || echo NO) | /proc/self/cgroup: $(cat /proc/self/cgroup 2>/dev/null | head -1)"
sample

while :; do
    sleep "$IV" || exit 0
    sample
done
