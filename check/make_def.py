#!/usr/bin/env python3
"""Regenerates build/rodentflow.def from the @_cdecl names in the ABI sources.

    python check/make_def.py          (from the top of the repository)
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
abi = root / "engine" / "Sources" / "RodentFlowABI" / "ABI"
names = sorted({m for p in sorted(abi.glob("*.swift"))
                for m in re.findall(r'@_cdecl\("([^"]+)"\)', p.read_text())})
if not names:
    sys.exit(f"No @_cdecl entry points found in {abi}")
lines = [
    "; rodentflow.def — the C entry points of RodentFlowABI.dll.",
    ";",
    "; Generated from the @_cdecl names in engine/Sources/RodentFlowABI/ABI/*.swift.",
    "; build\\build_engine.ps1 links with this only if the DLL comes out without its exports.",
    "; Regenerate with:  python check\\make_def.py",
    "",
    "LIBRARY RodentFlowABI",
    "EXPORTS",
    *(f"    {n}" for n in names),
]
(root / "build" / "rodentflow.def").write_text("\n".join(lines) + "\n")
print(f"wrote build/rodentflow.def with {len(names)} entry points")
