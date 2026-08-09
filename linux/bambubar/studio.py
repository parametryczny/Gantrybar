from __future__ import annotations

import os
from pathlib import Path

from .core import studio_devices_from_content


def candidates() -> list[Path]:
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    roots = [
        config,
        Path.home() / ".var/app/com.bambulab.BambuStudio/config",
        Path.home() / ".var/app/com.bambulab.BambuStudioBeta/config",
    ]
    folders = ("BambuStudio", "Bambu Studio", "BambuStudioBeta", "BambuStudioInternal")
    result: list[Path] = []
    for root in roots:
        for folder in folders:
            result.extend((root / folder / "BambuStudio.conf", root / folder / "BambuStudio.conf.bak"))
    return result


def devices() -> list[tuple[str, str, str | None]]:
    found = False
    last_error: Exception | None = None
    for path in candidates():
        if not path.exists():
            continue
        found = True
        try:
            values = studio_devices_from_content(path.read_text(encoding="utf-8"))
            if values:
                return values
        except (OSError, UnicodeError, ValueError) as error:
            last_error = error
    if not found:
        raise FileNotFoundError("bambu-studio-config-not-found")
    if last_error:
        raise last_error
    raise ValueError("bambu-studio-no-printers")
