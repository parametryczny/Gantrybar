"""Two-way LAN sync of Spoolbase (physical rolls), the printer list and display settings between the
user's own computers. Same /api/sync contract as macOS/Windows (camelCase keys, ISO-8601 dates,
lowercase enums), so Linux <-> Linux, Linux <-> Mac and Linux <-> Windows all work. No cloud.

Pure stdlib (urllib, json, threading) -- no extra dependency. The pure builders (local_snapshot /
apply_remote) are unit-testable; only sync_now touches the network.
"""

from __future__ import annotations

import json
import secrets
import socket
import threading
import urllib.request
from datetime import datetime, timezone
from typing import Any

from .physicalspool import PhysicalSpoolStore

# The subset of settings that travel between machines. Linux keys map 1:1 to the macOS raw values
# ("low"/"medium"/"high", "pl"/"en", "dark"/"light"); mac-only extras are filled with defaults on send
# and ignored on receive.
_NOTIFY = (("notifyFinished", "notify_finished"), ("notifyError", "notify_error"),
           ("notifyPaused", "notify_paused"), ("notifyLowFilament", "notify_low_filament"),
           ("notifyHumidity", "notify_humidity"))


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _wire_date(value: Any) -> str:
    """macOS/Windows decode ISO-8601 without fractional seconds; the Spoolbase catalogue stores dates
    with microseconds, so normalise to '...Z' on the wire or the peer drops the whole snapshot."""
    if not isinstance(value, str) or not value:
        return _now_iso()
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return _now_iso()
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def make_token() -> str:
    hexs = secrets.token_hex(8).upper()
    groups = [hexs[i:i + 4] for i in range(0, 16, 4)]
    return "-".join(["GANTRY"] + groups)


def normalize_address(address: str) -> str:
    value = (address or "").strip()
    for scheme in ("http://", "https://"):
        if value.lower().startswith(scheme):
            value = value[len(scheme):]
    value = value.strip("/")
    if not value:
        return ""
    if ":" not in value:
        value += ":8787"
    return value


class SyncService:
    def __init__(self, app: Any) -> None:
        self.app = app
        self.store: PhysicalSpoolStore = getattr(app, "physical_spools", None) or PhysicalSpoolStore()
        self._applying = False
        cfg = app.config.data
        if not cfg.get("sync_device_id"):
            cfg["sync_device_id"] = secrets.token_hex(8)
        if not cfg.get("sync_token"):
            cfg["sync_token"] = make_token()
        app.config.save()

    # --- token & peers --------------------------------------------------------
    @property
    def token(self) -> str:
        return str(self.app.config.data.get("sync_token", ""))

    @property
    def device_id(self) -> str:
        return str(self.app.config.data.get("sync_device_id", ""))

    def peers(self) -> list[dict[str, Any]]:
        return list(self.app.config.data.get("sync_peers", []) or [])

    def regenerate_token(self) -> None:
        self.app.config.data["sync_token"] = make_token()
        self.app.config.save()

    def set_token(self, token: str) -> None:
        token = (token or "").strip()
        if token:
            self.app.config.data["sync_token"] = token
            self.app.config.save()

    def add_peer(self, address: str) -> None:
        addr = normalize_address(address)
        peers = self.peers()
        if not addr or any(p.get("address") == addr for p in peers):
            return
        peers.append({"address": addr, "lastSyncAt": None, "lastError": None})
        self.app.config.data["sync_peers"] = peers
        self.app.config.save()
        self.sync_now()

    def remove_peer(self, address: str) -> None:
        self.app.config.data["sync_peers"] = [p for p in self.peers() if p.get("address") != address]
        self.app.config.save()

    def authorize(self, authorization: str | None) -> bool:
        if not authorization:
            return False
        presented = authorization[7:] if authorization.startswith("Bearer ") else authorization
        return presented == self.token

    # --- snapshot build / apply ----------------------------------------------
    def local_snapshot(self) -> dict[str, Any]:
        return {
            "protocolVersion": 1,
            "deviceID": self.device_id,
            "deviceName": socket.gethostname(),
            "generatedAt": _now_iso(),
            "spools": self.store.spools,
            "usageEvents": self.store.usage,
            "catalog": self._catalog(),
            "printers": [self._printer_dict(p) for p in self.app.printers],
            "settings": self._settings(),
        }

    def apply_remote(self, remote: dict[str, Any]) -> None:
        if not isinstance(remote, dict):
            return
        changed = self.store.merge_remote(remote.get("spools", []), remote.get("usageEvents", []))
        changed = self._merge_catalog(remote.get("catalog", [])) or changed
        changed = self._merge_printers(remote.get("printers", [])) or changed
        settings = remote.get("settings")
        if isinstance(settings, dict):
            clock = str(self.app.config.data.get("sync_settings_updated_at", ""))
            if str(settings.get("updatedAt", "")) > clock:
                self._apply_settings(settings)
                self.app.config.data["sync_settings_updated_at"] = settings.get("updatedAt", _now_iso())
                self.app.config.save()
                changed = True
        if changed:
            try:
                self.app.rebuild_cards()
            except Exception:
                pass

    def note_settings_changed(self) -> None:
        if self._applying:
            return
        self.app.config.data["sync_settings_updated_at"] = _now_iso()
        self.app.config.save()

    # --- helpers --------------------------------------------------------------
    def _catalog(self) -> list[dict[str, Any]]:
        store = getattr(self.app, "filament_store", None)
        if store is None:
            return []
        out = []
        for filament in store.filaments:
            row = filament.to_dict()
            row["updatedAt"] = _wire_date(row.get("updatedAt"))
            out.append(row)
        return out

    def _merge_catalog(self, remote: list[dict[str, Any]]) -> bool:
        store = getattr(self.app, "filament_store", None)
        if store is None or not remote:
            return False
        try:
            return store.merge_remote(remote)
        except Exception:
            return False

    @staticmethod
    def _printer_dict(printer: Any) -> dict[str, Any]:
        return {
            "serial": printer.serial, "name": printer.name,
            "model": getattr(printer, "model", "Bambu Lab"), "host": printer.host,
            "kind": getattr(printer.kind, "value", "bambu"), "port": getattr(printer, "port", None),
        }

    def _merge_printers(self, remote: list[dict[str, Any]]) -> bool:
        from .core import Printer, PrinterKind
        known = {p.serial for p in self.app.printers}
        changed = False
        for r in remote or []:
            serial = r.get("serial")
            if not serial or serial in known:
                continue
            try:
                kind = PrinterKind(r.get("kind", "bambu"))
            except ValueError:
                kind = PrinterKind.BAMBU
            self.app.printers.append(Printer(
                serial=serial, name=r.get("name", serial), host=r.get("host", ""),
                model=r.get("model", "Bambu Lab"), port=int(r.get("port") or 0), kind=kind))
            known.add(serial)
            changed = True
        if changed:
            self.app.config.printers = self.app.printers
            self.app.config.save()
            try:
                self.app.reconnect_all()
            except Exception:
                pass
        return changed

    def _settings(self) -> dict[str, Any]:
        cfg = self.app.config.data
        out = {
            "updatedAt": str(cfg.get("sync_settings_updated_at", "")),
            "theme": str(cfg.get("theme", "dark")),
            "language": str(cfg.get("language", "pl")),
            "panelTransparency": str(cfg.get("panel_transparency", "low")),
            "spoolbaseEnabled": bool(cfg.get("spoolbase_enabled", True)),
            "webDashboardEnabled": bool(cfg.get("web_dashboard_enabled", True)),
            "monochrome": bool(cfg.get("monochrome", False)),
            "autoUpdate": False,
            "cardShowFileName": True, "cardShowProgress": True,
            "cardShowTemperatures": True, "cardShowFilaments": True,
        }
        for wire, key in _NOTIFY:
            out[wire] = bool(cfg.get(key, True))
        return out

    def _apply_settings(self, s: dict[str, Any]) -> None:
        self._applying = True
        try:
            cfg = self.app.config.data
            cfg["theme"] = s.get("theme", cfg.get("theme"))
            cfg["language"] = s.get("language", cfg.get("language"))
            cfg["panel_transparency"] = s.get("panelTransparency", cfg.get("panel_transparency"))
            cfg["spoolbase_enabled"] = bool(s.get("spoolbaseEnabled", cfg.get("spoolbase_enabled", True)))
            cfg["web_dashboard_enabled"] = bool(s.get("webDashboardEnabled", cfg.get("web_dashboard_enabled", True)))
            cfg["monochrome"] = bool(s.get("monochrome", cfg.get("monochrome", False)))
            for wire, key in _NOTIFY:
                if wire in s:
                    cfg[key] = bool(s[wire])
            self.app.config.save()
            try:
                self.app.language = str(cfg.get("language", "pl"))
                self.app.apply_theme()
            except Exception:
                pass
        finally:
            self._applying = False

    # --- network --------------------------------------------------------------
    def sync_now(self) -> None:
        peers = self.peers()
        if not peers:
            return
        snapshot = json.dumps(self.local_snapshot()).encode()
        for peer in peers:
            threading.Thread(target=self._sync_one, args=(peer.get("address", ""), snapshot), daemon=True).start()

    def _sync_one(self, address: str, snapshot: bytes) -> None:
        error = None
        try:
            remote = self._request(address, "GET", None)
            if remote is not None:
                self._apply_on_main(remote)
            self._request(address, "POST", snapshot)
        except Exception as exc:  # noqa: BLE001 - report, never crash the sync thread
            error = str(exc)
        self._update_peer(address, error)

    def _request(self, address: str, method: str, body: bytes | None) -> dict[str, Any] | None:
        url = f"http://{address}/api/sync"
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        if body is not None:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req, timeout=8) as resp:
            text = resp.read().decode()
        try:
            return json.loads(text)
        except Exception:
            return None

    def _apply_on_main(self, remote: dict[str, Any]) -> None:
        try:
            from gi.repository import GLib  # type: ignore
            GLib.idle_add(lambda: (self.apply_remote(remote), False)[1])
        except Exception:
            self.apply_remote(remote)

    def _update_peer(self, address: str, error: str | None) -> None:
        peers = self.peers()
        for p in peers:
            if p.get("address") == address:
                p["lastError"] = error
                if error is None:
                    p["lastSyncAt"] = _now_iso()
        self.app.config.data["sync_peers"] = peers
        try:
            self.app.config.save()
        except Exception:
            pass
