#!/usr/bin/env bash
# Stage the microG play-services-tasks (+ play-services-basement, its sole
# POM dependency) artefacts into ~/.m2 as mavenLocal coordinates.
#
# Why: the adopted upstream liberate chain (m-c-liberate@160 / a-c-liberate@160)
# compiles the android-components lib/integrity-googleplay module against
# org.microg.gms:play-services-tasks (the Play Tasks API, no GMS runtime),
# and fenix keeps `implementation libs.play.services.tasks` for the same
# classes. Upstream F-Droid gets these from the gmscore srclib (0.3.17);
# 0.3.17.x is not published on Maven Central, so we pin the newest published
# release (0.3.14.250932 — API-identical for Task/Tasks/TaskCompletionSource/
# CancellationTokenSource) via the microg version line in gradle/libs.versions
# .toml (gms-free.patch).
#
# Network: plain curl of repo1.maven.org; checksums pinned below.
set -euo pipefail

V=0.3.14.250932
M2="${HOME}/.m2/repository"
BASE="https://repo1.maven.org/maven2/org/microg/gms"

declare -A SHA=(
  [play-services-tasks.pom]=783c02f7e532d8e36501560f02335f9cdf5918b47b869ba13a67026573511548
  [play-services-tasks.aar]=90a5c1630c26381ca00fceb093956b360c2e84c9c7120f3a567da0cdbfdba9a7
  [play-services-basement.pom]=a13c8fc1f30bf30909d770ac14c5438ca63481b000ce8dbe4f0e0b91025682f7
  [play-services-basement.aar]=d669e374b428c4a43d65a0ab8776324538eaa0aa71fec95c4f0afb2a5885ee3d
)

for a in play-services-tasks play-services-basement; do
  dir="$M2/org/microg/gms/$a/$V"
  mkdir -p "$dir"
  for e in pom aar; do
    f="$a-$V.$e"
    if [ -f "$dir/$f" ]; then
      echo "microg: $f already staged"
      continue
    fi
    tmp="$(mktemp)"
    curl -sSfL --retry 3 --max-time 300 "$BASE/$a/$V/$f" -o "$tmp"
    echo "${SHA[$a.$e]}  $tmp" | sha256sum -c - || { echo "microg: CHECKSUM MISMATCH for $f"; exit 1; }
    mv "$tmp" "$dir/$f"
    echo "microg: staged $a/$V/$f"
  done
done
echo "microg: play-services-tasks/basement $V in mavenLocal — OK"
