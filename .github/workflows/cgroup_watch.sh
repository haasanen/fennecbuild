#!/bin/bash
# cgroup_watch.sh <interval_s>
#
# Prints the REAL memory ceiling of this job to the console every <interval>
# seconds. `free -h` shows the HOST's RAM, which is not the limit a hosted
# runner enforces on the job — the job runs in a cgroup whose memory.max
# can be far smaller. If a heavy crate (geckoservo) crosses that cgroup
# limit, the kernel/orchestrator kills the job, and the host-wide `free`
# will never show it. This is the measurement that distinguishes "build
# resource use is the trigger" from "external lifetime kill".
#
# Console-only: every sample goes to STDOUT. No files. cgroup v1 and v2
# are both probed so it works regardless of which the runner uses.
set -u
IV="${1:-60}"

cgroup_mem() {
    local out=""
    # v2
    if [ -r /sys/fs/cgroup/memory.max ]; then
        local max cur peak
        max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        cur=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
        peak=$(cat /sys/fs/cgroup/memory.peak 2>/dev/null || echo "?")
        [ "$max" = "max" ] && max="unlimited"
        out="cg2 max=${max} cur=${cur} peak=${peak}"
    fi
    # v1
    if [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        local lim used
        lim=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)
        # 9223372036854771712 ~= "unlimited" sentinel in v1
        [ "$lim" -ge 9223372036854771712 ] 2>/dev/null && lim="unlimited"
        out="${out} cg1 limit=${lim} usage=${used}"
    fi
    [ -z "$out" ] && out="cgroup memory not readable (v1/v2 both missing)"
    echo "$out"
}

human() { awk -v b="${1:-0}" 'BEGIN{ if(b>=1073741824) printf "%.2fGiB",b/1073741824; else if(b>=1048576) printf "%.1fMiB",b/1048576; else printf "%dB",b }'; }

echo "cgroup_watch: start $(date -u +%H:%M:%S) interval=${IV}s"
echo "cgroup_watch: $(cgroup_mem)  (cur = $(human $( (cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0) )))"

while :; do
    sleep "$IV" || exit 0
    cur=$( (cat /sys/fs/cgroup/memory.current 2>/dev/null || cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null || echo 0) )
    echo "cgroup_watch $(date -u +%H:%M:%S) UTC: mem_now=$(human "$cur") | $(cgroup_mem) | procs=$(ls -d /proc/[0-9]* | wc -l) | load=$(cut -d' ' -f1-3 /proc/loadavg)"
done
