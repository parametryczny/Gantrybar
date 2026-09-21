#!/usr/bin/env python3
"""Compile and run the Settings window height regression in a disposable directory."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="gantry-settings-height-") as folder:
    out = Path(folder)
    sources = sorted(str(p) for p in (root / "Sources/Gantry").rglob("*.swift") if p.name != "GantryApp.swift")
    subprocess.run(["swiftc", "-D", "GANTRY_RENDER", "-Xfrontend", "-disable-dynamic-actor-isolation",
                    "-module-cache-path", str(out / "cache"), "-I", str(root / "Sources/CCommonCrypto"),
                    *sources, str(root / "scripts/check_settings_height.swift"), "-o", str(out / "height")],
                   check=True, stderr=subprocess.DEVNULL)
    sys.exit(subprocess.run([str(out / "height")]).returncode)
