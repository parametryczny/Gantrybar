"""Switching between the regular app and Gantry Workshop, the full-screen kiosk.

Both are windows over the same printers and settings, so a switch only starts the other one and
hands over "start after login": whichever was starting at login keeps doing so in the other form.
No GTK here, so the flow is testable without a display.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from .storage import autostart_enabled, set_autostart

KIOSK_AUTOSTART = """[Desktop Entry]
Type=Application
Name=Gantry Workshop
Comment=Full-screen printer monitoring dashboard
Exec=gantry-kiosk
Icon=gantry
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
"""


def kiosk_autostart_file() -> Path:
    """The login entry for the kiosk, the same file gantry-kiosk-setup writes."""
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "autostart" / "gantry-kiosk.desktop"


def kiosk_command() -> list[str] | None:
    """The installed kiosk launcher. It ships with the DEB, RPM and Arch packages, not the AppImage,
    and it is what keeps the screen awake, so without it the switch is not offered."""
    launcher = shutil.which("gantry-kiosk")
    return [launcher] if launcher else None


def desktop_app_command() -> list[str]:
    """The regular Gantry app: the installed launcher, or this interpreter when run from the sources."""
    launcher = shutil.which("gantry")
    return [launcher] if launcher else [sys.executable, "-m", "gantry"]


def _start(command: list[str]) -> None:
    subprocess.Popen(command, start_new_session=True, stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def enter_workshop() -> None:
    """Start the kiosk and move login start over to it. Raises OSError when it cannot start, in which
    case nothing has changed."""
    command = kiosk_command()
    if command is None:
        raise FileNotFoundError("gantry-kiosk")
    _start(command)
    if autostart_enabled():
        entry = kiosk_autostart_file()
        entry.parent.mkdir(parents=True, exist_ok=True)
        entry.write_text(KIOSK_AUTOSTART, encoding="utf-8")
        set_autostart(False)


def leave_workshop() -> None:
    """Start the regular app and move login start back to it. Raises OSError when it cannot start,
    in which case nothing has changed."""
    _start(desktop_app_command())
    entry = kiosk_autostart_file()
    if entry.exists():
        try:
            entry.unlink()
        except OSError:
            return  # a read-only autostart folder must not keep anyone in the kiosk
        set_autostart(True)
