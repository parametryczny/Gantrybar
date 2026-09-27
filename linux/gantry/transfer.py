from __future__ import annotations

"""Sends a sliced file to a printer that takes plain HTTP uploads, and starts it: Klipper (Moonraker),
PrusaLink and OctoPrint. Bambu Lab goes over FTPS instead (farm.upload). Uploading never starts a print
by itself; ``start`` is a separate, explicit call. Mirrors macOS PrinterFileTransfer.

No GTK: the requests are built by pure functions, so they are unit-tested headless.
"""

import http.client
import json
import urllib.parse
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from . import i18n
from .core import PrinterKind

CHUNK = 256 * 1024


class TransferError(Exception):
    pass


@dataclass
class TransferRequest:
    method: str
    url: str
    headers: dict[str, str] = field(default_factory=dict)
    body: bytes = b""


def supports(kind: Any) -> bool:
    return kind in (PrinterKind.KLIPPER, PrinterKind.PRUSA, PrinterKind.OCTOPRINT)


def accepts(kind: Any, extension: str) -> bool:
    """File extensions a printer prints from the library: Bambu takes sliced 3MF projects, the others
    G-code, and PrusaLink Prusa's binary G-code too."""
    value = extension.lower().lstrip(".")
    if value == "3mf":
        return kind == PrinterKind.BAMBU
    if value in ("gcode", "gco", "g"):
        return supports(kind)
    if value == "bgcode":
        return kind == PrinterKind.PRUSA
    return False


def _base(printer: Any) -> str:
    host = str(printer.host).strip()
    if not host or any(character in host for character in "/?#@ "):
        raise TransferError(i18n.t("The printer address is not valid."))
    port = int(getattr(printer, "port", 0) or printer.kind.default_port)
    return f"http://{host}:{port}"


def _multipart(url: str, content: bytes, remote_name: str, fields: dict[str, str]) -> TransferRequest:
    boundary = f"gantry-{uuid.uuid4()}"
    parts: list[bytes] = []
    for name, value in sorted(fields.items()):
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    safe = remote_name.replace('"', "")
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{safe}"\r\n'
                 "Content-Type: application/octet-stream\r\n\r\n".encode())
    parts.append(content)
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    return TransferRequest("POST", url, {"Content-Type": f"multipart/form-data; boundary={boundary}"}, b"".join(parts))


def upload_request(printer: Any, api_key: str | None, content: bytes, remote_name: str) -> TransferRequest:
    base = _base(printer)
    if printer.kind == PrinterKind.KLIPPER:
        request = _multipart(base + "/server/files/upload", content, remote_name, {"root": "gcodes"})
    elif printer.kind == PrinterKind.OCTOPRINT:
        request = _multipart(base + "/api/files/local", content, remote_name, {"select": "false", "print": "false"})
    elif printer.kind == PrinterKind.PRUSA:
        request = TransferRequest("PUT", base + "/api/v1/files/usb/" + urllib.parse.quote(remote_name),
                                  {"Content-Type": "application/octet-stream", "Print-After-Upload": "?0",
                                   "Overwrite-File": "?1"}, content)
    else:
        raise TransferError(i18n.t("This printer cannot receive files from Gantry."))
    if api_key:
        request.headers["X-Api-Key"] = api_key
    return request


def start_request(printer: Any, api_key: str | None, remote_name: str) -> TransferRequest:
    base = _base(printer)
    if printer.kind == PrinterKind.KLIPPER:
        request = TransferRequest("POST", base + "/printer/print/start?" + urllib.parse.urlencode({"filename": remote_name}))
    elif printer.kind == PrinterKind.OCTOPRINT:
        request = TransferRequest("POST", base + "/api/files/local/" + urllib.parse.quote(remote_name),
                                  {"Content-Type": "application/json"},
                                  json.dumps({"command": "select", "print": True}).encode())
    elif printer.kind == PrinterKind.PRUSA:
        request = TransferRequest("POST", base + "/api/v1/files/usb/" + urllib.parse.quote(remote_name))
    else:
        raise TransferError(i18n.t("This printer cannot receive files from Gantry."))
    if api_key:
        request.headers["X-Api-Key"] = api_key
    return request


def send(request: TransferRequest, progress: Callable[[float], None] = lambda _v: None,
         cancelled: Callable[[], bool] = lambda: False, timeout: float = 600) -> None:
    parts = urllib.parse.urlsplit(request.url)
    connection = http.client.HTTPConnection(parts.hostname or "", parts.port or 80, timeout=timeout)
    try:
        path = parts.path + (f"?{parts.query}" if parts.query else "")
        connection.putrequest(request.method, path)
        for name, value in request.headers.items():
            connection.putheader(name, value)
        connection.putheader("Content-Length", str(len(request.body)))
        connection.endheaders()
        total = max(1, len(request.body))
        for offset in range(0, len(request.body), CHUNK):
            if cancelled():
                raise TransferError("cancelled")
            connection.send(request.body[offset:offset + CHUNK])
            progress(min(1.0, (offset + CHUNK) / total))
        response = connection.getresponse()
        detail = response.read(200).decode("utf-8", "replace").strip()
    except OSError as error:
        raise TransferError(str(error)) from error
    finally:
        connection.close()
    if response.status in (401, 403):
        raise TransferError(i18n.t("The printer refused the API key."))
    if not 200 <= response.status < 300:
        message = i18n.t("The printer answered with HTTP {0}.").format(response.status)
        raise TransferError(message + (" " + detail if detail else ""))
    progress(1.0)


def upload(printer: Any, api_key: str | None, local: Path, remote_name: str,
           progress: Callable[[float], None], cancelled: Callable[[], bool]) -> None:
    send(upload_request(printer, api_key, Path(local).read_bytes(), remote_name), progress, cancelled)


def start(printer: Any, api_key: str | None, remote_name: str) -> None:
    send(start_request(printer, api_key, remote_name), timeout=15)
