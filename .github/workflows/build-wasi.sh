#!/bin/bash
# Phase 2: WASI SDK (the ~68 min phase).
# Split out of build.sh for the same reason as build-llvm.sh: so the workflow
# can cache the completed WASI install before the (longer, more failure-prone)
# Gecko/Fenix phase starts.
set -e
source "$(dirname "$0")/../../paths.sh"

# Ubuntu 26.04 runner image (2026-11 refresh) ships GCC 15, whose libstdc++
# stopped transitively including <cstdint>. wasi-sdk-20's LLVM predates the
# upstream include fix and dies with uint64_t-not-declared cascades in
# SmallVector.h (runs 42427084156/42429915223 after the WASI cache expired).
# Force-include the header for the host-tool compile; a no-op on older GCC.
export CXXFLAGS="${CXXFLAGS:+${CXXFLAGS} }-include cstdint"

# The same 2026-11 image refresh ships CMake 4.4, which removed compatibility
# with cmake_minimum_required(VERSION <3.5). wasi-sdk-20's toolchain file
# (wasi-sdk.cmake:4: cmake_minimum_required(VERSION 3.4.0)) is therefore a hard
# error for every sub-build that passes -DCMAKE_TOOLCHAIN_FILE=wasi-sdk.cmake:
# run 42433860701 died configuring compiler-rt, and both libcxx configures use
# the same toolchain file. CMAKE_POLICY_VERSION_MINIMUM (documented on
# cmake.org) raises the policy floor for all new build trees via the
# environment — one lever covers every remaining configure. CMake <3.31 does
# not know the variable and silently ignores it, so this is a no-op if the
# image falls back to CMake 3.x.
export CMAKE_POLICY_VERSION_MINIMUM=3.5

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
echo "build-wasi.sh: phase complete"
