from __future__ import annotations

import socket
import threading
import time
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from .core import PrinterKind, PrinterState


class DiagnosticsDialog(Gtk.Dialog):
    def __init__(self, app: Any) -> None:
        pl = app.language == "pl"
        super().__init__(title="Centrum diagnostyczne" if pl else "Diagnostic Center",
                         transient_for=app.window, modal=False)
        self.app, self.pl = app, pl
        self.set_default_size(500, 520)
        self.add_button("Zamknij" if pl else "Close", Gtk.ResponseType.CLOSE)
        self.connect("response", lambda dialog, _response: dialog.destroy())
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.get_style_context().add_class("settings-root")
        self.status = Gtk.Label(label="", xalign=0, wrap=True)
        self.status.get_style_context().add_class("settings-hint")
        run = Gtk.Button(label="Uruchom wszystkie testy" if pl else "Run all tests")
        run.connect("clicked", lambda button: self._run(button))
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        scroll = Gtk.ScrolledWindow(); scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.results)
        root.pack_start(self.status, False, False, 0); root.pack_start(run, False, False, 0)
        root.pack_start(scroll, True, True, 0)
        self.get_content_area().pack_start(root, True, True, 0)

    def present(self) -> None:
        self.show_all(); super().present()

    def _run(self, button: Gtk.Button) -> None:
        button.set_sensitive(False)
        self.status.set_text("Testuję…" if self.pl else "Testing…")
        threading.Thread(target=lambda: GLib.idle_add(self._done, button, self._collect()), daemon=True).start()

    @staticmethod
    def _probe(host: str, port: int) -> tuple[bool, float | None, str | None]:
        start = time.monotonic()
        try:
            with socket.create_connection((host, port), timeout=3):
                return True, (time.monotonic() - start) * 1000, None
        except OSError as error:
            return False, None, str(error)

    def _collect(self) -> list[tuple[str, list[str]]]:
        rows: list[tuple[str, list[str]]] = []
        for printer in self.app.printers:
            ok, latency, error = self._probe(printer.host, printer.port)
            if latency is None: quality = "—"
            elif latency < 50: quality = "bardzo dobra" if self.pl else "excellent"
            elif latency < 150: quality = "dobra" if self.pl else "good"
            elif latency < 400: quality = "słaba" if self.pl else "poor"
            else: quality = "bardzo słaba" if self.pl else "very poor"
            tel = self.app.telemetry.get(printer.serial)
            mqtt_ok = bool(tel and tel.state != PrinterState.OFFLINE)
            camera_port = (6000 if printer.kind == PrinterKind.BAMBU else
                           3031 if printer.kind == PrinterKind.ELEGOO_CC1 else
                           18088 if printer.kind == PrinterKind.ANYCUBIC_KOBRA_S1 else
                           8080 if printer.kind == PrinterKind.ELEGOO_CC2 else printer.port)
            cam_ok, cam_latency, cam_error = self._probe(printer.host, camera_port)
            try:
                secret = self.app.secrets.get(printer.serial)
                secret_ok = bool(secret) or printer.kind in (PrinterKind.ELEGOO_CC1, PrinterKind.SNAPMAKER,
                                                              PrinterKind.ANYCUBIC_KOBRA_S1)
                secret_error = None
            except Exception as value:
                secret_ok, secret_error = False, str(value)
            reason = self.app.connection_reasons.get(printer.serial, "—")
            lines = [
                f"{'✓' if ok else '×'}  " + ("Sieć" if self.pl else "Network") + (f" · {latency:.0f} ms · {quality}" if latency is not None else f" · {error}"),
                f"{'✓' if mqtt_ok else '×'}  MQTT · " + (("telemetria aktywna" if self.pl else "telemetry active") if mqtt_ok else reason),
                f"{'✓' if cam_ok else '×'}  " + ("Kamera" if self.pl else "Camera") + (f" · {cam_latency:.0f} ms" if cam_latency is not None else f" · {cam_error}"),
                f"{'✓' if secret_ok else '×'}  " + ("Magazyn sekretów" if self.pl else "Secret storage") + (" · OK" if secret_ok else f" · {secret_error or 'brak danych'}"),
            ]
            rows.append((printer.name, lines))
        return rows

    def _done(self, button: Gtk.Button, rows: list[tuple[str, list[str]]]) -> bool:
        for child in self.results.get_children(): self.results.remove(child)
        if not rows:
            self.results.pack_start(Gtk.Label(label="Brak drukarek." if self.pl else "No printers."), False, False, 0)
        for name, lines in rows:
            card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
            card.get_style_context().add_class("settings-card")
            title = Gtk.Label(label=name, xalign=0); title.get_style_context().add_class("status")
            card.pack_start(title, False, False, 0)
            for text in lines:
                label = Gtk.Label(label=text, xalign=0, wrap=True); label.get_style_context().add_class("settings-hint")
                card.pack_start(label, False, False, 0)
            self.results.pack_start(card, False, False, 0)
        self.results.show_all(); button.set_sensitive(True)
        self.status.set_text("Testy zakończone." if self.pl else "Tests complete.")
        return False
