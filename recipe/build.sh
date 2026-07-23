#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Local debug builds (compiler cache persists across runs):
# $ export SCCACHE_DIR=/home/you/.cache/sccache
# $ sccache --show-stats   # "Cache location" must read: Local disk: $SCCACHE_DIR
# $ rattler-build build --no-build-id --env-isolation none --recipe recipe/recipe.yaml -m .ci_support/linux_64_python3.14.____cp314.yaml
#
# --env-isolation none forwards HOME + SCCACHE_DIR into the build; the default (strict)
# normalizes HOME and strips host env, so sccache would instead write to a throwaway
# build-local dir that is wiped after the build.
# --no-build-id keeps the build path stable so the cache actually hits on the next run.
set -euo pipefail

cd "${SRC_DIR}/src"

PARALLEL="${PARALLEL:-${CPU_COUNT:-$(nproc)}}"
export PARALLEL
export PYTHON="${PREFIX}/bin/python"


export BUILD_ROOT="${SRC_DIR}/_llvm_build"
export LLVM_MODERN_INSTALL="${SRC_DIR}/llvm-modern-install"
export LLVM_MODERN_SRC="${SRC_DIR}/llvm-modern-src"

# sccache speeds up local rebuilds; skip it in CI (cold cache). conda-forge sets
# CI=azure|github_actions.
if [ -z "${CI:-}" ]; then
  command -v sccache &>/dev/null || { echo "ERROR: sccache not found"; exit 1; }
  export CMAKE_C_COMPILER_LAUNCHER=sccache
  export CMAKE_CXX_COMPILER_LAUNCHER=sccache
fi

echo "=============================================================="
echo "Step 1/2: Modern LLVM/MLIR + Python bindings"
echo "=============================================================="

cmake_args=(
    -G Ninja
    -S "${LLVM_MODERN_SRC}/llvm"
    -B "${BUILD_ROOT}"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="${LLVM_MODERN_INSTALL}"
    -DLLVM_ENABLE_PROJECTS=mlir
    -DLLVM_TARGETS_TO_BUILD=NVPTX
    -DLLVM_BUILD_TOOLS=OFF
    -DLLVM_BUILD_EXAMPLES=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
    -DMLIR_ENABLE_BINDINGS_PYTHON=ON
    -DCMAKE_CXX_FLAGS="-DMLIR_PYTHON_PACKAGE_PREFIX=numba_cuda_mlir._mlir."
    -DMLIR_BINDINGS_PYTHON_INSTALL_PREFIX="python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir"
    -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=numba_cuda_mlir
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON
    # MLIR (MLIRDetectPythonEnv.cmake) and the numba wheel each run find_package(Python3)
    # *and* an unversioned find_package(Python) (nanobind looks for Python_, not Python3_).
    # A free-threaded conda env ships only python3.14t (no python3.14), so an unpinned
    # search skips it and grabs a stray interpreter on PATH (e.g. /opt/conda/bin/python3.12).
    # Pin both so every find_package agrees on the conda interpreter.
    -DPython3_EXECUTABLE="${PYTHON}"
    -DPython_EXECUTABLE="${PYTHON}"
)

# The wheel's find_package(Python) can't take -D (setup.py hardcodes its cmake args) and
# CMake won't read this from the environment on its own, so pin-python-executable.patch
# forwards $ENV{Python_EXECUTABLE} / $ENV{Python_FIND_ABI}.
export Python_EXECUTABLE="${PYTHON}"

# CMake's FindPython gates each artifact on an ABI-accept list whose default excludes the
# free-threaded "t" ABI. On a free-threaded build set FIND_ABI's free-threading field ON so
# "t" is the required ABI (forcing this on a regular build would reject its interpreter,
# hence the guard). Fields are [pydebug;pymalloc;unicode;freethreading] = OFF;OFF;OFF;ON.
if [[ "$("${PYTHON}" -c 'import sysconfig; print(sysconfig.get_config_var("ABIFLAGS") or "")')" == *t* ]]; then
    freethread_abi="OFF;OFF;OFF;ON"
    cmake_args+=(
        -DPython3_FIND_ABI="${freethread_abi}"
        -DPython_FIND_ABI="${freethread_abi}"
    )
    export Python_FIND_ABI="${freethread_abi}"
fi

cmake "${cmake_args[@]}"
cmake --build "${BUILD_ROOT}" -j "${PARALLEL}"
cmake --install "${BUILD_ROOT}"
[ -z "${CI:-}" ] && sccache --show-stats

echo "=============================================================="
echo "Step 2/2: numba_cuda_mlir wheel"
echo "=============================================================="

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
