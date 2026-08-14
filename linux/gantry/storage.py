from __future__ import annotations

import json
import locale
import os
import subprocess
from pathlib import Path
from typing import Any

from .core import Printer, printer_to_dict


APP_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "gantry"
CONFIG_FILE = APP_DIR / "config.json"
# Pre-rebrand config location; migrated once on first run so existing installs keep their settings.
_LEGACY_APP_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "bambubar"


def _migrate_legacy_config() -> None:
    """One-time, non-destructive copy of ~/.config/bambubar into ~/.config/gantry."""
    if CONFIG_FILE.exists() or not (_LEGACY_APP_DIR / "config.json").exists():
        return
    try:
        import shutil
        APP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        for item in _LEGACY_APP_DIR.iterdir():
            target = APP_DIR / item.name
            if item.is_file() and not target.exists():
                shutil.copy2(item, target)
    except OSError:
        pass


DEFAULTS: dict[str, Any] = {
    "language": "pl",
    "theme": "dark",
    "panel_transparency": "low",
    "collapsed": False,
    "scan_targets": "",
    "notify_finished": True,
    "notify_error": True,
    "notify_paused": True,
    "notify_low_filament": True,
    "notify_humidity": True,
    "notify_offline": False,
    "quiet_hours_enabled": True,
    "quiet_hours_start": "22:00",
    "quiet_hours_end": "07:00",
    "printers": [],
    "certificate_pins": {},
}


class Config:
    def __init__(self) -> None:
        _migrate_legacy_config()
        self.data = dict(DEFAULTS)
        if not CONFIG_FILE.exists():
            language = (locale.getlocale()[0] or os.environ.get("LANG", "")).lower()
            self.data["language"] = "pl" if language.startswith("pl") else "en"
        self.load()

    def load(self) -> None:
        try:
            value = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
            if isinstance(value, dict):
                self.data.update(value)
        except (FileNotFoundError, OSError, json.JSONDecodeError):
            pass

    def save(self) -> None:
        APP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = CONFIG_FILE.with_suffix(".tmp")
        temporary.write_text(json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(CONFIG_FILE)

    @property
    def printers(self) -> list[Printer]:
        return [Printer.from_dict(value) for value in self.data.get("printers", [])
                if isinstance(value, dict) and value.get("serial")]

    @printers.setter
    def printers(self, values: list[Printer]) -> None:
        self.data["printers"] = [printer_to_dict(value) for value in values]
        self.save()

    def pin_for(self, serial: str) -> str | None:
        return self.data.get("certificate_pins", {}).get(serial)

    def set_pin(self, serial: str, fingerprint: str) -> None:
        pins = dict(self.data.get("certificate_pins", {}))
        pins[serial] = fingerprint
        self.data["certificate_pins"] = pins
        self.save()

    def remove_pin(self, serial: str) -> None:
        pins = dict(self.data.get("certificate_pins", {}))
        pins.pop(serial, None)
        self.data["certificate_pins"] = pins
        self.save()


class SecretStoreError(RuntimeError):
    pass


class SecretStore:
    """Uses the desktop Secret Service through libsecret's small `secret-tool` client."""

    @staticmethod
    def _run(arguments: list[str], value: str | None = None) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                ["secret-tool", *arguments], input=value, text=True,
                capture_output=True, timeout=15, check=False,
            )
        except FileNotFoundError as error:
            raise SecretStoreError("secret-tool-not-installed") from error
        except subprocess.TimeoutExpired as error:
            raise SecretStoreError("secret-service-timeout") from error

    def get(self, serial: str) -> str | None:
        result = self._run(["lookup", "application", "Gantry", "serial", serial])
        if result.returncode != 0:
            # Fall back to codes saved by the pre-rebrand app so upgrades keep credentials.
            result = self._run(["lookup", "application", "BambuBar", "serial", serial])
            if result.returncode != 0:
                return None
        value = result.stdout.rstrip("\n")
        return value or None

    def set(self, serial: str, code: str) -> None:
        result = self._run(
            ["store", "--label", f"Gantry — {serial}", "application", "Gantry", "serial", serial],
            code,
        )
        if result.returncode != 0:
            raise SecretStoreError(result.stderr.strip() or "secret-service-error")

    def delete(self, serial: str) -> None:
        self._run(["clear", "application", "Gantry", "serial", serial])
        self._run(["clear", "application", "BambuBar", "serial", serial])


def set_autostart(enabled: bool) -> None:
    directory = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "autostart"
    target = directory / "gantry.desktop"
    if not enabled:
        try:
            target.unlink()
        except FileNotFoundError:
            pass
        return
    directory.mkdir(parents=True, exist_ok=True)
    target.write_text("""[Desktop Entry]
Type=Application
Name=Gantry
Comment=Bambu Lab, Klipper and Prusa printer status monitor
Exec=gantry --background
Icon=gantry
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
""", encoding="utf-8")


def autostart_enabled() -> bool:
    directory = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "autostart"
    return (directory / "gantry.desktop").exists()
