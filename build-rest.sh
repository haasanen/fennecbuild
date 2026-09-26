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
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Phase 3: microG libs + Glean + Gecko + Fenix (the long tail after the two
# toolchain phases). LLVM/WASI are already built (or restored from cache) by
# build-llvm.sh / build-wasi.sh.
#
# STAGES: whitespace-separated subset of
#   gmscore glean glean_as gecko gecko_build gecko_package gecko_gv
#   ac_fetch150 appservices upush ac fenix
# selects which blocks run (CI runs one slice per step so a shared-runner
# recycle can be survived: each completed slice checkpoints its caches, and
# the retry re-runs earlier slices as up-to-date no-ops). Unset STAGES runs
# everything — the local / F-Droid path is unchanged.
# 'gecko' still runs all three gecko sub-stages (so the local path and any
# STAGES='gecko' caller are unchanged); CI runs gecko_build once per mach-
# build tier (MACH_BUILD_TARGETS) as separate workflow steps and checkpoints
# between them — a runner reclaimed mid-gecko then resumes at the next step
# (or, after a tier completes, from the cached finished state). Sub-stages
# assume their predecessors completed —
# their state arrives via the checkpoint caches restored at job start:
# gecko_package needs mach build's obj/, gecko_gv needs the packaged gecko.
set -e
source "$(dirname "$0")/paths.sh"

STAGES="${STAGES:-all}"
run_stage() {
    # "all" (or unset) runs everything — the local / F-Droid path.
    [ "$STAGES" = "all" ] && return 0
    case " $STAGES " in
        *" $1 "*) return 0 ;;
        *) echo "build-rest.sh: skipping stage '$1' (STAGES='$STAGES')"; return 1 ;;
    esac
}

# A published-to-mavenLocal artefact is the durable record that a publish
# stage COMPLETED (the .pom is written last by maven-publish, so an
# interrupted publish leaves it missing and the check fails open -> rebuild).
# If the artefacts are already in ~/.m2 (restored from the deps cache), the
# stage's finished output exists and the build is skipped — we never rebuild
# the same thing when nothing changed.
M2="$HOME/.m2/repository"

gmscore_published() {
    local V=0.3.16.252432 m
    for m in play-services-ads-identifier play-services-base play-services-basement play-services-fido play-services-tasks; do
        [ -f "$M2/org/microg/gms/$m/$V/$m-$V.aar" ] || return 1
    done
    return 0
}

glean_published() {  # $1 = version dir (68.0.1 for glean, 68.0.0 for glean_as)
    local V="$1"
    [ -f "$M2/org/mozilla/telemetry/glean/$V/glean-$V.aar" ] || return 1
    [ -f "$M2/org/mozilla/telemetry/glean-native/$V/glean-native-$V.aar" ] || return 1
    [ -f "$M2/org/mozilla/telemetry/glean-native-forUnitTests/$V/glean-native-forUnitTests-$V.jar" ] || return 1
    [ -f "$M2/org/mozilla/telemetry/glean-gradle-plugin/$V/glean-gradle-plugin-$V.jar" ] || return 1
    [ -f "$M2/org/mozilla/telemetry/glean/$V/glean-$V.pom" ] || return 1
    [ -f "$M2/org/mozilla/telemetry/glean-gradle-plugin/$V/glean-gradle-plugin-$V.pom" ] || return 1
    return 0
}

# Build microG libraries
if run_stage gmscore; then
if gmscore_published; then
    echo "gmscore: all 5 AARs already in ~/.m2 (0.3.16.252432) — skipping build"
else
pushd "$gmscore"
gradle -x javaDocReleaseGeneration \
    :play-services-ads-identifier:publishToMavenLocal \
    :play-services-base:publishToMavenLocal \
    :play-services-basement:publishToMavenLocal \
    :play-services-fido:publishToMavenLocal \
    :play-services-tasks:publishToMavenLocal
popd
fi
fi

if run_stage glean; then
if glean_published 68.0.1; then
    echo "glean: all artefacts already in ~/.m2 (68.0.1) — skipping build"
else
pushd "$glean"
export TARGET_CFLAGS=-DNDEBUG
gradle publishToMavenLocal
popd
fi
fi

if run_stage glean_as; then
if glean_published 68.0.0; then
    echo "glean_as: all artefacts already in ~/.m2 (68.0.0) — skipping build"
else
pushd "$glean_as"
# (inherits TARGET_CFLAGS from the glean stage; re-set so this stage is also
# runnable on its own)
export TARGET_CFLAGS=-DNDEBUG
gradle publishToMavenLocal
popd
fi
fi

if run_stage gecko || run_stage gecko_build; then
pushd "$mozilla_release"
# MACH_BUILD_TARGETS: run ONE logical mach-build tier (pre-export, export,
# pre-compile, binaries, faster) instead of the full build — the workflow
# runs the tiers as separate steps, each to completion. Unset = full build
# (local / F-Droid path unchanged).
./mach build ${MACH_BUILD_TARGETS:-}
popd
fi

if run_stage gecko || run_stage gecko_package; then
pushd "$mozilla_release"
./mach package
read -ra locales < "$patches/locales"
./mach package-multi-locale --locales "${locales[@]}"
popd
fi

if run_stage gecko || run_stage gecko_gv; then
pushd "$mozilla_release"
# locales list re-read so this sub-stage is runnable on its own (same file
# the gecko_package sub-stage consumed).
read -ra locales < "$patches/locales"
MOZ_CHROME_MULTILOCALE=${locales[*]}
export MOZ_CHROME_MULTILOCALE
gradle -x javadocRelease :geckoview:publishReleasePublicationToMavenLocal
popd
fi

if run_stage ac_fetch150; then
pushd "$android_components"
# Viaduct from A-S requires concept-fetch 150.0.3 built with compileSdk 36.1.
# Build such a copy of the concept-fetch module from the current A-C source
echo 150.0.3 > ../version.txt
sed -i -e '/compileSdkMajorVersion/s/37/36/' .config.yml
gradle :components:concept-fetch:publishToMavenLocal
git checkout .config.yml ../version.txt
# Required by UnifiedPush (keep exactly where upstream had it: before
# application-services and UnifiedPushAC are built)
gradle :components:{concept-base,concept-fetch,support-base,ui-icons}:publishToMavenLocal
popd
fi

if run_stage appservices; then
pushd "$application_services"
export NSS_DIR="$application_services/libs/desktop/linux-x86-64/nss"
export NSS_STATIC=1
./libs/verify-android-environment.sh
gradle publishToMavenLocal
# Build and install nimbus-fml manually
pushd components/support/nimbus-fml
cargo build --release
popd
mv target/release/nimbus-fml "$mozilla_release/obj/dist/host/bin/nimbus-fml"
popd
fi

if run_stage upush; then
pushd "$unifiedpush_ac"
gradle publishToMavenLocal
popd
fi

if run_stage ac; then
pushd "$android_components"
gradle publishToMavenLocal
popd
fi

if run_stage fenix; then
pushd "$fenix"
gradle assembleRelease
popd
fi
echo "build-rest.sh: phase complete (STAGES='${STAGES:-all}')"
