#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
"""Synthesize an ``LLVM-C.dll`` (+ import lib) from LLVM static ``.lib`` archives.

LLVM 7 cannot build the ``LLVM-C`` C-API shared library on Windows itself: its
``llvm/tools/llvm-shlib/CMakeLists.txt`` gates that target behind a Darwin-only
``FATAL_ERROR`` (native MSVC support for ``LLVM-C.dll`` landed in a later LLVM
release). The conda ``llvmdev 7.1.*`` package therefore ships LLVM 7 only as
static ``.lib`` archives. This script reconstructs the loadable ``LLVM-C.dll``
from those archives the same way modern ``llvm-shlib`` does on MSVC:

  1. ``dumpbin /symbols`` every ``LLVM*.lib`` and keep the defined ``LLVM*`` C
     symbols -> ``LLVM-C.def``.
  2. compile a tiny CRT stub, then ``link.exe /DLL /DEF /WHOLEARCHIVE:<lib>``
     over every archive -> ``LLVM-C.dll`` + ``LLVM-C.lib``.
  3. verify ``LLVMContextCreate`` is exported.

It is intentionally self-contained (stdlib only, no assumptions about the
numba-cuda-mlir source tree) so it can later be lifted verbatim into the
conda-forge LLVM 7.1 feedstock as a Windows-only ``libllvm-c`` output.

Usage::

    python build_llvm_c_dll.py --lib-dir "%LIBRARY_LIB%" --out-dir <dest>

Outputs ``<out-dir>/LLVM-C.dll`` and ``<out-dir>/LLVM-C.lib``.

The C runtime (``--crt``, default ``MD``) must match the CRT the input archives
were built with; conda-forge builds LLVM ``/MD``.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
from typing import Iterable

# Dependency libs the whole-archived LLVM libs may reference. conda-forge builds
# llvmdev fully (zlib + DIA SDK enabled), unlike upstream's minimal LLVM 7, so
# these must be on the link line. Default to the zlib *import* lib so the DLL
# links zlib dynamically (conda-forge preference: zlib CVEs are fixed by updating
# the shared lib, not rebuilding this package); --zlib-static embeds it instead.
_ZLIB_IMPORT_CANDIDATES = ("zlib.lib", "zdll.lib", "z.lib")
_ZLIB_STATIC_CANDIDATES = ("zlibstatic.lib",)
_SYSTEM_DEP_LIBS = ("ole32.lib", "oleaut32.lib")

# Defined external LLVM C-API symbols as they appear in `dumpbin /symbols`
# output (optionally decorated with an __imp_ thunk or a leading underscore).
_SYMBOL_RE = re.compile(r"\|\s+((?:__imp_)?_?LLVM[A-Za-z0-9_@]+)\s*$")

# A minimal translation unit that pulls in _fltused (required when linking a DLL
# from objects/archives that reference floating point but has no other code).
_STUB_SOURCE = "int _fltused = 0;\n"


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        **kwargs,
    )


def _resolve_tool(explicit: str | None, name: str, banner: str) -> str:
    """Find an MSVC tool on PATH (or use ``explicit``) and validate its banner."""
    tool = explicit or shutil.which(name)
    if not tool:
        raise SystemExit(f"ERROR: unable to find {name} on PATH (pass --{name.split('.')[0]})")
    proc = _run([tool, "/?"])
    if banner.lower() not in (proc.stdout + proc.stderr).lower():
        raise SystemExit(f"ERROR: {tool} does not look like {name} (missing banner {banner!r})")
    return tool


def _normalize_symbol(symbol: str) -> str:
    if symbol.startswith("__imp_"):
        symbol = symbol[len("__imp_") :]
    # x86 stdcall decoration: LLVMFoo@8 -> LLVMFoo
    if "@" in symbol:
        base, sep, suffix = symbol.rpartition("@")
        if sep and suffix.isdigit():
            symbol = base
    # x86 cdecl leading underscore: _LLVMFoo -> LLVMFoo
    if symbol.startswith("_LLVM"):
        symbol = symbol[1:]
    return symbol


def _extract_exports(
    libs: list[pathlib.Path], dumpbin: str, work_dir: pathlib.Path
) -> set[str]:
    """Collect every defined LLVM* external symbol across all archives.

    dumpbin accepts many inputs in one invocation, so all archives are scanned
    in a single call via a response file (dozens of quoted paths would otherwise
    risk the command-line length limit). Symbols need no per-lib attribution --
    everything accumulates into one set.
    """
    rsp = work_dir / "dumpbin-symbols.rsp"
    rsp.write_text(
        "/nologo\n/symbols\n" + "".join(f'"{lib}"\n' for lib in libs),
        encoding="utf-8",
    )
    proc = _run([dumpbin, f"@{rsp}"])
    if proc.returncode != 0:
        raise SystemExit(
            f"ERROR: dumpbin failed (exit {proc.returncode})\n{proc.stdout}\n{proc.stderr}"
        )
    exports: set[str] = set()
    for line in proc.stdout.splitlines():
        if "External" not in line or "UNDEF" in line:
            continue
        m = _SYMBOL_RE.search(line)
        if not m:
            continue
        symbol = _normalize_symbol(m.group(1))
        if symbol.startswith("LLVM"):
            exports.add(symbol)
    return exports


def _collect_libs(lib_dir: pathlib.Path) -> list[pathlib.Path]:
    libs = sorted(
        p
        for p in lib_dir.glob("LLVM*.lib")
        if p.name not in {"LLVM-C.lib", "LLVM.lib"}
    )
    if not libs:
        raise SystemExit(f"ERROR: no LLVM*.lib archives found under {lib_dir}")
    return libs


def _collect_dep_libs(
    lib_dir: pathlib.Path, machine: str, extra_libs: list[str], zlib_static: bool
) -> list[str]:
    """Dependency libraries needed to link the whole-archived LLVM libs.

    LLVMSupport references zlib (compress2/crc32/...) and LLVMDebugInfoPDB
    references the MSVC DIA SDK (IID_IDiaDataSource/CLSID_DiaSource/NoRegCoCreate)
    when llvmdev is built with those features (conda-forge does). Resolve them so
    the LLVM-C.dll link finds every external symbol.

    This is a hand-maintained mirror of the optional features conda-forge enables
    in llvmdev today; the principled source of truth is ``llvm-config
    --system-libs`` (plus the DIA SDK, which LLVM's own CMake pulls in for
    LLVMDebugInfoPDB). If a future llvmdev enables another system dependency the
    link fails with unresolved externals -- add it here or pass --extra-lib.
    """
    deps: list[str] = []

    zlib_candidates = _ZLIB_STATIC_CANDIDATES if zlib_static else _ZLIB_IMPORT_CANDIDATES
    for name in zlib_candidates:
        cand = lib_dir / name
        if cand.exists():
            deps.append(str(cand))
            kind = "static" if zlib_static else "import (dynamic)"
            print(f">>> zlib dependency [{kind}]: {cand.name}")
            break
    else:
        print("WARNING: no zlib lib found next to the LLVM archives")

    # diaguids.lib ships with MSVC under the DIA SDK (path independent of VS
    # edition via VSINSTALLDIR).
    vsinstall = os.environ.get("VSINSTALLDIR")
    if vsinstall:
        arch = "arm64" if machine.lower() == "arm64" else "amd64"
        diaguids = pathlib.Path(vsinstall) / "DIA SDK" / "lib" / arch / "diaguids.lib"
        if diaguids.exists():
            deps.append(str(diaguids))
            print(f">>> DIA SDK dependency: {diaguids}")
        else:
            print(f"WARNING: diaguids.lib not found at {diaguids}")
    else:
        print("WARNING: VSINSTALLDIR unset; cannot locate DIA SDK diaguids.lib")

    deps.extend(_SYSTEM_DEP_LIBS)
    deps.extend(extra_libs)
    return deps


def _write_def(path: pathlib.Path, dll_name: str, exports: Iterable[str]) -> None:
    with path.open("w", encoding="utf-8") as f:
        f.write(f"LIBRARY {dll_name}\n")
        f.write("EXPORTS\n")
        for name in sorted(exports):
            f.write(f"{name}\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Synthesize LLVM-C.dll from LLVM static libs")
    parser.add_argument(
        "--lib-dir",
        type=pathlib.Path,
        required=True,
        help="directory containing the LLVM*.lib static archives (e.g. %%LIBRARY_LIB%%)",
    )
    parser.add_argument(
        "--out-dir",
        type=pathlib.Path,
        required=True,
        help="destination directory for LLVM-C.dll and LLVM-C.lib",
    )
    parser.add_argument("--dll-name", default="LLVM-C", help="DLL base name (default: LLVM-C)")
    parser.add_argument("--machine", default="X64", help="link /MACHINE target (default: X64)")
    parser.add_argument(
        "--crt",
        default="MD",
        choices=("MD", "MT", "MDd", "MTd"),
        help="C runtime for the stub; must match the input archives (default: MD)",
    )
    parser.add_argument("--cl", default=None, help="path to cl.exe")
    parser.add_argument("--link", default=None, help="path to link.exe")
    parser.add_argument("--dumpbin", default=None, help="path to dumpbin.exe")
    parser.add_argument(
        "--extra-lib",
        action="append",
        default=[],
        metavar="LIB",
        help="additional dependency lib (full path or bare name) to add to the link",
    )
    parser.add_argument(
        "--zlib-static",
        action="store_true",
        help="statically embed zlib instead of linking the shared zlib import lib",
    )
    ns = parser.parse_args()

    lib_dir = ns.lib_dir.resolve()
    out_dir = ns.out_dir.resolve()
    work_dir = out_dir / "_llvm_c_build"
    out_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    cl = _resolve_tool(ns.cl, "cl.exe", "Microsoft (R) C/C++")
    link = _resolve_tool(ns.link, "link.exe", "Incremental Linker")
    dumpbin = _resolve_tool(ns.dumpbin, "dumpbin.exe", "COFF/PE Dumper")

    libs = _collect_libs(lib_dir)
    print(f">>> Scanning {len(libs)} LLVM static archives under {lib_dir}")
    dep_libs = _collect_dep_libs(lib_dir, ns.machine, ns.extra_lib, ns.zlib_static)

    exports = _extract_exports(libs, dumpbin, work_dir)
    if "LLVMContextCreate" not in exports:
        raise SystemExit(
            "ERROR: export scan did not find LLVMContextCreate; "
            f"got {len(exports)} LLVM symbols. Are these LLVM C-API archives?"
        )
    print(f">>> Collected {len(exports)} LLVM C-API export symbols")

    def_file = work_dir / f"{ns.dll_name}.def"
    _write_def(def_file, ns.dll_name, exports)

    # Compile the CRT stub. /MD (default) matches conda-forge's LLVM archives.
    stub_c = work_dir / "llvm-c-stub.c"
    stub_obj = work_dir / "llvm-c-stub.obj"
    stub_c.write_text(_STUB_SOURCE, encoding="utf-8")
    cl_proc = _run(
        [cl, "-nologo", "-c", "-O2", f"-{ns.crt}", f"-Fo{stub_obj}", str(stub_c)],
        cwd=str(work_dir),
    )
    if cl_proc.returncode != 0:
        raise SystemExit(f"ERROR: cl stub compile failed\n{cl_proc.stdout}\n{cl_proc.stderr}")

    dll_path = out_dir / f"{ns.dll_name}.dll"
    imp_path = out_dir / f"{ns.dll_name}.lib"

    # Build a link.exe response file: /WHOLEARCHIVE each static lib so every
    # exported symbol is pulled in, even without an explicit reference.
    link_rsp = work_dir / "llvm-c-link.rsp"
    with link_rsp.open("w", encoding="utf-8") as f:
        # Quote every path: response-file tokens split on spaces, and dep libs
        # like diaguids.lib live under "C:\Program Files\...".
        f.write("/NOLOGO\n/DLL\n")
        f.write(f"/MACHINE:{ns.machine}\n")
        f.write(f'/OUT:"{dll_path}"\n')
        f.write(f'/IMPLIB:"{imp_path}"\n')
        f.write(f'/DEF:"{def_file}"\n')
        f.write("/INCLUDE:LLVMContextCreate\n")
        f.write(f'"{stub_obj}"\n')
        for lib in libs:
            f.write(f'/WHOLEARCHIVE:"{lib}"\n')
        # Dependency libs (zlib, DIA SDK, COM) linked normally so only the
        # referenced symbols are pulled in.
        for dep in dep_libs:
            f.write(f'"{dep}"\n')

    print(f">>> Linking {dll_path.name}")
    link_proc = _run([link, f"@{link_rsp}"], cwd=str(work_dir))
    if link_proc.returncode != 0:
        raise SystemExit(f"ERROR: link.exe failed\n{link_proc.stdout}\n{link_proc.stderr}")
    if not dll_path.exists():
        raise SystemExit(f"ERROR: link succeeded but {dll_path} was not produced")

    # Verify the DLL actually exports the C API.
    verify = _run([dumpbin, "/nologo", "/exports", str(dll_path)])
    if "LLVMContextCreate" not in verify.stdout:
        raise SystemExit(
            f"ERROR: {dll_path} does not export LLVMContextCreate\n"
            f"{verify.stdout[:2000]}\n{verify.stderr}"
        )

    print(f">>> OK: {dll_path} ({dll_path.stat().st_size} bytes), import lib {imp_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
