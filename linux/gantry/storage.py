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
    "dashboard_columns": 2,
    "collapsed": False,
    "scan_targets": "",
    "notify_finished": True,
    "notify_error": True,
    "notify_paused": True,
    "notify_low_filament": True,
    # Heads-up shortly before a job ends, and the remaining-minutes threshold that triggers it.
    # Off by default: on a busy fleet it is one extra alert per job on top of the finished one.
    "notify_finishing_soon": False,
    "notify_finishing_soon_minutes": 10,
    "notify_humidity": True,
    "notify_offline": False,
    "quiet_hours_enabled": True,
    "quiet_hours_start": "22:00",
    "quiet_hours_end": "07:00",
    "spoolbase_enabled": True,
    "developer_mode": False,
    "card_show_filename": True,
    "card_show_progress": True,
    "card_show_temperatures": True,
    "card_show_filaments": True,
    "card_show_spool_grams": False,
    "monochrome": False,
    "web_dashboard_enabled": True,
    # Linux keeps package installation under the desktop package manager's control. This setting
    # enables periodic release checks and a native notification/link to the signed release page.
    "auto_update_check": False,
    # Same key and semantics as macOS/Windows: selected printers are pinned individually.
    # ``tray_progress_enabled`` is retained only for one-time migration from older Linux builds.
    "menu_bar_progress_serials": [],
    "tray_progress_enabled": False,
    # Automations: {serial: [rule, ...]}. Off-by-default kill switch gates the two code-running actions
    # (raw command / shell script); approved rule ids remember a one-time consent per rule.
    "automations": {},
    "allow_script_actions": False,
    "approved_script_rules": [],
    "printers": [],
    "certificate_pins": {},
    # Telegram: same shared keys as macOS/Windows (docs/telegram.md). Token stays local, no shared bot.
    "telegram-enabled": False,
    "telegram-bot-token": "",
    "telegram-chat-id": "",
    "telegram-mute-until": "",
    "print-history-v1": [],
    "printer-insights-v1": {},
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
                # Older Linux builds exposed one global "active prints" switch. Preserve that choice
                # by pinning every saved printer once, then use the per-printer model from now on.
                if "menu_bar_progress_serials" not in value and value.get("tray_progress_enabled"):
                    self.data["menu_bar_progress_serials"] = [
                        str(item.get("serial")) for item in value.get("printers", [])
                        if isinstance(item, dict) and item.get("serial")
                    ]
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

    def progress_serials(self) -> list[str]:
        values = self.data.get("menu_bar_progress_serials", [])
        return [str(value) for value in values if isinstance(value, str) and value]

    def is_progress_pinned(self, serial: str) -> bool:
        return serial in self.progress_serials()

    def set_progress_pinned(self, serial: str, enabled: bool) -> None:
        current = self.progress_serials()
        if enabled and serial not in current:
            current.append(serial)
        elif not enabled:
            current = [value for value in current if value != serial]
        self.data["menu_bar_progress_serials"] = current
        self.save()

    def prune_progress_pins(self, valid_serials: list[str]) -> None:
        valid = set(valid_serials)
        current = self.progress_serials()
        filtered = [serial for serial in current if serial in valid]
        if filtered != current:
            self.data["menu_bar_progress_serials"] = filtered
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
