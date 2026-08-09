from __future__ import annotations

import html
import http.cookies
import secrets
import ssl
import subprocess
import threading
import time
import urllib.parse
from collections import defaultdict
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from .csvimport import parse_printer_csv, template_csv
from .storage import APP_DIR


AddPrinter = Callable[[dict[str, Any]], tuple[bool, str]]
RemovePrinter = Callable[[str], tuple[bool, str]]
ImportPrinters = Callable[[list[dict[str, Any]]], tuple[bool, str]]
Snapshot = Callable[[], dict[str, Any]]


def pairing_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def parse_form(body: bytes) -> dict[str, str]:
    values = urllib.parse.parse_qs(body.decode("utf-8", errors="replace"), keep_blank_values=True)
    return {key: items[-1] for key, items in values.items() if items}


def validate_printer_form(values: dict[str, str]) -> tuple[dict[str, Any] | None, str]:
    kind = values.get("kind", "bambu").strip().lower() or "bambu"
    name = values.get("name", "").strip()
    host = values.get("host", "").strip()
    serial = values.get("serial", "").strip()
    code = values.get("code", "").strip()
    try:
        port = int(values.get("port") or {"bambu": 8883, "klipper": 7125, "prusa": 80}.get(kind, 0))
    except ValueError:
        port = 0
    if kind not in {"bambu", "klipper", "prusa"}:
        return None, "Wybierz obsługiwany typ drukarki."
    if kind != "bambu" and not serial:
        serial = f"{kind}-{host}-{port}"
    if not name or not host or not serial or (kind in {"bambu", "prusa"} and not code) or not 1 <= port <= 65535:
        return None, "Uzupełnij dane wymagane dla wybranego typu drukarki i poprawny port."
    if any(character.isspace() for character in host) or len(serial) > 128:
        return None, "Adres lub numer seryjny ma niepoprawny format."
    return {"kind": kind, "name": name, "host": host, "serial": serial, "code": code, "port": port}, ""


class WebConfigServer:
    def __init__(self, snapshot: Snapshot, add_printer: AddPrinter, remove_printer: RemovePrinter,
                 import_printers: ImportPrinters,
                 host: str = "0.0.0.0", port: int = 8443) -> None:
        self.snapshot = snapshot
        self.add_printer = add_printer
        self.remove_printer = remove_printer
        self.import_printers = import_printers
        self.host = host
        self.port = port
        self.code = pairing_code()
        self.sessions: dict[str, float] = {}
        self.failures: dict[str, list[float]] = defaultdict(list)
        self.httpd: ThreadingHTTPServer | None = None
        self.thread: threading.Thread | None = None
        self.error: str | None = None
        hostname = socket_hostname()
        self.public_host = f"{hostname}.local" if not hostname.endswith(".local") else hostname

    @property
    def url(self) -> str:
        return f"https://{self.public_host}:{self.port}"

    def start(self) -> None:
        try:
            certificate, key = ensure_certificate()
            owner = self

            class Handler(ConfigHandler):
                server_owner = owner

            server = ThreadingHTTPServer((self.host, self.port), Handler)
            self.port = int(server.server_address[1])
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(certificate, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            self.httpd = server
            self.thread = threading.Thread(target=server.serve_forever, name="gantry-web-config", daemon=True)
            self.thread.start()
        except (OSError, subprocess.SubprocessError, ssl.SSLError) as error:
            self.error = str(error)

    def stop(self) -> None:
        if self.httpd:
            self.httpd.shutdown()
            self.httpd.server_close()
            self.httpd = None

    def new_session(self) -> str:
        token = secrets.token_urlsafe(32)
        self.sessions[token] = time.time() + 24 * 3600
        return token

    def valid_session(self, token: str | None) -> bool:
        if not token:
            return False
        expires = self.sessions.get(token, 0)
        if expires <= time.time():
            self.sessions.pop(token, None)
            return False
        return True

    def login_allowed(self, address: str) -> bool:
        now = time.time()
        self.failures[address] = [value for value in self.failures[address] if now - value < 60]
        return len(self.failures[address]) < 5

    def failed_login(self, address: str) -> None:
        self.failures[address].append(time.time())


class ConfigHandler(BaseHTTPRequestHandler):
    server_owner: WebConfigServer

    def log_message(self, _format: str, *_arguments: object) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/favicon.ico":
            self.send_response(204); self.end_headers(); return
        token = self._session_token()
        if not self.server_owner.valid_session(token):
            self._html(login_page(), status=200); return
        if self.path == "/template.csv":
            self._download("Gantry-printers-template.csv", template_csv().encode("utf-8-sig"), "text/csv; charset=utf-8")
            return
        self._html(config_page(self.server_owner.snapshot(), token or ""))

    def do_POST(self) -> None:
        length = min(int(self.headers.get("Content-Length", "0") or 0), 524_288)
        form = parse_form(self.rfile.read(length))
        address = self.client_address[0]
        if self.path == "/login":
            if not self.server_owner.login_allowed(address):
                self._html(login_page("Za dużo prób. Odczekaj minutę."), status=429); return
            supplied = form.get("code", "").replace(" ", "")
            if not secrets.compare_digest(supplied, self.server_owner.code):
                self.server_owner.failed_login(address)
                self._html(login_page("Niepoprawny kod parowania."), status=403); return
            token = self.server_owner.new_session()
            self.send_response(303)
            self.send_header("Location", "/")
            self.send_header("Set-Cookie", f"bb_session={token}; Path=/; Max-Age=86400; HttpOnly; SameSite=Strict; Secure")
            self.end_headers(); return

        token = self._session_token()
        if not self.server_owner.valid_session(token) or not secrets.compare_digest(form.get("csrf", ""), token or ""):
            self._html(login_page("Sesja wygasła. Sparuj urządzenie ponownie."), status=403); return
        if self.path == "/add":
            values, error = validate_printer_form(form)
            ok, message = self.server_owner.add_printer(values) if values else (False, error)
            self._html(config_page(self.server_owner.snapshot(), token or "", message, ok), status=200 if ok else 400); return
        if self.path == "/remove":
            ok, message = self.server_owner.remove_printer(form.get("serial", ""))
            self._html(config_page(self.server_owner.snapshot(), token or "", message, ok), status=200 if ok else 400); return
        if self.path == "/import":
            try:
                records = parse_printer_csv(form.get("csv", ""))
                ok, message = self.server_owner.import_printers(records)
            except ValueError as error:
                ok, message = False, str(error)
            self._html(config_page(self.server_owner.snapshot(), token or "", message, ok), status=200 if ok else 400); return
        self._html("Nie znaleziono", status=404)

    def _session_token(self) -> str | None:
        cookie = http.cookies.SimpleCookie(self.headers.get("Cookie", ""))
        value = cookie.get("bb_session")
        return value.value if value else None

    def _html(self, body: str, status: int = 200) -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(data)

    def _download(self, filename: str, data: bytes, content_type: str) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers(); self.wfile.write(data)


def ensure_certificate() -> tuple[str, str]:
    APP_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    certificate = APP_DIR / "web-config.crt"
    key = APP_DIR / "web-config.key"
    if certificate.exists() and key.exists():
        return str(certificate), str(key)
    hostname = socket_hostname()
    names = f"DNS:{hostname},DNS:{hostname}.local,DNS:gantry.local,DNS:localhost,IP:127.0.0.1"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
        "-days", "825", "-subj", f"/CN={hostname}.local",
        "-addext", f"subjectAltName={names}",
        "-keyout", str(key), "-out", str(certificate),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=30)
    key.chmod(0o600); certificate.chmod(0o644)
    return str(certificate), str(key)


def socket_hostname() -> str:
    import socket
    return socket.gethostname().strip().lower() or "gantry"


def page_shell(content: str, title: str = "Gantry Workshop") -> str:
    refresh = ("<script>setTimeout(()=>{if(!['INPUT','SELECT','TEXTAREA'].includes(document.activeElement.tagName))"
               "location.reload()},15000)</script>" if 'printer-grid' in content else "")
    return f"""<!doctype html><html lang=\"pl\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">{refresh}<title>{html.escape(title)}</title><style>
    :root{{color-scheme:dark;font-family:system-ui,sans-serif;background:#161719;color:#f4f4f5}}*{{box-sizing:border-box}}body{{margin:0;padding:28px 18px}}main{{max-width:900px;margin:auto}}header{{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}}h1{{font-size:25px;margin:0;letter-spacing:.08em}}h2{{font-size:18px;margin:26px 0 12px}}small,.muted{{color:#a8a8ad}}.panel{{background:#26272a;border:1px solid #424348;border-radius:16px;padding:18px;margin-bottom:14px}}label{{display:grid;gap:6px;color:#b4b4ba;font-size:13px}}input,select{{width:100%;padding:11px;border:1px solid #4a4b50;border-radius:9px;background:#1d1e20;color:#fff;font:inherit}}button,.button{{display:inline-block;padding:11px 15px;border:0;border-radius:9px;background:#f4f4f5;color:#171719;font:inherit;font-weight:600;text-decoration:none;cursor:pointer}}.secondary{{background:#45464a;color:#fff}}.grid{{display:grid;grid-template-columns:1fr 1fr;gap:12px}}.wide{{grid-column:1/-1}}.printer-grid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}}.printer-card{{background:#202124;border:1px solid #414247;border-radius:13px;padding:14px}}.printer-card.finished{{border-color:#397b5a;background:#1e382d}}.printer-card.error{{border-color:#d64b55;background:#3b2428}}.printer-head{{display:flex;justify-content:space-between;gap:12px}}.printer-head span{{display:grid}}.job,.telemetry{{margin-top:9px;color:#b8b8bd;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}progress{{width:100%;height:7px;margin-top:10px;accent-color:#0a9fff}}.slots{{display:flex;gap:5px;min-height:26px;margin-top:9px}}.slot{{display:grid;place-items:center;min-width:27px;height:25px;padding:0 5px;border-radius:7px;background:var(--slot);color:#111;font-size:11px;font-style:normal;font-weight:700}}.slot.active{{outline:2px solid #fff}}.remove{{padding:5px 8px;margin-top:10px;background:#45464a;color:#fff;font-size:11px}}.message{{padding:11px 13px;border-radius:9px;background:#493033;color:#ffd9dc;margin-bottom:15px}}.message.ok{{background:#254132;color:#c9f8da}}code{{font-size:18px}}@media(max-width:650px){{.grid,.printer-grid{{grid-template-columns:1fr}}.wide{{grid-column:auto}}}}
    </style><main>{content}</main></html>"""


def login_page(message: str = "") -> str:
    notice = f'<div class="message">{html.escape(message)}</div>' if message else ""
    return page_shell(f"""<header><div><h1>GANTRY</h1><small>Konfiguracja Raspberry Pi</small></div></header>{notice}<section class=\"panel\"><form method=\"post\" action=\"/login\"><label>Kod parowania z ekranu<input name=\"code\" inputmode=\"numeric\" autocomplete=\"one-time-code\" maxlength=\"7\" required autofocus></label><p><button type=\"submit\">Połącz</button></p></form><small>Połączenie jest szyfrowane lokalnym certyfikatem. Przy pierwszym wejściu przeglądarka może poprosić o zaakceptowanie lokalnego certyfikatu Gantry.</small></section>""")


def config_page(snapshot: dict[str, Any], csrf: str, message: str = "", success: bool = False) -> str:
    printers = snapshot.get("printers", [])
    def row(item: dict[str, Any]) -> str:
        state = str(item.get("state", "offline"))
        progress = max(0, min(100, int(item.get("progress") or 0)))
        remaining = item.get("remaining")
        eta = "—" if remaining is None else f"{int(remaining) // 60}h {int(remaining) % 60}m"
        layer = "—" if item.get("layer") is None else f'{item.get("layer")}/{item.get("layers") or "—"}'
        nozzle = "—" if item.get("nozzle") is None else f'{float(item["nozzle"]):.0f}/{float(item.get("nozzle_target") or 0):.0f}°'
        bed = "—" if item.get("bed") is None else f'{float(item["bed"]):.0f}/{float(item.get("bed_target") or 0):.0f}°'
        slots = "".join(
            f'<i class="slot{" active" if slot.get("active") else ""}" style="--slot:#{html.escape(str(slot.get("color", "8e8e93")))}">{html.escape(str(slot.get("label", "")))}</i>'
            for slot in item.get("ams", []) if isinstance(slot, dict)
        )
        return f'''<article class="printer-card {html.escape(state)}"><div class="printer-head"><span><strong>{html.escape(str(item.get("name", "")))}</strong><small>{html.escape(str(item.get("kind", "bambu"))).title()} • {html.escape(state)}</small></span><b>{progress}%</b></div><div class="job">{html.escape(str(item.get("job", "—")))}</div><progress max="100" value="{progress}"></progress><div class="telemetry">◷ {eta}　▤ {layer}　♨ {nozzle}　▣ {bed}</div><div class="slots">{slots}</div><form method="post" action="/remove"><input type="hidden" name="csrf" value="{html.escape(csrf)}"><input type="hidden" name="serial" value="{html.escape(str(item.get("serial", "")))}"><button class="remove" type="submit">Usuń</button></form></article>'''

    rows = "".join(row(item) for item in printers if isinstance(item, dict)) or '<p class="muted">Nie dodano jeszcze drukarek.</p>'
    notice = f'<div class="message{" ok" if success else ""}">{html.escape(message)}</div>' if message else ""
    return page_shell(f"""<header><div><h1>GANTRY</h1><small>{len(printers)} drukarek • panel lokalny</small></div><code>RPi</code></header>{notice}<section class=\"panel\"><h2>Status drukarek</h2><div class=\"printer-grid\">{rows}</div></section><section class=\"panel\"><h2>Import CSV</h2><p class=\"muted\">Pobierz szablon, uzupełnij go na komputerze i wczytaj tutaj. Typy: bambu, klipper, prusa. CSV zawiera kody dostępu — usuń go po imporcie.</p><p><a class=\"button secondary\" href=\"/template.csv\">Pobierz szablon CSV</a></p><form id=\"csv-form\" method=\"post\" action=\"/import\"><input type=\"hidden\" name=\"csrf\" value=\"{html.escape(csrf)}\"><input id=\"csv-file\" type=\"file\" accept=\".csv,text/csv\" required><textarea id=\"csv-content\" name=\"csv\" hidden></textarea><p><button type=\"submit\">Importuj drukarki</button></p></form></section><section class=\"panel\"><h2>Dodaj drukarkę ręcznie</h2><form method=\"post\" action=\"/add\" class=\"grid\"><input type=\"hidden\" name=\"csrf\" value=\"{html.escape(csrf)}\"><label>Typ<select name=\"kind\"><option value=\"bambu\">Bambu Lab</option><option value=\"klipper\">Klipper / Moonraker</option><option value=\"prusa\">Prusa / PrusaLink</option></select></label><label>Nazwa<input name=\"name\" required></label><label>Adres IP / host<input name=\"host\" required></label><label>Numer seryjny (Bambu)<input name=\"serial\"></label><label>Port<input name=\"port\" type=\"number\" min=\"1\" max=\"65535\" placeholder=\"8883 / 7125 / 80\"></label><label class=\"wide\">Kod dostępu / klucz API<input name=\"code\" type=\"password\"></label><div class=\"wide\"><button type=\"submit\">Dodaj i połącz</button></div></form></section><script>const form=document.getElementById('csv-form'),file=document.getElementById('csv-file'),content=document.getElementById('csv-content');form.addEventListener('submit',async event=>{{if(!file.files.length){{event.preventDefault();return}}event.preventDefault();content.value=await file.files[0].text();form.submit()}});</script>""")
