"""Turns a finished print into a physical-spool decrement, locally and without the cloud.

  - Klipper / Moonraker: real measured ``filament_used`` (mm) converted to grams here.
  - Bambu: the slicer's ``used_g`` read from the printed ``.gcode.3mf``, fetched over the printer's own
    FTPS (implicit TLS, port 990, user ``bblp``, password = access code, self-signed cert accepted).

Rules (same as macOS/Windows): subtract on FINISH only, never on start; every subtraction is idempotent
per print job. Pure stdlib (zipfile, xml, ftplib, ssl) -- no extra dependency. The grams math and the
3mf parser are unit-testable; only the FTPS fetch needs the printer.
"""

from __future__ import annotations

import io
import ssl
import threading
import time
import xml.etree.ElementTree as ET
import zipfile
from ftplib import FTP_TLS
from typing import Any

_DIAMETER_MM = 1.75

_DENSITY = {"PETG": 1.27, "ABS": 1.04, "ASA": 1.07, "TPU": 1.21, "PVA": 1.23, "PC": 1.20, "PLA": 1.24}


def density(material: str | None) -> float:
    m = (material or "").upper()
    for key, value in _DENSITY.items():
        if key in m:
            return value
    if m.startswith("PA"):
        return 1.14   # nylon family
    return 1.24


def grams(length_mm: float, material: str | None) -> float:
    """grams = cross-section area (mm^2) * length (mm) -> mm^3, /1000 -> cm^3, * density (g/cm^3)."""
    area = 3.141592653589793 * (_DIAMETER_MM / 2) * (_DIAMETER_MM / 2)
    return length_mm * area / 1000.0 * density(material)


def parse_3mf_filaments(data: bytes) -> list[dict[str, Any]]:
    """Per-filament rows from a Bambu .gcode.3mf (Metadata/slice_info.config). Returns dicts with
    id / used_g / used_m / type / color (6-hex, no '#')."""
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            config = archive.read("Metadata/slice_info.config")
    except Exception:
        return []
    try:
        root = ET.fromstring(config)
    except ET.ParseError:
        return []
    out: list[dict[str, Any]] = []
    for element in root.iter("filament"):
        def _f(name: str) -> float:
            try:
                return float(element.get(name) or 0)
            except (TypeError, ValueError):
                return 0.0
        out.append({
            "id": int(element.get("id") or (len(out) + 1)),
            "used_g": _f("used_g"),
            "used_m": _f("used_m"),
            "type": element.get("type") or "",
            "color": (element.get("color") or "").lstrip("#").upper(),
        })
    return out


class _ImplicitFTPTLS(FTP_TLS):
    """FTP over implicit TLS (the whole control channel is wrapped from connect, as Bambu expects)."""

    def connect(self, host: str = "", port: int = 990, timeout: float = 8.0, source_address=None):  # type: ignore[override]
        import socket
        self.host = host
        self.port = port
        self.sock = self.context.wrap_socket(
            socket.create_connection((host, port), timeout), server_hostname=None)
        self.af = self.sock.family
        self.file = self.sock.makefile("r", encoding=self.encoding)
        self.welcome = self.getresp()
        return self.welcome


def fetch_bambu_3mf(host: str, access_code: str, filename: str) -> bytes | None:
    """Download the printed .gcode.3mf over the printer's local FTPS. Accepts the self-signed cert.
    Returns the bytes, or None on any failure (never raises)."""
    base = filename.replace("\\", "/").rsplit("/", 1)[-1]
    candidates = [filename, f"/{base}", base, f"/cache/{base}", f"/model/{base}"]
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    ftp = _ImplicitFTPTLS(context=context)
    try:
        ftp.connect(host, 990, timeout=8.0)
        ftp.login("bblp", access_code)
        ftp.prot_p()
        for path in candidates:
            chunks: list[bytes] = []
            try:
                ftp.retrbinary(f"RETR {path}", chunks.append)
                if chunks:
                    return b"".join(chunks)
            except Exception:
                continue
        return None
    except Exception:
        return None
    finally:
        try:
            ftp.quit()
        except Exception:
            try:
                ftp.close()
            except Exception:
                pass


def _job_id(serial: str, telemetry: Any) -> str:
    return f"{serial}|{telemetry.job_name or '?'}|{int(time.time() // 3600)}"


def _loaded_location(store: Any, serial: str, groups: list) -> Any:
    """The slot carrying an assigned spool that is active (or present) — the one a single extruder feeds."""
    from .physicalspool import location_for
    for gi, group in enumerate(groups):
        for si, slot in enumerate(group.slots):
            if getattr(slot, "active", False) or getattr(slot, "present", False):
                loc = location_for(serial, getattr(group, "external", False), gi, si)
                if store.spool_at(loc) is not None:
                    return loc
    return None


def _consume_klipper(store: Any, serial: str, telemetry: Any, job_id: str) -> bool:
    if not telemetry.filament_used_mm or telemetry.filament_used_mm <= 0:
        return False
    for gi, group in enumerate(telemetry.filament_groups):
        for si, slot in enumerate(group.slots):
            if not (getattr(slot, "active", False) or getattr(slot, "present", False)):
                continue
            from .physicalspool import location_for
            loc = location_for(serial, getattr(group, "external", False), gi, si)
            spool = store.spool_at(loc)
            if spool is None:
                continue
            used = grams(telemetry.filament_used_mm, getattr(slot, "material", None))
            return store.consume(spool["id"], used, serial, job_id)
    return False


def _consume_bambu(store: Any, serial: str, host: str, access_code: str, telemetry: Any, job_id: str) -> None:
    if not telemetry.gcode_file:
        return
    data = fetch_bambu_3mf(host, access_code, telemetry.gcode_file)
    if not data:
        return
    filaments = parse_3mf_filaments(data)
    groups = telemetry.filament_groups

    def by_color(color_hex: str):
        from .physicalspool import location_for
        for gi, group in enumerate(groups):
            for si, slot in enumerate(group.slots):
                slot_hex = (getattr(slot, "color", "") or "").lstrip("#").upper()[:6]
                if color_hex and slot_hex == color_hex[:6]:
                    return location_for(serial, getattr(group, "external", False), gi, si)
        return None

    single = _loaded_location(store, serial, groups) if len(filaments) == 1 else None
    for fil in filaments:
        if fil["used_g"] <= 0:
            continue
        loc = by_color(fil["color"]) or single
        if loc is None:
            continue
        spool = store.spool_at(loc)
        if spool is not None:
            store.consume(spool["id"], fil["used_g"], serial, f"{job_id}#{fil['id']}")


def on_finish(app: Any, serial: str, previous: Any, current: Any) -> None:
    """Decrement the assigned spool on the transition into FINISHED. Bambu fetches over the network in a
    background thread; Klipper is immediate. Idempotent per job."""
    from .core import PrinterState, PrinterKind
    if previous.state == PrinterState.FINISHED or current.state != PrinterState.FINISHED:
        return
    printer = next((p for p in app.printers if p.serial == serial), None)
    store = getattr(app, "physical_spools", None)
    if printer is None or store is None:
        return
    job_id = _job_id(serial, current)
    if printer.kind == PrinterKind.KLIPPER:
        _consume_klipper(store, serial, current, job_id)
    elif printer.kind == PrinterKind.BAMBU:
        try:
            access = app.secrets.get(serial)
        except Exception:
            access = None
        if access:
            threading.Thread(target=_consume_bambu,
                             args=(store, serial, printer.host, access, current, job_id), daemon=True).start()
