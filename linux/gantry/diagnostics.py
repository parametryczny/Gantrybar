"""Fleet connectivity check, the GTK counterpart of the macOS/Windows Diagnostic Center.

Reports two things per printer: whether its service port answers (with latency and a quality
grade) and whether Gantry currently holds a live connection to it. The worker thread posts a
result after every printer instead of only at the end, so the dialog names the printer under
test and moves a progress bar rather than sitting on a silent "Testing...".
"""
from __future__ import annotations

import socket
import threading
import time
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from .core import PrinterState

# Hard ceiling per printer, so one unreachable host cannot stall the whole run.
PER_PRINTER_LIMIT = 3


class DiagnosticsDialog(Gtk.Dialog):
    def __init__(self, app: Any) -> None:
        pl = app.language == "pl"
        super().__init__(title="Centrum diagnostyczne" if pl else "Diagnostic Center",
                         transient_for=app.window, modal=False)
        self.app, self.pl = app, pl
        self._alive = True
        self.set_default_size(500, 520)
        self.add_button("Zamknij" if pl else "Close", Gtk.ResponseType.CLOSE)
        self.connect("response", lambda dialog, _response: dialog.destroy())
        self.connect("destroy", self._on_destroy)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.get_style_context().add_class("settings-root")
        self.status = Gtk.Label(label="Sprawdź łączność wszystkich drukarek." if pl
                                else "Check connectivity for every printer.", xalign=0, wrap=True)
        self.status.get_style_context().add_class("settings-hint")
        self.progress = Gtk.ProgressBar()
        self.progress.set_no_show_all(True)
        self.run_button = Gtk.Button(label="Uruchom wszystkie testy" if pl else "Run all tests")
        self.run_button.connect("clicked", lambda _button: self._run())
        self.results = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.results)
        root.pack_start(self.status, False, False, 0)
        root.pack_start(self.progress, False, False, 0)
        root.pack_start(self.run_button, False, False, 0)
        root.pack_start(scroll, True, True, 0)
        self.get_content_area().pack_start(root, True, True, 0)

    def present(self) -> None:
        self.show_all()
        self.progress.hide()
        super().present()

    def _on_destroy(self, *_args: object) -> None:
        self._alive = False

    # ---- run -----------------------------------------------------------------

    def _run(self) -> None:
        self.run_button.set_sensitive(False)
        for child in self.results.get_children():
            self.results.remove(child)
        printers = list(self.app.printers)
        if not printers:
            self.results.pack_start(Gtk.Label(label="Brak drukarek." if self.pl else "No printers.",
                                              xalign=0), False, False, 0)
            self.results.show_all()
            self.status.set_text("Testy zakończone." if self.pl else "Tests complete.")
            self.run_button.set_sensitive(True)
            return
        self.progress.set_fraction(0)
        self.progress.show()
        threading.Thread(target=self._worker, args=(printers,), daemon=True).start()

    def _worker(self, printers: list[Any]) -> None:
        started = time.monotonic()
        for index, printer in enumerate(printers):
            GLib.idle_add(self._set_current, index, len(printers), printer.name)
            ok, latency, error = self._probe(printer.host, printer.port)
            GLib.idle_add(self._add_result, index, len(printers), printer, ok, latency, error)
        GLib.idle_add(self._finish, len(printers), time.monotonic() - started)

    @staticmethod
    def _probe(host: str, port: int) -> tuple[bool, float | None, str | None]:
        start = time.monotonic()
        try:
            with socket.create_connection((host, port), timeout=PER_PRINTER_LIMIT):
                return True, (time.monotonic() - start) * 1000, None
        except OSError as error:
            return False, None, str(error)

    # ---- ui ------------------------------------------------------------------

    def _set_current(self, index: int, total: int, name: str) -> bool:
        if not self._alive:
            return False
        self.status.set_text((f"Testuję {index + 1} z {total}: {name}" if self.pl
                              else f"Testing {index + 1} of {total}: {name}"))
        return False

    def _add_result(self, index: int, total: int, printer: Any,
                    ok: bool, latency: float | None, error: str | None) -> bool:
        if not self._alive:
            return False
        if latency is None:
            quality = "—"
        elif latency < 50:
            quality = "bardzo dobra" if self.pl else "excellent"
        elif latency < 150:
            quality = "dobra" if self.pl else "good"
        elif latency < 400:
            quality = "słaba" if self.pl else "poor"
        else:
            quality = "bardzo słaba" if self.pl else "very poor"
        tel = self.app.telemetry.get(printer.serial)
        connected = bool(tel and tel.state != PrinterState.OFFLINE)
        reason = self.app.connection_reasons.get(printer.serial, "—")
        lines = [
            f"{'✓' if ok else '×'}  " + ("Sieć" if self.pl else "Network")
            + (f" · {latency:.0f} ms · {quality}" if latency is not None else f" · {error}"),
            f"{'✓' if connected else '×'}  "
            + ("Połączenie z drukarką" if self.pl else "Printer connection") + " · "
            + (("telemetria aktywna" if self.pl else "telemetry active") if connected else reason),
        ]
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        card.get_style_context().add_class("settings-card")
        title = Gtk.Label(label=printer.name, xalign=0)
        title.get_style_context().add_class("status")
        card.pack_start(title, False, False, 0)
        for text in lines:
            label = Gtk.Label(label=text, xalign=0, wrap=True)
            label.get_style_context().add_class("settings-hint")
            card.pack_start(label, False, False, 0)
        self.results.pack_start(card, False, False, 0)
        self.results.show_all()
        self.progress.set_fraction(float(index + 1) / float(total))
        return False

    def _finish(self, total: int, seconds: float) -> bool:
        if not self._alive:
            return False
        self.status.set_text((f"Testy zakończone: {total} drukarek w {seconds:.1f} s" if self.pl
                              else f"Tests complete: {total} printers in {seconds:.1f} s"))
        self.progress.hide()
        self.run_button.set_sensitive(True)
        return False
