from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class DesktopApp:
    name: str
    command: tuple[str, ...]


_NATIVE = (
    ("Bambu Studio", ("bambu-studio", "BambuStudio")),
    ("OrcaSlicer", ("orca-slicer", "OrcaSlicer")),
    ("Creality Print", ("creality-print", "CrealityPrint")),
    ("PrusaSlicer", ("prusa-slicer", "PrusaSlicer")),
)
_FLATPAK = (
    ("Bambu Studio", "com.bambulab.BambuStudio"),
    ("OrcaSlicer", "com.orcaslicer.OrcaSlicer"),
    ("PrusaSlicer", "com.prusa3d.PrusaSlicer"),
)


def installed_slicers() -> list[DesktopApp]:
    found: list[DesktopApp] = []
    names: set[str] = set()
    for name, binaries in _NATIVE:
        executable = next((path for binary in binaries if (path := shutil.which(binary))), None)
        if executable:
            found.append(DesktopApp(name, (executable,)))
            names.add(name)
    if shutil.which("flatpak"):
        roots = (Path.home() / ".local/share/flatpak/app", Path("/var/lib/flatpak/app"))
        for name, app_id in _FLATPAK:
            if name not in names and any((root / app_id).exists() for root in roots):
                found.append(DesktopApp(name, ("flatpak", "run", app_id)))
                names.add(name)
    return found


def open_desktop_app(app: DesktopApp) -> None:
    subprocess.Popen(app.command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
