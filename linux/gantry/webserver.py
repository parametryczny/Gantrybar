"""A tiny, read-only web dashboard for the fleet, served on the LAN so it can be viewed from a phone.

View-only, local network only, no cloud. Built on the stdlib http.server (no extra dependency). The
page polls /api/printers every 2s. Every endpoint is read-only: the server accepts nothing that
changes state.
"""

from __future__ import annotations

import json
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

PORT = 8787


def _printer_dict(printer: Any, telemetry: Any, physical_spools: Any = None,
                  filament_store: Any = None, spoolbase_enabled: bool = True,
                  show_spool_grams: bool = True) -> dict[str, Any]:
    active = getattr(telemetry.state, "value", "") in {"printing", "paused"}
    groups = []
    for group_index, group in enumerate(telemetry.filament_groups):
        slots = []
        for slot_index, slot in enumerate(group.slots):
            present = getattr(slot, "present", False)
            assigned = None
            if spoolbase_enabled and physical_spools is not None:
                from .physicalspool import location_for
                assigned = physical_spools.spool_at(
                    location_for(printer.serial, group.external, group_index, slot_index))
            definition = None
            if assigned is not None and filament_store is not None:
                definition = next((item for item in filament_store.filaments
                                   if item.id == assigned.get("filamentDefinitionID")), None)
            color = (str(definition.colorHex) if definition is not None else
                     (slot.color or "8E8E93")).lstrip("#")[:6]
            material = slot.material if present else (
                (definition.type or definition.name) if definition is not None else "")
            percent = (physical_spools.percent(assigned) if assigned is not None else slot.remaining)
            raw_grams = assigned.get("remainingWeightGrams") if assigned is not None else getattr(slot, "remaining_weight_g", None)
            grams = int(raw_grams) if show_spool_grams and raw_grams is not None else None
            slots.append({
                "label": slot.label,
                "material": material,
                "colorHex": color,
                "percent": percent,
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
        "protocol": {
            "bambu": "MQTT", "klipper": "KLIPPER", "prusa": "PRUSALINK", "snapmaker": "HTTP",
            "elegoo_cc1": "SDCP", "elegoo_cc2": "MQTT LAN", "anycubic_kobra_s1": "MQTT LAN",
        }.get(getattr(getattr(printer, "kind", None), "value", ""), "LAN"),
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


def fleet_snapshot(printers: list[Any], telemetry: dict[str, Any], physical_spools: Any = None,
                   filament_store: Any = None, spoolbase_enabled: bool = True,
                   show_spool_grams: bool = True) -> dict[str, Any]:
    """Pure builder (unit-testable): the fleet payload the dashboard JS renders."""
    out = []
    for printer in printers:
        tel = telemetry.get(printer.serial)
        if tel is None:
            continue
        out.append(_printer_dict(printer, tel, physical_spools, filament_store, spoolbase_enabled,
                                 show_spool_grams))
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
        self._httpd: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._httpd is not None:
            return
        app = self.app

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

            def do_GET(self) -> None:
                if self.path.startswith("/api/printers"):
                    data = fleet_snapshot(
                        list(app.printers), dict(app.telemetry),
                        getattr(app, "physical_spools", None), getattr(app, "filament_store", None),
                        bool(app.config.data.get("spoolbase_enabled", True)),
                        bool(app.config.data.get("card_show_spool_grams", False)))
                    self._send(200, json.dumps(data).encode(), "application/json")
                    return
                self._send(200, WEB_HTML.encode(), "text/html; charset=utf-8")

            def do_POST(self) -> None:
                self._send(404, b"not found", "text/plain")

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


def _load_dashboard_html() -> str:
    """Load the canonical macOS-style dashboard copied into every platform package."""
    candidates = (
        Path(__file__).with_name("data") / "web-dashboard.html",
        Path(__file__).resolve().parents[2] / "Resources" / "web-dashboard.html",
    )
    for path in candidates:
        try:
            return path.read_text(encoding="utf-8")
        except OSError:
            continue
    return HTML


WEB_HTML = _load_dashboard_html()
