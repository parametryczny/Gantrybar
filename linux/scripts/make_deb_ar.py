#!/usr/bin/env python3
"""Write the simple ar container used by Debian packages (portable macOS fallback)."""

from __future__ import annotations

import sys
import time
from pathlib import Path


def header(name: str, size: int) -> bytes:
    fields = (
        f"{name}/".ljust(16),
        str(int(time.time())).ljust(12),
        "0".ljust(6),
        "0".ljust(6),
        "100644".ljust(8),
        str(size).ljust(10),
        "`\n",
    )
    value = "".join(fields).encode("ascii")
    if len(value) != 60:
        raise ValueError("invalid ar header")
    return value


def main(arguments: list[str]) -> int:
    if len(arguments) < 3:
        print("usage: make_deb_ar.py OUTPUT INPUT...", file=sys.stderr)
        return 2
    output = Path(arguments[1])
    inputs = [Path(value) for value in arguments[2:]]
    with output.open("wb") as archive:
        archive.write(b"!<arch>\n")
        for path in inputs:
            data = path.read_bytes()
            archive.write(header(path.name, len(data)))
            archive.write(data)
            if len(data) % 2:
                archive.write(b"\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
