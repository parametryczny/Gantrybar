#!/usr/bin/env python3
"""Compile and run the production AppKit layout regression in a disposable directory."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="gantry-card-test-") as folder:
    out = Path(folder)
    sources = sorted(str(p) for p in (root / "Sources/Gantry").rglob("*.swift") if p.name != "GantryApp.swift")
    subprocess.run(["swiftc", "-D", "GANTRY_RENDER", "-Xfrontend", "-disable-dynamic-actor-isolation",
                    "-module-cache-path", str(out / "cache"), "-I", str(root / "Sources/CCommonCrypto"),
                    *sources, str(root / "scripts/check_card_error_layout.swift"), "-o", str(out / "card-test")], check=True)
    subprocess.run([str(out / "card-test")], check=True)
