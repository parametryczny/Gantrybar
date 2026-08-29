"""A tiny, read-only web dashboard for the fleet, served on the LAN so it can be viewed from a phone.

View-only, local network only, no cloud. Built on the stdlib http.server (no extra dependency). The
page polls /api/printers every 2s. The /api/sync endpoint (two-way sync) is wired in when a SyncService
is attached; without one it returns 404, so the web view works on its own.
"""

from __future__ import annotations

import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

PORT = 8787


def _printer_dict(printer: Any, telemetry: Any) -> dict[str, Any]:
    active = getattr(telemetry.state, "value", "") in {"printing", "paused"}
    groups = []
    for group in telemetry.filament_groups:
        slots = []
        for slot in group.slots:
            present = getattr(slot, "present", False)
            color = (slot.color or "8E8E93").lstrip("#")[:6] if slot.color else "8E8E93"
            grams = int(slot.remaining_weight_g) if getattr(slot, "remaining_weight_g", None) else None
            slots.append({
                "label": slot.label,
                "material": slot.material if present else "",
                "colorHex": color,
                "percent": slot.remaining,
                "grams": grams,
                "active": slot.active,
            })
        groups.append({
            "name": group.display_name,
            "external": group.external,
            "humidity": group.humidity,
            "temp": group.temperature,
            "slots": slots,
        })
    return {
        "name": printer.name,
        "state": getattr(telemetry.state, "value", "offline"),
        "progress": telemetry.progress,
        "remainingMinutes": telemetry.remaining_minutes,
        "job": (telemetry.job_name or "") if active else "",
        "nozzle": telemetry.nozzle,
        "bed": telemetry.bed,
        "chamber": telemetry.chamber,
        "layer": telemetry.current_layer,
        "totalLayers": telemetry.total_layers,
        "groups": groups,
    }


def fleet_snapshot(printers: list[Any], telemetry: dict[str, Any]) -> dict[str, Any]:
    """Pure builder (unit-testable): the fleet payload the dashboard JS renders."""
    out = []
    for printer in printers:
        tel = telemetry.get(printer.serial)
        if tel is None:
            continue
        out.append(_printer_dict(printer, tel))
    return {"printers": out}


def local_ipv4() -> str | None:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            sock.connect(("192.0.2.1", 80))   # TEST-NET, no packet actually sent
            return sock.getsockname()[0]
        finally:
            sock.close()
    except Exception:
        return None


class GantryWebServer:
    def __init__(self, app: Any) -> None:
        self.app = app
        self.sync: Any = None
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._httpd is not None:
            return
        app = self.app
        server = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args: Any) -> None:
                pass  # keep the console quiet

            def _send(self, status: int, body: bytes, ctype: str) -> None:
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except Exception:
                    pass

            def _auth(self) -> str | None:
                return self.headers.get("Authorization")

            def do_GET(self) -> None:
                if self.path.startswith("/api/sync"):
                    if server.sync is None or not server.sync.authorize(self._auth()):
                        self._send(401, b'{"error":"unauthorized"}', "application/json")
                        return
                    self._send(200, json.dumps(server.sync.local_snapshot()).encode(), "application/json")
                    return
                if self.path.startswith("/api/printers"):
                    data = fleet_snapshot(list(app.printers), dict(app.telemetry))
                    self._send(200, json.dumps(data).encode(), "application/json")
                    return
                self._send(200, HTML.encode(), "text/html; charset=utf-8")

            def do_POST(self) -> None:
                if not self.path.startswith("/api/sync"):
                    self._send(404, b"not found", "text/plain")
                    return
                if server.sync is None or not server.sync.authorize(self._auth()):
                    self._send(401, b'{"error":"unauthorized"}', "application/json")
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(length) if length else b""
                    snapshot = json.loads(body.decode()) if body else {}
                    server.sync.apply_remote(snapshot)
                    self._send(200, b'{"ok":true}', "application/json")
                except Exception:
                    self._send(400, b'{"error":"bad snapshot"}', "application/json")

        try:
            self._httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
        except Exception:
            self._httpd = None
            return
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._httpd is not None:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            except Exception:
                pass
        self._httpd = None
        self._thread = None


HTML = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Gantry</title>
<style>
:root{--bg:#0c0d0e;--card:#151719;--line:rgba(255,255,255,.09);--text:#f2f3f1;--sec:#a7aaa6;--muted:#6d716e;--noz:#ff8a61;--bed:#efbd5f;--cham:#bba5ef}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font-family:-apple-system,system-ui,'Segoe UI',sans-serif;padding:14px}
h1{font-size:18px;font-weight:800;letter-spacing:.5px;margin:0 0 2px}
.sub{color:var(--sec);font-size:12px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px}
.card{background:rgba(21,23,25,.6);border:1px solid var(--line);border-radius:16px;padding:12px}
.top{display:flex;align-items:center;gap:8px}.name{font-weight:600;font-size:14px}
.pill{font-size:9px;color:var(--sec);border:1px solid var(--line);border-radius:5px;padding:2px 6px}
.status{color:var(--sec);font-size:11px;margin:6px 0 2px}.pct{font-size:26px;font-weight:600}
.rule{height:1px;background:var(--line);margin:8px 0}.temps{display:flex;gap:6px}
.temp{flex:1}.temp .l{font-size:7px;color:var(--sec);letter-spacing:.5px}.temp .v{font-size:15px;font-weight:600}
.ams{display:flex;gap:10px;flex-wrap:wrap;margin-top:2px}.grp{flex:1;min-width:120px}.grp .h{font-size:10px;font-weight:600}
.slots{display:flex;gap:5px;margin-top:4px}.slot{flex:1;text-align:center}
.sw{height:22px;border-radius:6px;border:1px solid var(--line);display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:700}
.mat{font-size:10px;font-weight:600;margin-top:2px}.off{opacity:.45}.foot{color:var(--muted);text-align:center;font-size:11px;margin-top:16px}
</style></head><body>
<h1>GANTRY</h1><div class="sub" id="sub">Ładowanie…</div>
<div class="grid" id="grid"></div>
<div class="foot">Podgląd na żywo • tylko sieć lokalna</div>
<script>
const NOZ='var(--noz)',BED='var(--bed)',CHAM='var(--cham)';
function ink(hex){hex=(hex||'').replace('#','');const r=parseInt(hex.substr(0,2),16),g=parseInt(hex.substr(2,2),16),b=parseInt(hex.substr(4,2),16);return (0.299*r+0.587*g+0.114*b)/255>0.58?'#151719':'#fff'}
function temp(v,c){return v==null?'<span class="v" style="color:var(--muted)">—</span>':'<span class="v" style="color:'+c+'">'+Math.round(v)+'°</span>'}
function render(d){const ps=(d&&d.printers)||[];document.getElementById('sub').textContent=ps.length+' drukarek • '+ps.filter(p=>p.state==='printing').length+' pracuje';
document.getElementById('grid').innerHTML=ps.map(p=>{const temps='<div class="temps">'+'<div class="temp"><div class="l">DYSZA</div>'+temp(p.nozzle,NOZ)+'</div>'+'<div class="temp"><div class="l">STÓŁ</div>'+temp(p.bed,BED)+'</div>'+(p.chamber!=null?'<div class="temp"><div class="l">KOMORA</div>'+temp(p.chamber,CHAM)+'</div>':'')+'</div>';
const ams=(p.groups||[]).map(g=>'<div class="grp"><div class="h">'+g.name+'</div><div class="slots">'+g.slots.map(s=>{const pct=s.percent==null?'':s.percent+'%';const col=s.material?('#'+(s.colorHex||'8E8E93')):'transparent';const style=s.material?('background:'+col+';color:'+ink(s.colorHex)):'';return '<div class="slot"><div class="sw" style="'+style+'">'+pct+'</div><div class="mat">'+(s.material||'—')+'</div></div>'}).join('')+'</div></div>').join('');
const off=p.state==='offline';return '<div class="card'+(off?' off':'')+'"><div class="top"><span class="name">'+p.name+'</span><span class="pill">'+p.state+'</span></div>'+'<div class="status">'+(p.job||'')+'</div><div class="pct">'+p.progress+'%</div>'+'<div class="rule"></div>'+temps+(ams?'<div class="rule"></div><div class="ams">'+ams+'</div>':'')+'</div>';}).join('');}
function poll(){fetch('/api/printers').then(r=>r.json()).then(render).catch(()=>{document.getElementById('sub').textContent='Brak połączenia z Gantry';});}
poll();setInterval(poll,2000);
</script></body></html>"""
