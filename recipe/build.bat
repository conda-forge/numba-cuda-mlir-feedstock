@echo off
setlocal enableextensions
:: SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
:: SPDX-License-Identifier: Apache-2.0
::
:: Windows analog of build.sh. Two steps, same as Linux:
::   1. build modern LLVM/MLIR + Python bindings from source (MSVC, /MD, static)
::   2. pip install the numba_cuda_mlir wheel
:: plus two Windows-only steps Linux does not need:
::   1b/1c. stage the MLIR bindings + build the modern->NVVM bridge (cmake --install
::          does not lay these out under the custom prefix on Windows)
::   2b.    synthesize LLVM-C.dll from conda llvmdev's static LLVM 7 libs, because
::          LLVM 7 cannot build LLVM-C.dll on Windows itself. This is the Windows
::          equivalent of Linux's libLLVM-7.so (which comes prebuilt from libllvm7.1).

set "PYTHON=%PREFIX%\python.exe"

:: conda-build layout vars (rattler-build normally sets these; default them
:: defensively so the LLVM-C synthesis can always find llvmdev's static libs).
if not defined LIBRARY_PREFIX set "LIBRARY_PREFIX=%PREFIX%\Library"
if not defined LIBRARY_LIB set "LIBRARY_LIB=%LIBRARY_PREFIX%\lib"

if not defined PARALLEL set "PARALLEL=%CPU_COUNT%"
if not defined PARALLEL set "PARALLEL=%NUMBER_OF_PROCESSORS%"
if not defined PARALLEL set "PARALLEL=2"
echo Building with PARALLEL=%PARALLEL% compile jobs

set "BUILD_ROOT=%SRC_DIR%\_llvm_build"
set "LLVM_MODERN_SRC=%SRC_DIR%\llvm-modern-src"
set "LLVM_MODERN_INSTALL=%SRC_DIR%\llvm-modern-install"
set "MLIR_PKG=%LLVM_MODERN_INSTALL%\python_packages\numba_cuda_mlir_mlir\numba_cuda_mlir\_mlir"
set "MLIR_LIBS=%MLIR_PKG%\_mlir_libs"
set "BRIDGE_BUILD=%BUILD_ROOT%\mlir-modern-to-nvvm"
set "LLVM_C_OUT=%SRC_DIR%\llvm-c-install"

:: sccache speeds up local rebuilds; skip it in CI (cold cache, and its daemon holds
:: the work dir open which breaks cleanup). CI is forwarded via the recipe's script
:: env (rattler-build's isolation strips it otherwise); test the value, not `defined`,
:: since it may arrive as an empty string. setup.py reads these env vars for the wheel's
:: cmake; our own cmake calls pass them via %LAUNCHER_ARGS%.
set "LAUNCHER_ARGS="
if "%CI%"=="" (
    where sccache >nul 2>nul || (echo ERROR: sccache not found & exit /b 1)
    set "CMAKE_C_COMPILER_LAUNCHER=sccache"
    set "CMAKE_CXX_COMPILER_LAUNCHER=sccache"
    set "LAUNCHER_ARGS=-DCMAKE_C_COMPILER_LAUNCHER=sccache -DCMAKE_CXX_COMPILER_LAUNCHER=sccache"
)

:: pin-python-executable.patch reads $ENV{Python_EXECUTABLE} in the wheel's cmake.
set "Python_EXECUTABLE=%PYTHON%"

:: On a free-threaded build ("t" ABI) tell FindPython to require that ABI, matching
:: build.sh. Fields are [pydebug;pymalloc;unicode;freethreading].
set "FIND_ABI_ARGS="
for /f "usebackq delims=" %%A in (`"%PYTHON%" -c "import sysconfig;print('t' if 't' in (sysconfig.get_config_var('ABIFLAGS') or '') else '')"`) do set "FT=%%A"
if "%FT%"=="t" (
  set "FIND_ABI_ARGS=-DPython_FIND_ABI=OFF;OFF;OFF;ON -DPython3_FIND_ABI=OFF;OFF;OFF;ON"
  set "Python_FIND_ABI=OFF;OFF;OFF;ON"
)

echo ==============================================================
echo Step 1/3: Modern LLVM/MLIR + Python bindings
echo ==============================================================
cmake -G Ninja ^
  -S "%LLVM_MODERN_SRC%\llvm" ^
  -B "%BUILD_ROOT%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_INSTALL_PREFIX="%LLVM_MODERN_INSTALL%" ^
  -DCMAKE_C_COMPILER=cl ^
  -DCMAKE_CXX_COMPILER=cl ^
  %LAUNCHER_ARGS% ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL ^
  -DLLVM_USE_CRT_RELEASE=MD ^
  -DLLVM_ENABLE_PROJECTS=mlir ^
  -DLLVM_TARGETS_TO_BUILD=NVPTX ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DLLVM_ENABLE_PIC=ON ^
  -DLLVM_BUILD_TOOLS=OFF ^
  -DLLVM_BUILD_EXAMPLES=OFF ^
  -DLLVM_INCLUDE_TESTS=OFF ^
  -DLLVM_INCLUDE_BENCHMARKS=OFF ^
  -DLLVM_INCLUDE_DOCS=OFF ^
  -DLLVM_ENABLE_ZLIB=OFF ^
  -DLLVM_ENABLE_ZSTD=OFF ^
  -DMLIR_ENABLE_BINDINGS_PYTHON=ON ^
  -DCMAKE_CXX_FLAGS="-DMLIR_PYTHON_PACKAGE_PREFIX=numba_cuda_mlir._mlir. -DMLIR_USE_FALLBACK_TYPE_IDS=1" ^
  -DMLIR_BINDINGS_PYTHON_INSTALL_PREFIX="python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir" ^
  -DMLIR_BINDINGS_PYTHON_NB_DOMAIN=numba_cuda_mlir ^
  -DMLIR_PYTHON_STUBGEN_ENABLED=OFF ^
  -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=ON ^
  -DPython_ROOT_DIR="%PREFIX%" ^
  -DPython_EXECUTABLE="%PYTHON%" ^
  -DPython_FIND_REGISTRY=NEVER ^
  -DPython3_ROOT_DIR="%PREFIX%" ^
  -DPython3_EXECUTABLE="%PYTHON%" ^
  -DPython3_FIND_REGISTRY=NEVER ^
  %FIND_ABI_ARGS%
if errorlevel 1 exit /b 1

cmake --build "%BUILD_ROOT%" -j %PARALLEL%
if errorlevel 1 exit /b 1
cmake --install "%BUILD_ROOT%"
if errorlevel 1 exit /b 1
if "%CI%"=="" sccache --show-stats

echo ==============================================================
echo Step 1b: Stage MLIR Python bindings into the install tree
echo ==============================================================
"%PYTHON%" "%RECIPE_DIR%\stage_mlir_bindings.py" --build-root "%BUILD_ROOT%" --install-root "%LLVM_MODERN_INSTALL%"
if errorlevel 1 exit /b 1

echo ==============================================================
echo Step 1c: Modern-to-NVVM bridge (MLIRModernToNVVM)
echo ==============================================================
cmake -G Ninja ^
  -S "%SRC_DIR%\src\cext\mlir-modern" ^
  -B "%BRIDGE_BUILD%" ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_PREFIX_PATH="%LLVM_MODERN_INSTALL%" ^
  -DMLIR_DIR="%LLVM_MODERN_INSTALL%\lib\cmake\mlir" ^
  -DLLVM_DIR="%LLVM_MODERN_INSTALL%\lib\cmake\llvm" ^
  -DCMAKE_C_COMPILER=cl ^
  -DCMAKE_CXX_COMPILER=cl ^
  %LAUNCHER_ARGS% ^
  -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
if errorlevel 1 exit /b 1
cmake --build "%BRIDGE_BUILD%" --target MLIRModernToNVVM MLIRModernToNVVMSmoke -j %PARALLEL%
if errorlevel 1 exit /b 1
for %%E in (dll lib) do for /f "delims=" %%F in ('dir /b /s "%BRIDGE_BUILD%\MLIRModernToNVVM.%%E" 2^>nul') do copy /y "%%F" "%MLIR_LIBS%\" >nul
if not exist "%MLIR_LIBS%\MLIRModernToNVVM.dll" (echo ERROR: MLIRModernToNVVM.dll was not produced & exit /b 1)

echo ==============================================================
echo Step 2: Synthesize LLVM-C.dll from conda llvmdev static libs
echo ==============================================================
"%PYTHON%" "%RECIPE_DIR%\build_llvm_c_dll.py" --lib-dir "%LIBRARY_LIB%" --out-dir "%LLVM_C_OUT%" --dll-name LLVM-C
if errorlevel 1 exit /b 1

echo ==============================================================
echo Step 3: numba_cuda_mlir wheel
echo ==============================================================
cd /d "%SRC_DIR%\src"
:: CUDA headers + dlpack come from the conda host env (Library prefix on Windows).
set "CUDAToolkit_ROOT=%LIBRARY_PREFIX%"
set "DLPACK_PATH=%LIBRARY_PREFIX%"
set "MLIR_DIR=%LLVM_MODERN_INSTALL%\lib\cmake\mlir"
:: setup.py._stage_libllvm7 bundles this DLL into numba_cuda_mlir\lib\ (keeps the
:: basename on Windows). At runtime CAPILoader LoadLibrary's it. No symlink step
:: (that is Linux-only).
set "LIBLLVM7=%LLVM_C_OUT%\LLVM-C.dll"
"%PYTHON%" -m pip install . --no-build-isolation --no-deps -vv
if errorlevel 1 exit /b 1

echo === Windows build complete ===

:: Stop the sccache daemon before rattler-build packages/cleans up. Under env
:: isolation rattler-build remaps HOME into the work dir, so sccache's cache lands
:: inside work\, and the running server keeps those files mapped -- which makes the
:: post-package cleanup fail to delete work\ with "Access is denied (os error 5)".
:: Unconditional and exit /b 0 so a missing server never fails the build.
sccache --stop-server >nul 2>nul
exit /b 0
