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

# Parallelism uses CPU_COUNT, which rattler-build always sets (conda-build API) to
# the detected core count. To cap it and avoid OOM on RAM-constrained machines,
# export your own value with --env-isolation none, which forwards it and takes
# precedence:  CPU_COUNT=4 rattler-build ... --env-isolation none
# (Under the default strict isolation the forwarded value is stripped.)

if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ]; then
    export PYTHON="${BUILD_PREFIX}/bin/python"
else
    export PYTHON="${PREFIX}/bin/python"
fi

export BUILD_ROOT="${SRC_DIR}/_llvm_build"
export LLVM_MODERN_INSTALL="${SRC_DIR}/llvm-modern-install"
export LLVM_MODERN_SRC="${SRC_DIR}/llvm-modern-src"

command -v sccache &>/dev/null || { echo "ERROR: sccache not found"; exit 1; }
export CMAKE_C_COMPILER_LAUNCHER=sccache
export CMAKE_CXX_COMPILER_LAUNCHER=sccache

# cmake flags shared by every LLVM/MLIR configure (native, cross Stage 1, Stage 2).
LLVM_CMAKE_COMMON=(
    -G Ninja
    -S "${LLVM_MODERN_SRC}/llvm"
    -DCMAKE_BUILD_TYPE=Release
    -DLLVM_ENABLE_PROJECTS=mlir
    -DLLVM_TARGETS_TO_BUILD=NVPTX
    -DLLVM_BUILD_TOOLS=OFF
    -DLLVM_BUILD_EXAMPLES=OFF
    -DLLVM_INCLUDE_TESTS=OFF
    -DLLVM_INCLUDE_BENCHMARKS=OFF
    -DLLVM_INCLUDE_DOCS=OFF
)

# MLIR Python-binding flags (native build + cross Stage 2 only; the Stage 1
# tblgen-only build turns bindings OFF).
#   MLIR_PYTHON_PACKAGE_PREFIX bakes "numba_cuda_mlir._mlir." into the compiled
#     .so files, so bindings import as numba_cuda_mlir._mlir.ir (not mlir.ir).
#   MLIR_BINDINGS_PYTHON_NB_DOMAIN isolates nanobind typeids from other MLIR-based
#     projects sharing the process.
MLIR_BINDINGS_FLAGS=(
    -DMLIR_ENABLE_BINDINGS_PYTHON=ON
    -DCMAKE_CXX_FLAGS="-DMLIR_PYTHON_PACKAGE_PREFIX=numba_cuda_mlir._mlir."
    -DMLIR_BINDINGS_PYTHON_INSTALL_PREFIX="python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir"
    -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=numba_cuda_mlir
    -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON
    -DPython3_EXECUTABLE="${PYTHON}"
    -DPython_EXECUTABLE="${PYTHON}"
)

echo "=============================================================="
echo "Step 1/2: Modern LLVM/MLIR + Python bindings"
echo "=============================================================="
if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ]; then
    # Cross-compilation requires a two-stage LLVM build: build llvm-tblgen / mlir-tblgen for
    # the BUILD platform (they generate source), then use these tools to compile for the
    # HOST platform.
    NATIVE_BUILD="${BUILD_ROOT}-native"
    mkdir -p "${NATIVE_BUILD}" "${LLVM_MODERN_INSTALL}"

    echo ">>> Stage 1: building native llvm-tblgen / mlir-tblgen"
    # Use a subshell so these env changes stay scoped to Stage 1. Build with conda's
    # build-platform compiler ($CC_FOR_BUILD/$CXX_FOR_BUILD). We drop the host binutils,
    # compiler flags, and path vars that point at $PREFIX, and disable zstd/zlib, so this
    # build-platform build can't pick up host tools or link against host .so files from
    # $PREFIX/lib; cmake derives ar/ranlib from the compiler.
    (
        export CC="${CC_FOR_BUILD}" CXX="${CXX_FOR_BUILD}"
        unset AR LD NM RANLIB STRIP OBJCOPY
        unset CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
        unset LIBRARY_PATH LD_LIBRARY_PATH PKG_CONFIG_PATH CMAKE_PREFIX_PATH CMAKE_ARGS

        cmake "${LLVM_CMAKE_COMMON[@]}" -B "${NATIVE_BUILD}" \
            -DCMAKE_C_COMPILER="${CC_FOR_BUILD}" \
            -DCMAKE_CXX_COMPILER="${CXX_FOR_BUILD}" \
            -DMLIR_ENABLE_BINDINGS_PYTHON=OFF \
            -DLLVM_ENABLE_ZSTD=OFF \
            -DLLVM_ENABLE_ZLIB=OFF

        cmake --build "${NATIVE_BUILD}" -j "${CPU_COUNT}" \
            --target llvm-tblgen mlir-tblgen llvm-min-tblgen
    )

    echo ">>> Stage 2: cross-compiling LLVM/MLIR + Python bindings"
    # ${CMAKE_ARGS} (exported by conda's host compiler activation) supplies the full cross
    # toolchain: CMAKE_SYSTEM_NAME/PROCESSOR, the cross ar/ranlib/ld/strip,
    # CMAKE_FIND_ROOT_PATH ($PREFIX + sysroot), and the find-root modes. We pass it first,
    # then override two things afterwards (cmake takes the last -D):
    #   - CMAKE_INSTALL_PREFIX (CMAKE_ARGS defaults it to $PREFIX) → our staging dir.
    #   - FIND_ROOT_PATH_MODE_INCLUDE back to BOTH (only this one). CMAKE_ARGS sets it to
    #     ONLY (search only $PREFIX + sysroot), but cross-python reports the host Python
    #     headers under $BUILD_PREFIX (its crossenv venv), which is not on the find-root
    #     path — so ONLY makes MLIR's find_package(Python Development.Module) fail with
    #     "missing Python_INCLUDE_DIRS". BOTH lets cmake accept that absolute header path.
    #     LIBRARY stays ONLY (Development.Module links no libpython on Linux, so keeping the
    #     stricter mode avoids pulling any build-host library into the cross link) and
    #     PROGRAM stays NEVER — the interpreter and tblgen tools are passed explicitly.
    #
    # LLVM's cmake spins up a NATIVE ExternalProject (at ${BUILD_ROOT}/NATIVE/) for
    # build-machine tools; it inherits $CC, so without an override it would use the host
    # (cross) compiler. CROSS_TOOLCHAIN_FLAGS_NATIVE is LLVM's escape hatch: a
    # semicolon-separated flag string appended to that NATIVE invocation. Point it at the
    # build-platform gcc and disable zstd/zlib there too. rm -rf so the NATIVE
    # ExternalProject reconfigures with the right flags; sccache preserves the object-file
    # work so this is cheap.
    rm -rf "${BUILD_ROOT}"
    mkdir -p "${BUILD_ROOT}"

    CROSS_NATIVE_FLAGS="\
-DCMAKE_C_COMPILER=${CC_FOR_BUILD};-DCMAKE_CXX_COMPILER=${CXX_FOR_BUILD};\
-DLLVM_ENABLE_ZSTD=OFF;-DLLVM_ENABLE_ZLIB=OFF;\
-DCMAKE_C_COMPILER_LAUNCHER=sccache;-DCMAKE_CXX_COMPILER_LAUNCHER=sccache"

    cmake ${CMAKE_ARGS:-} "${LLVM_CMAKE_COMMON[@]}" "${MLIR_BINDINGS_FLAGS[@]}" -B "${BUILD_ROOT}" \
        -DCMAKE_INSTALL_PREFIX="${LLVM_MODERN_INSTALL}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH \
        -DLLVM_TABLEGEN="${NATIVE_BUILD}/bin/llvm-tblgen" \
        -DMLIR_TABLEGEN="${NATIVE_BUILD}/bin/mlir-tblgen" \
        "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=${CROSS_NATIVE_FLAGS}"
else
    # ${CMAKE_ARGS} supplies conda's standard toolchain (ar/ranlib/ strip, find-root policy,
    # install libdir). Our CMAKE_INSTALL_PREFIX overrides conda's default of $PREFIX so the
    # LLVM tree lands in the staging install dir.
    cmake ${CMAKE_ARGS:-} "${LLVM_CMAKE_COMMON[@]}" "${MLIR_BINDINGS_FLAGS[@]}" -B "${BUILD_ROOT}" \
        -DCMAKE_INSTALL_PREFIX="${LLVM_MODERN_INSTALL}"
fi

# Build + install the configured tree (identical for native and cross).
cmake --build "${BUILD_ROOT}" -j "${CPU_COUNT}"
cmake --install "${BUILD_ROOT}"

echo "=== sccache stats ==="
sccache --show-stats

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

# The wheel's find_package(Python) is also unversioned and unhinted, so it too would
# grab a stray regular python from PATH on free-threaded builds. setup.py won't forward
# -D to its cmake, so the pin-python-executable.patch (applied via recipe.yaml) makes its
# CMakeLists read $ENV{Python_EXECUTABLE}; export it here. ${PYTHON} is the right
# interpreter in every case (host python natively; cross-python when cross).
export Python_EXECUTABLE="${PYTHON}"

if [ "${CONDA_BUILD_CROSS_COMPILATION:-0}" = "1" ]; then
    # numba-cuda-mlir/cext/mlir-llvm70 uses mlir_tablegen() to generate headers at build
    # time. The MLIR install exports mlir-tblgen as an IMPORTED target pointing at
    # ${LLVM_MODERN_INSTALL}/bin/mlir-tblgen — the host binary, which can't run on the build
    # machine. Swap in the build-platform one built in Stage 1.
    cp "${BUILD_ROOT}-native/bin/mlir-tblgen" "${LLVM_MODERN_INSTALL}/bin/mlir-tblgen"

    # pip's metadata step spawns a subprocess via sys.executable, which cross-python sets to
    # the host Python (argv[0] trick) → binfmt_misc → exit 255. Build the wheel in-process
    # instead: BuildExtWithCmake.run() calls cmake via self.spawn() (a cmake subprocess, not
    # sys.executable). Installing the built .whl reads metadata from the zip, so no
    # build-backend subprocess is spawned.
    "${PYTHON}" setup.py bdist_wheel
    "${PYTHON}" -m pip install dist/*.whl --no-deps -vv
else
    "${PYTHON}" -m pip install . \
        --no-build-isolation \
        --no-deps \
        -vv
fi

# numba-cuda-mlir's runtime loader looks for a bundled numba_cuda_mlir/lib/libLLVM-7.so.
# Point that at the conda libllvm7.1 library.
SP="$("${PYTHON}" -c "import sysconfig; print(sysconfig.get_paths()['platlib'])")"
mkdir -p "${SP}/numba_cuda_mlir/lib"
# $SP/numba_cuda_mlir/lib -> up 4 -> $PREFIX/lib
ln -sf ../../../../libLLVM-7.1.so "${SP}/numba_cuda_mlir/lib/libLLVM-7.so"
