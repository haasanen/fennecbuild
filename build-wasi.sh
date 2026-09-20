#!/bin/bash
# Phase 2: WASI SDK (the ~68 min phase).
# Split out of build.sh for the same reason as build-llvm.sh: so the workflow
# can cache the completed WASI install before the (longer, more failure-prone)
# Gecko/Fenix phase starts.
set -e
source "$(dirname "$0")/paths.sh"

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
