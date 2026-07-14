#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Local debug builds (compiler cache persists across runs):
#   export SCCACHE_DIR=/home/you/.cache/sccache
#   sccache --show-stats   # "Cache location" must read: Local disk: $SCCACHE_DIR
#   rattler-build build --no-build-id --env-isolation none \
#     --recipe recipe/recipe.yaml -m .ci_support/linux_64_python3.11.____cpython.yaml
#
# --env-isolation none forwards HOME + SCCACHE_DIR into the build; the default
# (strict) normalizes HOME and strips host env, so sccache would instead write to
# a throwaway build-local dir that is wiped after the build. --no-build-id keeps
# the build path stable so the cache actually hits on the next run.
set -euo pipefail

# One build script drives every output; dispatch on the package being built.
# rattler-build leaves PKG_NAME unset for the `staging:` output, so map an unset
# value to the staging name.
PKG_NAME="${PKG_NAME:-numba-cuda-mlir-staging}"

cd "${SRC_DIR}/src"

PARALLEL="${PARALLEL:-${CPU_COUNT:-$(nproc)}}"
export PARALLEL
export PYTHON="${PREFIX}/bin/python"

export BUILD_ROOT="${SRC_DIR}/_llvm_build"
export LLVM_MODERN_INSTALL="${SRC_DIR}/llvm-modern-install"
export LLVM_MODERN_SRC="${SRC_DIR}/llvm-modern-src"

case "${PKG_NAME}" in
  numba-cuda-mlir-staging)
    echo "=============================================================="
    echo "Staging: Modern LLVM/MLIR + Python bindings (built once, cached)"
    echo "=============================================================="
    chmod +x ci/*.sh
    # Keep upstream's sccache wiring in ci/build-llvm-modern.sh (it sets
    # CMAKE_C/CXX_COMPILER_LAUNCHER=$(which sccache) and guards on sccache being
    # present). sccache is a build dependency, so leaving it in place caches the
    # LLVM/MLIR object files and speeds up local debug rebuilds. This output's
    # work directory is cached by rattler-build and restored into the package
    # output, so the LLVM/MLIR build does not run again for the wheel.
    ci/build-llvm-modern.sh
    ;;

  numba-cuda-mlir)
    echo "=============================================================="
    echo "Package: numba_cuda_mlir wheel (reuses cached LLVM/MLIR)"
    echo "=============================================================="
    # rattler-build restored the staging work directory, so ${LLVM_MODERN_INSTALL}
    # already contains the compiled LLVM/MLIR install tree.

    # Cache the wheel's native (pybind11/nanobind) compile on local rebuilds.
    export CMAKE_C_COMPILER_LAUNCHER=sccache
    export CMAKE_CXX_COMPILER_LAUNCHER=sccache

    # CUDA headers come from the conda host env; FindCUDAToolkit.cmake honors
    # $CUDAToolkit_ROOT for cuda.h.
    export CUDAToolkit_ROOT="${PREFIX}"
    export DLPACK_PATH="${PREFIX}"
    export MLIR_DIR="${LLVM_MODERN_INSTALL}/lib/cmake/mlir"
    # LIBLLVM7 intentionally unset: we don't bundle libLLVM-7.so. The legacy LLVM 7
    # runtime is provided by the libllvm7.1 conda package (see symlink below).

    "${PYTHON}" -m pip install . \
        --no-build-isolation \
        --no-deps \
        -vv

    # numba-cuda-mlir's runtime loader looks for a bundled
    # numba_cuda_mlir/lib/libLLVM-7.so. Point that at the conda libllvm7.1 library
    SP="$("${PYTHON}" -c "import sysconfig; print(sysconfig.get_paths()['platlib'])")"
    mkdir -p "${SP}/numba_cuda_mlir/lib"
    # $SP/numba_cuda_mlir/lib -> up 4 -> $PREFIX/lib
    ln -sf ../../../../libLLVM-7.1.so "${SP}/numba_cuda_mlir/lib/libLLVM-7.so"
    ;;

  *)
    echo "Unknown PKG_NAME: ${PKG_NAME}" >&2
    exit 1
    ;;
esac
