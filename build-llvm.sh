#!/bin/bash
# Phase 1: Android SDK bits + LLVM (the ~100 min phase).
# Split out of build.sh so a mid-WASI runner death still lets the workflow
# cache the completed LLVM out/ (build.sh alone would never save it).
set -e
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
echo "build-llvm.sh: phase complete"
