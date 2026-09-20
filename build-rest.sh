#!/bin/bash
# Phase 3: microG libs + Glean + Gecko + Fenix (the long tail after the two
# toolchain phases). LLVM/WASI are already built (or restored from cache) by
# build-llvm.sh / build-wasi.sh.
set -e
source "$(dirname "$0")/paths.sh"

# Build microG libraries
pushd "$gmscore"
gradle -x javaDocReleaseGeneration \
    :play-services-ads-identifier:publishToMavenLocal \
    :play-services-base:publishToMavenLocal \
    :play-services-basement:publishToMavenLocal \
    :play-services-fido:publishToMavenLocal \
    :play-services-tasks:publishToMavenLocal
popd

pushd "$glean"
export TARGET_CFLAGS=-DNDEBUG
gradle publishToMavenLocal
popd

pushd "$glean_as"
gradle publishToMavenLocal
popd

pushd "$mozilla_release"
./mach build
./mach package
read -ra locales < "$patches/locales"
./mach package-multi-locale --locales "${locales[@]}"
MOZ_CHROME_MULTILOCALE=${locales[*]}
export MOZ_CHROME_MULTILOCALE
gradle -x javadocRelease :geckoview:publishReleasePublicationToMavenLocal
popd

pushd "$android_components"
# Viaduct from A-S requires concept-fetch 150.0.3 built with compileSdk 36.1.
# Build such a copy of the concept-fetch module from the current A-C source
echo 150.0.3 > ../version.txt
sed -i -e '/compileSdkMajorVersion/s/37/36/' .config.yml
gradle :components:concept-fetch:publishToMavenLocal
git checkout .config.yml ../version.txt
# Required by UnifiedPush
gradle :components:{concept-base,concept-fetch,support-base,ui-icons}:publishToMavenLocal
popd

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

pushd "$unifiedpush_ac"
gradle publishToMavenLocal
popd

pushd "$android_components"
gradle publishToMavenLocal
popd

pushd "$fenix"
gradle assembleRelease
popd
echo "build-rest.sh: phase complete"
