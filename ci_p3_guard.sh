#!/bin/bash
# ci_p3_guard.sh — measure the Phase-3 build dirs (MozFennec/obj +
# MozAppServices/target) and signal whether they fit under the 9 GB
# per-cache budget that actions/cache enforces (10 GB hard cap).
# Exit 0 = save the build-dir checkpoint; exit 1 = skip it (deps still saved).
# Never fails the run: every error path falls through to "skip".
T=0
for d in "${SRCLIB_DIR:-../srclib}/MozFennec/obj" "${SRCLIB_DIR:-../srclib}/MozAppServices/target"; do
    if [ -d "$d" ]; then
        b=$(du -sb "$d" 2>/dev/null | awk '{print $1}')
        T=$((T + ${b:-0}))
    fi
done
tg=$(awk -v b="$T" 'BEGIN{printf "%.2f", b/1073741824}')
echo "build dirs (MozFennec obj + app-services target) = ${tg} GB"
df -h /
if awk -v g="$tg" 'BEGIN{exit !(g < 9.0)}'; then
    exit 0
fi
echo "build dirs >= 9.0 GB — skipping the build-dir checkpoint (deps cache still saved)"
exit 1
