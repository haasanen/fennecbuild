#!/bin/sh
# Copyright (c) 2026 haasanen
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Version-aware gradle shim, mirroring how F-Droid's build service runs
# gradle for fennecbuild: it reads the CURRENT project's own
# gradle/wrapper/gradle-wrapper.properties and uses that project's pinned
# Gradle version, falling back to 9.7.0 for in-tree projects without a
# wrapper (geckoview/fenix inside mozilla-central).
#
# Pinned versions observed in the repos this build uses:
#   gmscore (v0.3.16.252432)      -> 8.13
#   glean (v68.x)                 -> 8.14.3
#   application-services (v155.0) -> 8.14.3
#   in-tree geckoview/fenix       -> 9.7.0 (default)
#
# A single global 9.7.0 does NOT work: gmscore's Android Gradle Plugin
# relies on org.gradle.api.problems.internal.InternalProblems, a Gradle
# internal API removed in Gradle 9.6.0.

VROOT=/opt/gradle-versions
PROP="$(pwd)/gradle/wrapper/gradle-wrapper.properties"
V=""
[ -f "$PROP" ] && V=$(sed -n 's/.*gradle-\([0-9][0-9.]*\)-[a-z]*\.zip/\1/p' "$PROP" | head -1)
V="${V:-9.7.0}"
G="$VROOT/gradle-$V/bin/gradle"
if [ ! -x "$G" ]; then
    echo "gradle wrapper: installing gradle-$V" >&2
    curl -fsSL "https://services.gradle.org/distributions/gradle-$V-bin.zip" -o "/tmp/g-$V.zip"
    curl -fsSL "https://services.gradle.org/distributions/gradle-$V-bin.zip.sha256" -o "/tmp/g-$V.zip.sha256"
    echo "$(cat /tmp/g-$V.zip.sha256)  /tmp/g-$V.zip" | sha256sum -c -
    sudo mkdir -p "$VROOT"
    sudo unzip -q "/tmp/g-$V.zip" -d "$VROOT"
    rm -f "/tmp/g-$V.zip" "/tmp/g-$V.zip.sha256"
fi
exec "$G" "$@"
