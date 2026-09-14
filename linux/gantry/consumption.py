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
import urllib.parse
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


def candidate_paths(file_name: str) -> list[str]:
    """Where the printed archive may sit on the printer's card, in the order macOS tries them
    (BambuFileClient.candidatePaths): the name as reported and its last component, with .gcode.3mf and .3mf
    added when missing and spaces as underscores, each at the root and under cache/, model/ and data/.
    Linux used to try five paths, so a job reported without an extension was never found. One fixture
    (design/fixtures/bambu-3mf-candidates.json) holds all three platforms to the same list."""
    raw = urllib.parse.unquote(file_name).strip()
    if not raw:
        return []
    names: list[str] = []

    def add_name(value: str) -> None:
        value = value.strip("/")
        if value and value not in names:
            names.append(value)

    last = _last_component(raw)
    add_name(raw)
    add_name(last)
    for seed in (raw, last):
        if not seed.lower().endswith(".3mf"):
            add_name(seed + ".gcode.3mf")
            add_name(seed + ".3mf")
    # Studio and cloud jobs sometimes replace spaces with underscores in the file name on the card.
    for name in list(names):
        if " " in name:
            add_name(name.replace(" ", "_"))
    paths: list[str] = []

    def add_path(value: str) -> None:
        if value not in paths:
            paths.append(value)

    for name in names:
        add_path(name)
        add_path("/" + name)
        leaf = _last_component(name)
        for root in ("cache", "model", "data"):
            add_path(f"/{root}/{leaf}")
            add_path(f"{root}/{leaf}")
    return paths


def _last_component(path: str) -> str:
    """NSString.lastPathComponent: the part after the last slash, trailing slashes ignored."""
    trimmed = path.rstrip("/")
    if not trimmed:
        return "/" if path else ""
    return trimmed.rsplit("/", 1)[-1]


def fetch_bambu_3mf(host: str, access_code: str, filename: str) -> bytes | None:
    """Download the printed .gcode.3mf over the printer's local FTPS. Accepts the self-signed cert.
    Returns the bytes, or None on any failure (never raises)."""
    candidates = candidate_paths(filename.replace("\\", "/"))
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


_SESSIONS_KEY = "spoolbase-print-sessions"


def observe_session(sessions: dict[str, dict[str, Any]], serial: str, previous_state: Any, state: Any,
                    job_name: str | None, now: float, accounting_enabled: bool = True) -> tuple[str | None, bool]:
    """Which print a finished job belongs to. Returns (the job id when this update is the finish to
    account for, whether the sessions changed). Mirrors macOS PrintJobSessions: the hour a FINISHED
    packet arrived used to be the identity, so two short prints of one file within an hour merged and a
    finish seen again after a restart in a later hour was subtracted twice. A session starts when the
    printer is seen printing, ends when it finishes, and is kept in the config."""
    from .core import PrinterState
    job = job_name or "?"
    session_id = f"{serial}|{job}|{int(now)}"
    current = sessions.get(serial)
    if state in (PrinterState.PRINTING, PrinterState.PAUSED):
        if current and current.get("job") == job and not current.get("finished"):
            return None, False
        sessions[serial] = {"job": job, "id": session_id, "finished": False}
        return None, True
    if state == PrinterState.FINISHED:
        if previous_state == PrinterState.FINISHED:
            return None, False
        if current and current.get("job") == job:
            changed = not current.get("finished")
            if changed and not accounting_enabled:
                current["skipped"] = True
            current["finished"] = True
            return (None if current.get("skipped") else current["id"]), changed
        # Finished before Gantry saw it print. One session for it, kept, so a restart reuses it.
        sessions[serial] = {"job": job, "id": session_id, "finished": True, "skipped": not accounting_enabled}
        return (session_id if accounting_enabled else None), True
    return None, False


def loaded_slot(serial: str, groups: list, has_spool: Any) -> tuple[dict[str, Any], Any] | None:
    """The slot a single-extruder print came from: the active one, wherever it is. With none active, only
    a lone loaded roll counts. Taking the first present slot charged whatever roll sat in A1 while A2 was
    feeding, and the first unit's roll while the second unit was feeding."""
    from .physicalspool import location_for
    active: list[tuple[dict[str, Any], Any]] = []
    loaded: list[tuple[dict[str, Any], Any]] = []
    for gi, group in enumerate(groups):
        for si, slot in enumerate(group.slots):
            entry = (location_for(serial, getattr(group, "external", False), gi, si), slot)
            if getattr(slot, "active", False):
                active.append(entry)
            elif getattr(slot, "present", False) and has_spool(entry[0]):
                loaded.append(entry)
    if active:
        return active[0] if len(active) == 1 else None
    return loaded[0] if len(loaded) == 1 else None


def assigned_spools(store: Any, serial: str, groups: list) -> dict[tuple[int, int], str]:
    """The roll assigned to every slot, read when the print finishes."""
    from .physicalspool import location_for
    assigned: dict[tuple[int, int], str] = {}
    for gi, group in enumerate(groups):
        for si, _slot in enumerate(group.slots):
            spool = store.spool_at(location_for(serial, getattr(group, "external", False), gi, si))
            if spool is not None:
                assigned[(gi, si)] = spool["id"]
    return assigned


def bambu_charges(serial: str, groups: list, filaments: list[dict[str, Any]],
                  assigned: dict[tuple[int, int], str]) -> list[tuple[str, float, Any]]:
    """Maps each sliced filament to a slot by colour (a single filament falls back to the loaded slot) and
    to the roll that was assigned there when the print finished."""
    def hex6(value: Any) -> str:
        return (value or "").lstrip("#").upper()[:6]

    def by_color(fil: dict[str, Any]) -> tuple[int, int] | None:
        """The slot a filament was printed from, by colour. Two slots of one colour are told apart by
        material; still more than one means the job cannot say which roll it used, so nothing is charged
        rather than the first match (two black rolls used to be charged as one)."""
        wanted = hex6(fil.get("color"))
        if not wanted:
            return None
        matches = [(gi, si, (getattr(slot, "material", "") or "").upper())
                   for gi, group in enumerate(groups) for si, slot in enumerate(group.slots)
                   if hex6(getattr(slot, "color", "")) == wanted]
        material = str(fil.get("type") or "").upper()
        if len(matches) > 1 and material:
            matches = [match for match in matches if match[2] == material]
        return (matches[0][0], matches[0][1]) if len(matches) == 1 else None

    charges: list[tuple[str, float, Any]] = []
    for fil in filaments:
        if fil["used_g"] <= 0:
            continue
        target = by_color(fil)
        if target is None and len(filaments) == 1:
            chosen = loaded_slot(serial, groups, lambda loc: (loc["amsIndex"], loc["slot"]) in assigned)
            target = (chosen[0]["amsIndex"], chosen[0]["slot"]) if chosen else None
        if target is None or target not in assigned:
            continue
        charges.append((assigned[target], fil["used_g"], fil["id"]))
    return charges


def _consume_klipper(store: Any, serial: str, telemetry: Any, job_id: str) -> bool:
    if not telemetry.filament_used_mm or telemetry.filament_used_mm <= 0:
        return False
    chosen = loaded_slot(serial, telemetry.filament_groups, lambda loc: store.spool_at(loc) is not None)
    if chosen is None:
        return False
    location, slot = chosen
    spool = store.spool_at(location)
    if spool is None:
        return False
    used = grams(telemetry.filament_used_mm, getattr(slot, "material", None))
    return store.consume(spool["id"], used, serial, job_id)


def _consume_bambu(store: Any, serial: str, host: str, access_code: str, telemetry: Any, job_id: str,
                   assigned: dict[tuple[int, int], str], still_enabled: Any = lambda: True) -> None:
    if not telemetry.gcode_file or not assigned:
        return
    data = fetch_bambu_3mf(host, access_code, telemetry.gcode_file)
    if not data:
        store.warn_accounting(job_id, telemetry.job_name or serial)
        return
    # Spoolbase switched off during the download: the print is not accounted.
    if not still_enabled():
        return
    filaments = parse_3mf_filaments(data)
    charges = bambu_charges(serial, telemetry.filament_groups, filaments, assigned)
    if not filaments or len(charges) < sum(f["used_g"] > 0 for f in filaments):
        store.warn_accounting(job_id, telemetry.job_name or serial)
    for spool_id, used_g, filament_id in charges:
        store.consume(spool_id, used_g, serial, f"{job_id}#{filament_id}")


def on_finish(app: Any, serial: str, previous: Any, current: Any) -> None:
    """Follows print sessions on every state change and decrements the assigned roll when one finishes.
    Bambu fetches over the network in a background thread; Klipper is immediate. Idempotent per job.

    With Spoolbase off nothing is subtracted, and nothing is remembered as subtracted either: switching it
    back on resumes from the grams the rolls had. Sessions are still followed, so a print that started
    before the switch has the right identity when it ends."""
    from .core import PrinterKind
    printer = next((p for p in app.printers if p.serial == serial), None)
    if printer is None:
        return
    config = getattr(app, "config", None)
    data = getattr(config, "data", None)
    sessions = data.setdefault(_SESSIONS_KEY, {}) if isinstance(data, dict) else {}
    active = getattr(app, "_spoolbase_active", None)
    job_id, changed = observe_session(sessions, serial, previous.state, current.state, current.job_name, time.time(),
                                      accounting_enabled=not callable(active) or active())
    if changed and callable(getattr(config, "save", None)):
        config.save()
    active = getattr(app, "_spoolbase_active", None)
    if job_id is None or (callable(active) and not active()):
        return
    store = getattr(app, "physical_spools", None)
    if store is None:
        return
    if printer.kind == PrinterKind.KLIPPER:
        _consume_klipper(store, serial, current, job_id)
    elif printer.kind == PrinterKind.BAMBU:
        try:
            access = app.secrets.get(serial)
        except Exception:
            access = None
        if access:
            # The rolls are read now, at the finish. Looked up after the download, a roll swapped in while
            # the file was still coming over was charged for the print that had come off the old one.
            assigned = assigned_spools(store, serial, current.filament_groups)
            enabled = active if callable(active) else (lambda: True)
            threading.Thread(target=_consume_bambu,
                             args=(store, serial, printer.host, access, current, job_id, assigned, enabled),
                             daemon=True).start()
