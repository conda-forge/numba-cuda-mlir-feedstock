#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Stage the built MLIR Python bindings into the LLVM install tree (Windows).

On Windows ``cmake --install`` does not lay the MLIR Python package out under the
custom ``MLIR_BINDINGS_PYTHON_INSTALL_PREFIX`` with its native runtime artifacts
the way it does on Linux, so we copy them from the build tree by hand -- the same
work upstream ``ci/build-windows.sh`` (``build_modern_llvm``) does. This mirrors
that logic so ``setup.py`` (via ``MLIR_DIR``) can find and bundle the bindings.

Copies into ``<install>/python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir``:
  * the whole ``_mlir`` package from ``<build>/tools/mlir/python_packages/...``
  * every ``_mlir*.pyd`` / ``MLIRPython*.dll`` / ``nanobind*.dll`` found under the
    build tree, into ``_mlir/_mlir_libs``
And copies ``MLIRPythonCAPI.lib`` to ``<install>/lib`` (the import lib setup.py
links the LLVM70 bridge against).
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys
import sysconfig

_MLIR_PKG_REL = pathlib.PurePosixPath(
    "python_packages/numba_cuda_mlir_mlir/numba_cuda_mlir/_mlir"
)
_RUNTIME_GLOBS = ("_mlir*.pyd", "MLIRPython*.dll", "nanobind*.dll")


def main() -> int:
    parser = argparse.ArgumentParser(description="Stage MLIR Python bindings (Windows)")
    parser.add_argument("--build-root", type=pathlib.Path, required=True)
    parser.add_argument("--install-root", type=pathlib.Path, required=True)
    ns = parser.parse_args()

    build_root = ns.build_root.resolve()
    install_root = ns.install_root.resolve()

    build_pkg = build_root / "tools" / "mlir" / _MLIR_PKG_REL
    install_pkg = install_root / _MLIR_PKG_REL
    install_libs = install_pkg / "_mlir_libs"

    if not build_pkg.is_dir():
        raise SystemExit(f"ERROR: MLIR Python build package not found at {build_pkg}")

    install_pkg.mkdir(parents=True, exist_ok=True)
    shutil.copytree(build_pkg, install_pkg, dirs_exist_ok=True)
    install_libs.mkdir(parents=True, exist_ok=True)

    copied = 0
    for pattern in _RUNTIME_GLOBS:
        for artifact in build_root.rglob(pattern):
            if artifact.is_file():
                shutil.copy2(artifact, install_libs / artifact.name)
                copied += 1
    print(f">>> Staged {copied} MLIR runtime artifacts into {install_libs}")

    ext_suffix = sysconfig.get_config_var("EXT_SUFFIX") or ".pyd"
    core_ext = install_libs / f"_mlir{ext_suffix}"
    if not core_ext.exists():
        listing = "\n".join(sorted(p.name for p in install_libs.glob("*"))) or "<empty>"
        raise SystemExit(
            f"ERROR: MLIR core extension {core_ext.name} was not staged into {install_libs}\n"
            f"Contents:\n{listing}"
        )

    capi_lib = next(build_root.rglob("MLIRPythonCAPI.lib"), None)
    if capi_lib is not None:
        dest = install_root / "lib" / "MLIRPythonCAPI.lib"
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(capi_lib, dest)
        print(f">>> Staged import lib {dest}")
    else:
        print("WARNING: MLIRPythonCAPI.lib not found in build tree")

    return 0


if __name__ == "__main__":
    sys.exit(main())
