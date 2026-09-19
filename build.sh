#!/bin/bash
#
#    Fennec build scripts
#    Copyright (C) 2020-2024  Matías Zúñiga, Andrew Nayenko, Tavi
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU Affero General Public License as
#    published by the Free Software Foundation, either version 3 of the
#    License, or (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU Affero General Public License for more details.
#
#    You should have received a copy of the GNU Affero General Public License
#    along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

set -e

# shellcheck source=paths.sh
source "$(dirname "$0")/paths.sh"

# We publish the artifacts into a local Maven repository instead of using the
# auto-publication workflow because the latter does not work for Gradle
# plugins (Glean).

# Set up Android SDK for GeckoView
sdkmanager 'build-tools;37.0.0'
sdkmanager 'platform-tools'

# Install some Android SDK components manually, see
# https://gitlab.com/fdroid/sdkmanager/-/work_items/31
if [ ! -e /opt/android-sdk/cmdline-tools/21.0 ]; then
    curl --silent -O https://dl.google.com/android/repository/commandlinetools-linux-15641748_latest.zip
    echo 'a66d5ef0238fc0162e9c1446602ce0dd41702d4dd7a94d2ce42d12b7f80baf7e  commandlinetools-linux-15641748_latest.zip' | shasum -c
    unzip -q commandlinetools-linux-15641748_latest.zip
    mkdir -p /opt/android-sdk/cmdline-tools/
    mv cmdline-tools /opt/android-sdk/cmdline-tools/21.0
fi
if [ ! -e /opt/android-sdk/platforms/android-37.1 ]; then
    curl --silent -O https://dl.google.com/android/repository/platform-37.1_r01.zip
    echo 'cadf0a541847820ea3d8ffc5c192562a18376cf9ba510bf9659c772f9a442184  platform-37.1_r01.zip' | shasum -c
    unzip -q platform-37.1_r01.zip
    mkdir -p /opt/android-sdk/platforms/
    mv android-37.1 /opt/android-sdk/platforms/android-37.1
fi

# Set up Rust
cargo install --force --vers 0.29.4 cbindgen

# Build LLVM (skip when a completed install exists, e.g. restored from the
# CI cache — the install takes ~100 min to build)
pushd "$llvm"
if [ -d "$llvm/out/lib" ] && [ -e "$llvm/out/CI_DONE" ]; then
    echo "LLVM install present (restored from cache) — skipping build"
else
    llvmtarget=$(cat "$llvm/targets_to_build")
    cmake -S llvm -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=out -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ -DLLVM_ENABLE_PROJECTS="clang" -DLLVM_TARGETS_TO_BUILD="$llvmtarget" \
        -DLLVM_USE_LINKER=lld -DLLVM_BINUTILS_INCDIR=/usr/include -DLLVM_ENABLE_PLUGINS=FORCE_ON \
        -DLLVM_DEFAULT_TARGET_TRIPLE="x86_64-unknown-linux-gnu"
    cmake --build build -j"$(nproc)"
    cmake --build build --target install -j"$(nproc)"
    touch "$llvm/out/CI_DONE"
fi
popd

# Build WASI SDK (skip when the sysroot install exists, e.g. restored from cache)
pushd "$wasi"
if [ -d "$wasi/build/install/wasi/share/wasi-sysroot" ] && [ -e "$wasi/build/install/wasi/CI_DONE" ]; then
    echo "WASI install present (restored from cache) — skipping build"
else
    mkdir -p build/install/wasi
    touch build/compiler-rt.BUILT # fool the build system
    make \
        PREFIX=/wasi \
        build/wasi-libc.BUILT \
        build/libcxx.BUILT \
        -j"$(nproc)"
    touch build/install/wasi/CI_DONE
fi
popd

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
# Build such a copy of concept-fetch from the current A-C source code
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
