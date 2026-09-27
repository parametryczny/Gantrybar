from __future__ import annotations

"""Farm: sliced 3MF files sent to Bambu Lab printers over local FTPS and started over MQTT after an
explicit check, G-code sent to Klipper, PrusaLink and OctoPrint over HTTP (transfer.py), plus a queue
that hands copies to printers whose bed the user confirmed empty.

Mirrors the macOS Farm (Sources/Gantry/Farm). No GTK here: the archive reading, the rules and the store
are unit-tested headless; farmwindow draws them.
"""

import json
import math
import os
import re
import shutil
import ssl
import threading
import time
import uuid
import base64
import binascii
import xml.etree.ElementTree as ElementTree
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from . import transfer
from .core import PrinterKind, PrinterState

MAX_BYTES = 512 * 1024 * 1024
FARM_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "gantry" / "farm"
ACTIVE = ("uploading", "uploaded", "awaitingStart", "uncertain", "printing")


class FarmError(Exception):
    pass


# ---------------------------------------------------------------- archive

def read_plates(zip_file: zipfile.ZipFile) -> list[dict[str, Any]]:
    indices = sorted({int(match.group(1)) for name in zip_file.namelist()
                      if (match := re.fullmatch(r"Metadata/plate_(\d+)\.gcode", name)) and 0 < int(match.group(1)) < 1000})
    if not indices:
        raise FarmError("To nie jest pocięty plik. W Bambu Studio wybierz eksport pociętej płyty (.3mf).")
    metadata: list[dict[str, Any]] = []
    try:
        info = zip_file.getinfo("Metadata/slice_info.config")
        if info.file_size < 16 * 1024 * 1024:
            metadata = parse_slice_info(zip_file.read(info))
    except KeyError:
        pass
    return [next((plate for plate in metadata if plate["index"] == index), {"index": index, "filaments": []}) for index in indices]


def parse_slice_info(data: bytes) -> list[dict[str, Any]]:
    # The DTD/entity attack surface of ElementTree is limited to what expat allows; the file never
    # references external entities in practice, and a malformed one simply yields no metadata.
    if b"<!DOCTYPE" in data[:2048] or b"<!ENTITY" in data[:4096]:
        return []
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError:
        return []
    plates = []
    for element in root.iter("plate"):
        plate: dict[str, Any] = {"index": -1, "filaments": []}
        for meta in element.findall("metadata"):
            key, value = meta.get("key"), meta.get("value")
            if value is None:
                continue
            if key == "index":
                plate["index"] = int(value) if value.isdigit() else -1
            elif key == "prediction":
                plate["seconds"] = int(value) if value.isdigit() else None
            elif key == "printer_model_id":
                plate["printerModel"] = value
            elif key == "nozzle_diameters":
                try:
                    plate["nozzle"] = float(value)
                except ValueError:
                    pass
        for filament in element.findall("filament"):
            try:
                fid = int(filament.get("id") or 0)
            except ValueError:
                continue
            if 0 < fid <= 64:
                try:
                    grams = float(filament.get("used_g") or 0)
                except ValueError:
                    grams = 0.0
                plate["filaments"].append({"id": fid, "material": filament.get("type") or "?",
                                           "color": filament.get("color") or "", "grams": grams})
        plates.append(plate)
    return plates


def read_preview(zip_file: zipfile.ZipFile, plate: int) -> bytes | None:
    for name in (f"Metadata/plate_{plate}.png", f"Metadata/top_{plate}.png"):
        try:
            info = zip_file.getinfo(name)
        except KeyError:
            continue
        if info.file_size <= 16 * 1024 * 1024:
            return zip_file.read(info)
    return None


# ---------------------------------------------------------------- G-code

GCODE_EXTENSIONS = frozenset({"gcode", "gco", "g", "bgcode"})


def is_gcode(path: str | Path) -> bool:
    return Path(path).suffix.lower().lstrip(".") in GCODE_EXTENSIONS


def gcode_format(path: str | Path) -> str:
    return "bgcode" if Path(path).suffix.lower() == ".bgcode" else "gcode"


def _comments(data: bytes) -> str:
    """Only the head and tail are scanned, never the whole toolpath."""
    window = 512 * 1024
    head, tail = data[:window], data[-window:] if len(data) > window else b""
    return head.decode("utf-8", "replace") + "\n" + tail.decode("utf-8", "replace")


def gcode_settings(text: str) -> dict[str, str]:
    """Key/value comments such as ``; filament_type = PLA;PETG`` or ``;TIME:3600``. First one wins."""
    result: dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line.startswith(";"):
            continue
        body = line[1:].strip()
        separator = body.find("=") if "=" in body else body.find(":")
        if separator < 0:
            continue
        key, value = body[:separator].strip().lower(), body[separator + 1:].strip()
        if key and len(key) < 80 and key not in result:
            result[key] = value
    return result


def gcode_seconds(text: str) -> int | None:
    """"1d 2h 3m 4s" (PrusaSlicer, Orca), or plain seconds (Cura)."""
    value = text.strip()
    if value.isdigit():
        return int(value)
    total, found = 0, False
    for amount, unit in re.findall(r"(\d+)\s*([dhms])", value):
        total += int(amount) * {"d": 86400, "h": 3600, "m": 60, "s": 1}[unit]
        found = True
    return total if found else None


def gcode_plate(data: bytes) -> dict[str, Any]:
    """Time, filaments, nozzle and printer from the slicer's comments, as one plate."""
    values = gcode_settings(_comments(data))
    plate: dict[str, Any] = {"index": 1, "filaments": []}
    for key in ("estimated printing time (normal mode)", "time", "total estimated time"):
        seconds = gcode_seconds(values[key]) if key in values else None
        if seconds is not None:
            plate["seconds"] = seconds
            break
    model = values.get("printer_model") or values.get("printer_settings_id")
    if model:
        plate["printerModel"] = model
    try:
        plate["nozzle"] = float(values.get("nozzle_diameter", "").split(",")[0].strip())
    except ValueError:
        pass

    def listed(key: str) -> list[str]:
        return [item.strip() for item in re.split(r"[;,]", values.get(key, ""))] if values.get(key) else []
    materials, colours = listed("filament_type"), listed("filament_colour")
    grams = listed("filament used [g]") or listed("total filament used [g]")
    for index, material in enumerate(materials):
        if not material:
            continue
        try:
            used = float(grams[index]) if index < len(grams) else 0.0
        except ValueError:
            used = 0.0
        # Unused extruders of a multi-tool profile carry a material but no weight.
        if len(materials) > 1 and used == 0 and grams:
            continue
        plate["filaments"].append({"id": index + 1, "material": material,
                                   "color": colours[index] if index < len(colours) else "", "grams": used})
    return plate


def gcode_thumbnail(data: bytes) -> bytes | None:
    """The largest ``; thumbnail begin WxH N`` PNG block (PrusaSlicer, Orca, Cura with the plug-in)."""
    text = data[:2 * 1024 * 1024].decode("utf-8", "replace")
    best: tuple[int, bytes] | None = None
    collecting: tuple[int, list[str]] | None = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("; thumbnail begin"):
            size = line.split()[3] if len(line.split()) > 3 else ""
            area = 1
            for part in size.split("x"):
                area *= int(part) if part.isdigit() else 1
            collecting = (area, [])
        elif line.startswith("; thumbnail end"):
            if collecting is not None:
                try:
                    png = base64.b64decode("".join(collecting[1]), validate=True)
                except (binascii.Error, ValueError):
                    png = b""
                if png and collecting[0] > (best[0] if best else 0):
                    best = (collecting[0], png)
            collecting = None
        elif collecting is not None and line.startswith(";"):
            collecting[1].append(line[1:].strip())
    return best[1] if best else None


def file_extension(file: dict[str, Any]) -> str:
    return file.get("format") or "3mf"


def printer_accepts(printer: Any, file: dict[str, Any]) -> bool:
    return transfer.accepts(printer.kind, file_extension(file))


def supports_printer(kind: Any) -> bool:
    """Printers the Farm sends files to: Bambu Lab (3MF over FTPS) and the HTTP ones (G-code)."""
    return kind == PrinterKind.BAMBU or transfer.supports(kind)


def job_is_gcode(job: dict[str, Any]) -> bool:
    return not str(job.get("remoteName", "")).lower().endswith(".3mf")


# ---------------------------------------------------------------- rules

def slot_index(slot_id: str) -> int | None:
    parts = slot_id.split("-")
    if len(parts) != 3 or parts[0] != "ams" or not parts[1].isdigit() or not parts[2].isdigit():
        return None
    unit, tray = int(parts[1]), int(parts[2])
    return unit * 4 + tray if 0 <= unit <= 15 and 0 <= tray <= 3 else None


def start_block(telemetry: Any, seen_at: float | None, now: float | None = None) -> str | None:
    now = time.time() if now is None else now
    if telemetry is None or seen_at is None or now - seen_at >= 30:
        return "Brak świeżego statusu drukarki."
    if telemetry.state not in (PrinterState.IDLE, PrinterState.FINISHED):
        return "Drukarka nie jest gotowa."
    if telemetry.error_code:
        return "Drukarka zgłasza błąd."
    return None


def matches(job: dict[str, Any], telemetry: Any) -> bool:
    """Whatever extension the printer reports the job with: Bambu drops ".3mf", OctoPrint and Moonraker
    keep ".gcode", some firmware shows the bare stem."""
    remote = job["remoteName"]
    stem = os.path.splitext(remote)[0]
    reported = (telemetry.job_name or "").replace("\\", "/").rsplit("/", 1)[-1] if telemetry.job_name else None
    gcode = (telemetry.gcode_file or "").replace("\\", "/").rsplit("/", 1)[-1]
    return (reported is not None and (reported in (stem, remote) or os.path.splitext(reported)[0] == stem)) \
        or gcode == remote


def command(job: dict[str, Any]) -> str:
    remote = job["remoteName"]
    return json.dumps({"print": {
        "command": "project_file", "sequence_id": str(int(time.time())),
        "param": f"Metadata/plate_{job['plate']['index']}.gcode", "url": f"ftp:///{remote}",
        "subtask_name": remote[:-4] if remote.endswith(".3mf") else remote,
        "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0", "file": "", "md5": "",
        "bed_type": "auto", "bed_levelling": bool(job.get("bedLeveling", True)), "flow_cali": False,
        "vibration_cali": False, "timelapse": False, "layer_inspect": False,
        "use_ams": bool(job["mapping"]), "ams_mapping": job["mapping"]}}, separators=(",", ":"))


def _rgb(value: str) -> tuple[int, int, int] | None:
    text = (value or "").strip().lstrip("#")
    if len(text) < 6:
        return None
    try:
        number = int(text[:6], 16)
    except ValueError:
        return None
    return number >> 16 & 0xFF, number >> 8 & 0xFF, number & 0xFF


def color_distance(a: str, b: str) -> float | None:
    """Weighted RGB distance (0…~765), enough to tell "same spool colour" from "different"."""
    x, y = _rgb(a), _rgb(b)
    if x is None or y is None:
        return None
    r = (x[0] + y[0]) / 2
    dr, dg, db = x[0] - y[0], x[1] - y[1], x[2] - y[2]
    return math.sqrt((2 + r / 256) * dr * dr + 4 * dg * dg + (2 + (255 - r) / 256) * db * db)


def auto_mapping(plate: dict[str, Any], slots: list[Any], max_distance: float = 90) -> list[int] | None:
    """AMS mapping from the slots loaded now: same material, closest colour within the limit, enough
    filament when the roll reports its weight. A single-filament plate may use the external spool
    (empty mapping). None when a filament has no source."""
    filaments = plate.get("filaments") or []
    if not filaments:
        return None

    def fits(slot: Any, filament: dict[str, Any]) -> float | None:
        if (slot.material or "").casefold() != (filament["material"] or "").casefold():
            return None
        if slot.remaining_weight_g is not None and slot.remaining_weight_g < filament["grams"]:
            return None
        if _rgb(filament["color"]) is None:
            return 0.0
        distance = color_distance(filament["color"], slot.color)
        return distance if distance is not None and distance <= max_distance else None

    mapping = [-1] * max(f["id"] for f in filaments)
    complete = True
    for filament in filaments:
        candidates = [(index, d) for slot in slots if not slot.external
                      and (index := slot_index(slot.slot_id)) is not None and (d := fits(slot, filament)) is not None]
        if candidates:
            mapping[filament["id"] - 1] = min(candidates, key=lambda item: item[1])[0]
        else:
            complete = False
    if complete:
        return mapping
    if len(filaments) == 1 and any(slot.external and fits(slot, filaments[0]) is not None for slot in slots):
        return []
    return None


def next_queue_item(queue: list[dict[str, Any]], serial: str, telemetry: Any,
                    accepts: Callable[[str | None], bool] = lambda fmt: fmt is None) -> tuple[int, list[int]] | None:
    for index, item in enumerate(queue):
        if item.get("copies", 0) <= 0 or (item.get("printers") and serial not in item["printers"]):
            continue
        if not accepts(item.get("format")):
            continue
        nozzle = item["plate"].get("nozzle")
        if nozzle is not None and telemetry.nozzle_diameter is not None and abs(nozzle - telemetry.nozzle_diameter) > 0.01:
            continue
        # G-code carries its own filament choice and was sliced for the printers it names.
        if item.get("format") is not None:
            if serial in (item.get("printers") or []):
                return index, []
            continue
        mapping = auto_mapping(item["plate"], telemetry.ams_slots)
        if mapping is not None:
            return index, mapping
    return None


# ---------------------------------------------------------------- FTPS upload

def upload(host: str, access_code: str, local: Path, remote_name: str,
           progress: Callable[[float], None], cancelled: Callable[[], bool]) -> None:
    """Uploads over the printer's implicit FTPS; returns only after the 226 reply."""
    if not re.fullmatch(r"gantry-[A-Fa-f0-9-]+\.3mf", remote_name):
        raise FarmError("Invalid upload name")
    from .consumption import _ImplicitFTPTLS
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    ftp = _ImplicitFTPTLS(context=context)
    total = max(1, local.stat().st_size)
    sent = 0

    def chunk(data: bytes) -> None:
        nonlocal sent
        if cancelled():
            raise FarmError("Anulowano transfer. Nie uruchomiono druku.")
        sent += len(data)
        progress(sent / total)
    try:
        ftp.connect(host, 990, timeout=15.0)
        ftp.login("bblp", access_code)
        ftp.prot_p()
        with open(local, "rb") as handle:
            ftp.storbinary(f"STOR {remote_name}", handle, blocksize=256 * 1024, callback=chunk)
    finally:
        try:
            ftp.quit()
        except Exception:
            try:
                ftp.close()
            except Exception:
                pass


# ---------------------------------------------------------------- store

def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _date(value: Any) -> float:
    try:
        return datetime.fromisoformat(str(value)).timestamp()
    except ValueError:
        return 0.0


class FarmStore:
    """Library, jobs and queue in ~/.local/share/gantry/farm/index.json. Main loop only; ``run_async``
    and ``on_main`` are injected so tests need no threads or GLib."""

    def __init__(self, app: Any, root: Path | None = None,
                 uploader: Callable[..., None] = upload,
                 sender: Callable[..., None] = transfer.upload,
                 starter: Callable[..., None] = transfer.start,
                 run_async: Callable[[Callable[[], None]], None] | None = None,
                 on_main: Callable[[Callable[[], None]], None] | None = None) -> None:
        self.app = app
        self.root = root or FARM_DIR
        self.uploader = uploader
        self.sender, self.starter = sender, starter
        self.run_async = run_async or (lambda job: threading.Thread(target=job, daemon=True).start())
        self.on_main = on_main or (lambda job: job())
        self.files: list[dict[str, Any]] = []
        self.jobs: list[dict[str, Any]] = []
        self.queue: list[dict[str, Any]] = []
        self.armed: set[str] = set()     # beds the user confirmed empty; memory only
        self.progress: dict[str, float] = {}
        self.notice = ""
        self.listeners: list[Callable[[], None]] = []
        self._cancel: set[str] = set()
        self._ready = True
        try:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            index = self.root / "index.json"
            if index.exists():
                data = json.loads(index.read_text(encoding="utf-8"))
                self.files, self.jobs, self.queue = data.get("files", []), data.get("jobs", []), data.get("queue") or []
                for job in self.jobs:
                    if job.get("state") == "uploading":
                        job.update(state="failed", message="Transfer przerwany przez zamknięcie aplikacji. Wyślij ponownie.")
                    if job.get("state") == "awaitingStart":
                        job.update(state="uncertain", message="Start wysłano przed restartem. Sprawdź drukarkę; polecenie nie zostanie powtórzone.")
                self.persist()
        except (OSError, ValueError) as error:
            self._ready = False
            self.notice = f"Nie można odczytać biblioteki: {error}"

    def _changed(self) -> None:
        for listener in list(self.listeners):
            listener()

    def file_path(self, file_id: str) -> Path:
        return self.root / f"{file_id}.3mf"

    def stored_path(self, file: dict[str, Any]) -> Path:
        return self.root / f"{file['id']}.{file_extension(file)}"

    def preview_path(self, file_id: str, plate: int) -> Path:
        return self.root / f"{file_id}.plate-{plate}.png"

    def persist(self) -> None:
        if not self._ready:
            raise FarmError("Biblioteka jest niedostępna. Nie można bezpiecznie zapisać zadania.")
        target = self.root / "index.json"
        temp = target.with_suffix(".tmp")
        temp.write_text(json.dumps({"files": self.files, "jobs": self.jobs, "queue": self.queue}), encoding="utf-8")
        os.replace(temp, target)

    def _try_persist(self) -> None:
        try:
            self.persist()
        except (OSError, FarmError) as error:
            self.notice = str(error)

    def set_notice(self, text: str) -> None:
        self.notice = text
        self._changed()

    def import_file(self, path: str) -> dict[str, Any] | None:
        """Adds a sliced 3MF or a G-code file to the library and returns its entry (None on failure)."""
        try:
            if not self._ready:
                raise FarmError("Biblioteka jest niedostępna.")
            source = Path(path)
            if is_gcode(source):
                return self._import_gcode(source)
            if not source.is_file() or source.stat().st_size > MAX_BYTES:
                raise FarmError("Wybierz plik 3MF do 512 MB.")
            file_id = str(uuid.uuid4())
            with zipfile.ZipFile(source) as archive:
                plates = read_plates(archive)
                shutil.copyfile(source, self.file_path(file_id))
                for plate in plates:
                    preview = read_preview(archive, plate["index"])
                    if preview:
                        self.preview_path(file_id, plate["index"]).write_bytes(preview)
            entry = {"id": file_id, "name": source.name, "bytes": source.stat().st_size, "plates": plates, "importedAt": _now_iso()}
            self.files.append(entry)
            try:
                self.persist()
            except Exception:
                self.files.remove(entry)
                raise
            self.set_notice(f"Dodano {entry['name']} · {len(plates)} płyt.")
            return entry
        except zipfile.BadZipFile:
            self.set_notice("Nieprawidłowe lub nieobsługiwane archiwum 3MF.")
        except (FarmError, OSError) as error:
            self.set_notice(str(error))
        return None

    def _import_gcode(self, source: Path) -> dict[str, Any]:
        if not source.is_file() or source.stat().st_size > MAX_BYTES:
            raise FarmError("Wybierz plik G-code do 512 MB.")
        file_id, fmt = str(uuid.uuid4()), gcode_format(source)
        data = source.read_bytes()
        entry = {"id": file_id, "name": source.name, "bytes": len(data), "importedAt": _now_iso(), "format": fmt,
                 "plates": [gcode_plate(data) if fmt == "gcode" else {"index": 1, "filaments": []}]}
        self.stored_path(entry).write_bytes(data)
        thumbnail = gcode_thumbnail(data) if fmt == "gcode" else None
        if thumbnail:
            self.preview_path(file_id, 1).write_bytes(thumbnail)
        self.files.append(entry)
        try:
            self.persist()
        except Exception:
            self.files.remove(entry)
            raise
        self.set_notice(f"Dodano {entry['name']} · G-code.")
        return entry

    def _printer(self, serial: str) -> Any:
        return next((p for p in self.app.printers if p.serial == serial), None)

    def _telemetry(self, serial: str) -> Any:
        return self.app.telemetry.get(serial)

    def _seen(self, serial: str) -> float | None:
        return getattr(self.app, "telemetry_seen", {}).get(serial)

    def upload_to(self, file: dict[str, Any], plate: dict[str, Any], printer: Any, mapping: list[int],
                  queue_item: str | None = None, auto_start: bool = False) -> None:
        if not supports_printer(printer.kind):
            raise FarmError("Ta drukarka nie przyjmuje plików z Gantry.")
        if not printer_accepts(printer, file):
            raise FarmError(f"{printer.name}: ten plik nie pasuje do drukarki. 3MF drukują Bambu Lab, G-code — Klipper, Prusa i OctoPrint.")
        if any(j["serial"] == printer.serial and j["state"] == "uploading" for j in self.jobs):
            raise FarmError("Ta drukarka już odbiera plik.")
        try:
            code = self.app.secrets.get(printer.serial)
        except Exception:
            code = None
        gcode = file.get("format") is not None
        if not code and not gcode:
            raise FarmError("Brak kodu dostępu do drukarki.")
        job_id = str(uuid.uuid4())
        now = _now_iso()
        remote_name = f"gantry-{job_id[:8]}.{file_extension(file)}" if gcode else f"gantry-{job_id}.3mf"
        job = {"id": job_id, "fileID": file["id"], "fileName": file["name"], "serial": printer.serial,
               "printerName": printer.name, "plate": plate, "mapping": mapping, "remoteName": remote_name,
               "state": "uploading", "message": "Wysyłanie…", "createdAt": now, "updatedAt": now, "bedLeveling": True}
        if queue_item:
            job["queueItemID"] = queue_item
        if auto_start:
            job["autoStart"] = True
        self.jobs.insert(0, job)
        try:
            self.persist()
        except Exception:
            self.jobs.remove(job)
            raise
        local, host, remote = self.stored_path(file), printer.host, job["remoteName"]

        def work() -> None:
            failure: str | None = None
            progress = lambda value: self.on_main(lambda: self._progress(job_id, value))  # noqa: E731
            cancelled = lambda: job_id in self._cancel  # noqa: E731
            try:
                if gcode:
                    self.sender(printer, code, local, remote, progress, cancelled)
                else:
                    self.uploader(host, code, local, remote, progress, cancelled)
            except Exception as error:   # noqa: BLE001 - every failure is reported on the job
                failure = "Anulowano transfer. Nie uruchomiono druku." if job_id in self._cancel else str(error)

            def finish() -> None:
                self._cancel.discard(job_id)
                self.progress.pop(job_id, None)
                if failure is None:
                    self._update(job_id, "uploaded", "Plik na drukarce. Druk nie został uruchomiony.")
                else:
                    self._update(job_id, "failed", failure)
                    self._return_to_queue(job)
                self.reconcile()
            self.on_main(finish)
        self._changed()
        self.run_async(work)

    def _progress(self, job_id: str, value: float) -> None:
        self.progress[job_id] = value
        self._changed()

    def cancel(self, job_id: str) -> None:
        self._cancel.add(job_id)

    def block_reason(self, job: dict[str, Any]) -> str | None:
        if job["state"] != "uploaded":
            return "To zadanie nie oczekuje na uruchomienie."
        if self._printer(job["serial"]) is None:
            return "Drukarka została usunięta."
        if any(j["serial"] == job["serial"] and j["state"] in ("awaitingStart", "uncertain", "printing") for j in self.jobs):
            return "Poprzednie zadanie tej drukarki wymaga zakończenia lub sprawdzenia."
        requires = getattr(self.app, "requires_signed_commands", None)
        if callable(requires) and requires(job["serial"]):
            return "Drukarka wymaga podpisanych poleceń. Sprawdź tryb LAN / Developer Mode."
        telemetry = self._telemetry(job["serial"])
        reason = start_block(telemetry, self._seen(job["serial"]))
        if reason:
            return reason
        if job_is_gcode(job):
            nozzle = job["plate"].get("nozzle")
            if nozzle is not None and telemetry.nozzle_diameter is not None and abs(nozzle - telemetry.nozzle_diameter) > 0.01:
                return "Średnica dyszy różni się od profilu pliku."
            return None
        filaments = job["plate"].get("filaments") or []
        if not filaments:
            return "Brak informacji o filamentach w pliku. Wyeksportuj płytę z Bambu Studio."
        if not job["mapping"]:
            if len(filaments) != 1:
                return "Wydruk wielomateriałowy wymaga przypisania AMS."
        else:
            for filament in filaments:
                if filament["id"] > len(job["mapping"]):
                    return "Przypisanie AMS jest niekompletne lub materiał w slocie się zmienił."
                slot = next((s for s in telemetry.ams_slots if slot_index(s.slot_id) == job["mapping"][filament["id"] - 1]), None)
                if slot is None or (slot.material or "").casefold() != filament["material"].casefold():
                    return "Przypisanie AMS jest niekompletne lub materiał w slocie się zmienił."
        nozzle = job["plate"].get("nozzle")
        if nozzle is not None and telemetry.nozzle_diameter is not None and abs(nozzle - telemetry.nozzle_diameter) > 0.01:
            return "Średnica dyszy różni się od profilu pliku."
        return None

    def start(self, job_id: str, bed_confirmed: bool, profile_confirmed: bool) -> None:
        """Only after an explicit confirmation; persisting precedes the irreversible send."""
        job = next((j for j in self.jobs if j["id"] == job_id), None)
        if not bed_confirmed or not profile_confirmed or job is None:
            raise FarmError("Potwierdź pusty stół i profil drukarki.")
        reason = self.block_reason(job)
        if reason:
            raise FarmError(reason)
        job.update(state="awaitingStart", startRequestedAt=_now_iso(), updatedAt=_now_iso(),
                   message="Wysłano start. Oczekiwanie na potwierdzenie drukarki…")
        self.persist()
        if job_is_gcode(job):
            printer = self._printer(job["serial"])
            try:
                code = self.app.secrets.get(printer.serial)
            except Exception:
                code = None

            def work() -> None:
                try:
                    self.starter(printer, code, job["remoteName"])
                except Exception as error:   # noqa: BLE001 - reported on the job, never retried
                    message = f"Nie potwierdzono startu: {error} Sprawdź drukarkę."
                    self.on_main(lambda: self._update(job_id, "uncertain", message))
            self.run_async(work)
            self._changed()
            return
        if not self.app.send_command(job["serial"], command(job)):
            self._update(job_id, "uncertain", "Nie potwierdzono wysłania startu. Sprawdź drukarkę.")
            raise FarmError("Nie potwierdzono wysłania startu. Sprawdź drukarkę.")
        self._changed()

    def resolve(self, job_id: str) -> None:
        job = next((j for j in self.jobs if j["id"] == job_id), None)
        if job is not None and job["state"] == "uncertain":
            self._update(job_id, "failed", "Użytkownik sprawdził drukarkę i zamknął niepotwierdzone zadanie. Nie ponowiono startu.")

    def _update(self, job_id: str, state: str, message: str) -> None:
        job = next((j for j in self.jobs if j["id"] == job_id), None)
        if job is None:
            return
        job.update(state=state, message=message, updatedAt=_now_iso())
        try:
            self.persist()
        except (OSError, FarmError) as error:
            self._ready = False
            self.notice = f"Nie udało się zapisać stanu. Nowe wysyłki i starty są zablokowane: {error}"
        self._changed()

    # ------------------------------------------------------------ queue

    def enqueue(self, file: dict[str, Any], plate: dict[str, Any], copies: int, serials: list[str]) -> None:
        if not 1 <= copies <= 99:
            raise FarmError("Liczba kopii: od 1 do 99.")
        if file.get("format") is not None:
            if not serials:
                raise FarmError("G-code jest pocięty pod konkretną drukarkę. Zaznacz drukarki, które mogą go drukować.")
            for serial in serials:
                printer = self._printer(serial)
                if printer is None or not printer_accepts(printer, file):
                    raise FarmError(f"Zaznaczona drukarka nie drukuje plików {file_extension(file)}.")
        elif not plate.get("filaments"):
            raise FarmError("Brak informacji o filamentach w pliku. Kolejka dobiera AMS po materiale i kolorze.")
        item = {"id": str(uuid.uuid4()), "fileID": file["id"], "fileName": file["name"], "plate": plate,
                "copies": copies, "printers": serials, "createdAt": _now_iso()}
        if file.get("format") is not None:
            item["format"] = file["format"]
        self.queue.append(item)
        try:
            self.persist()
        except Exception:
            self.queue.remove(item)
            raise
        self.reconcile()
        self.set_notice(f"Do kolejki: {file['name']} · płyta {plate['index']} × {copies}.")

    def remove_from_queue(self, item_id: str) -> None:
        self.queue = [item for item in self.queue if item["id"] != item_id]
        self._try_persist()
        self._changed()

    def move_up(self, item_id: str) -> None:
        index = next((i for i, item in enumerate(self.queue) if item["id"] == item_id), 0)
        if index > 0:
            self.queue[index - 1], self.queue[index] = self.queue[index], self.queue[index - 1]
            self._try_persist()
            self._changed()

    def arm(self, serial: str) -> None:
        printer = self._printer(serial)
        if printer is None or not supports_printer(printer.kind):
            raise FarmError("Kolejka obsługuje drukarki Bambu Lab, Klipper, Prusa i OctoPrint.")
        telemetry = self._telemetry(serial)
        if telemetry is not None and telemetry.state in (PrinterState.PRINTING, PrinterState.PAUSED):
            raise FarmError("Drukarka drukuje. Oznacz stół jako pusty po zdjęciu wydruku.")
        self.armed.add(serial)
        self.reconcile()
        self._changed()

    def disarm(self, serial: str) -> None:
        self.armed.discard(serial)
        self._changed()

    def _return_to_queue(self, job: dict[str, Any]) -> None:
        item_id = job.get("queueItemID")
        if not item_id:
            return
        # The bed confirmation belonged to this attempt; without it the copy would go straight back out.
        self.armed.discard(job["serial"])
        existing = next((item for item in self.queue if item["id"] == item_id), None)
        if existing is not None:
            existing["copies"] += 1
        else:
            fmt = next((f.get("format") for f in self.files if f["id"] == job["fileID"]), None)
            item = {"id": item_id, "fileID": job["fileID"], "fileName": job["fileName"], "plate": job["plate"],
                    "copies": 1, "printers": [] if fmt is None else [job["serial"]], "createdAt": job["createdAt"]}
            if fmt is not None:
                item["format"] = fmt
            self.queue.insert(0, item)
        self._try_persist()

    def _active(self, serial: str) -> bool:
        return any(j["serial"] == serial and j["state"] in ACTIVE for j in self.jobs)

    def _dispatch(self) -> None:
        if not self._ready or not self.queue:
            return
        requires = getattr(self.app, "requires_signed_commands", None)
        for serial in sorted(self.armed):
            printer = self._printer(serial)
            if printer is None or not supports_printer(printer.kind):
                self.armed.discard(serial)
                continue
            telemetry = self._telemetry(serial)
            if (self._active(serial) or telemetry is None or start_block(telemetry, self._seen(serial))
                    or (callable(requires) and requires(serial))):
                continue
            kind = printer.kind
            found = next_queue_item(self.queue, serial, telemetry,
                                    accepts=lambda fmt, kind=kind: transfer.accepts(kind, fmt or "3mf"))
            if found is None:
                continue
            index, mapping = found
            item = self.queue[index]
            file = next((f for f in self.files if f["id"] == item["fileID"]), None)
            if file is None:
                self.queue.pop(index)
                self.notice = f"Usunięto z kolejki {item['fileName']}: brak pliku w bibliotece."
                self._try_persist()
                continue
            try:
                self.upload_to(file, item["plate"], printer, mapping, item["id"], auto_start=True)
            except FarmError as error:
                self.notice = f"{printer.name}: {error}"
                continue
            if item["copies"] > 1:
                item["copies"] -= 1
            else:
                self.queue.pop(index)
            try:
                self.persist()
            except (OSError, FarmError) as error:
                self._ready = False
                self.notice = f"Nie udało się zapisać kolejki. Wysyłki są zablokowane: {error}"
                return

    def _start_armed(self) -> None:
        for job in [j for j in self.jobs if j["state"] == "uploaded" and j.get("autoStart") and j["serial"] in self.armed]:
            reason = self.block_reason(job)
            if reason:
                message = f"Automatyczny start wstrzymany: {reason}"
                if job["message"] != message:
                    self._update(job["id"], "uploaded", message)
                continue
            self.armed.discard(job["serial"])
            try:
                self.start(job["id"], True, True)
            except FarmError as error:
                self.notice = f"{job['printerName']}: {error}"

    def reconcile(self) -> None:
        now = time.time()
        for job in [j for j in self.jobs if j["state"] in ("awaitingStart", "uncertain", "printing")]:
            telemetry = self._telemetry(job["serial"])
            seen = self._seen(job["serial"])
            fresh = telemetry is not None and seen is not None and now - seen < 30
            since = _date(job.get("startRequestedAt") or job.get("createdAt"))
            if fresh and seen >= since and matches(job, telemetry):
                if telemetry.state in (PrinterState.PRINTING, PrinterState.PAUSED):
                    if job["state"] != "printing":
                        self._update(job["id"], "printing", "Drukarka potwierdziła ten wydruk.")
                elif telemetry.state == PrinterState.FINISHED:
                    self._update(job["id"], "finished", "Wydruk zakończony. Odbierz elementy ze stołu.")
                elif telemetry.state == PrinterState.ERROR:
                    self._update(job["id"], "failed", "Drukarka zgłosiła błąd podczas wydruku.")
            if job["state"] == "printing" and fresh and (
                    telemetry.state == PrinterState.IDLE or (telemetry.state == PrinterState.PRINTING and not matches(job, telemetry))):
                self._update(job["id"], "uncertain", "Wydruk został przerwany lub drukarka wykonuje inne zadanie. Sprawdź jej stan.")
            if job["state"] == "awaitingStart" and now - _date(job.get("startRequestedAt")) > 60:
                self._update(job["id"], "uncertain", "Brak potwierdzenia startu. Sprawdź drukarkę. Polecenie nie będzie automatycznie ponawiane.")
        self._start_armed()
        self._dispatch()


def shared(app: Any) -> FarmStore:
    """The one library the Farm window and the control panel both use, so they never write index.json
    over each other."""
    if getattr(app, "farm", None) is None:
        from gi.repository import GLib  # type: ignore
        app.farm = FarmStore(app, on_main=lambda job: GLib.idle_add(lambda: (job(), False)[1]))
    return app.farm
