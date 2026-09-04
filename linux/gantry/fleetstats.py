from __future__ import annotations

"""Fleet statistics: one summary across every printer, with export to a text file.

PrinterInsights already collected history, print hours and filament use per printer, but nothing
added them up, so "how much did I print this month" had no answer. Mirrors the macOS panel, including
the caveat about lifetime counters below.

gi is already pinned in app.py.
"""

from datetime import datetime, timedelta, timezone
from typing import Any

from gi.repository import Gtk  # type: ignore

from . import i18n

PERIODS = (7, 30, 365, 0)   # 0 = all time


class FleetStatsDialog(Gtk.Dialog):
    def __init__(self, app: Any) -> None:
        super().__init__(title=i18n.t("Fleet statistics"),
                         transient_for=app.window, modal=True)
        self.app = app
        self.pl = app.language == "pl"
        self.period_days = 30
        self.rendered_text = ""
        self.set_default_size(470, 560)
        self.set_size_request(420, 420)

        self.add_button(i18n.t("Done"), Gtk.ResponseType.OK)
        export = self.add_button(i18n.t("Export to file…"),
                                 Gtk.ResponseType.APPLY)
        export.connect("clicked", self._export)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.get_style_context().add_class("settings-root")

        self.period = Gtk.ComboBoxText()
        for days in PERIODS:
            self.period.append(str(days), self._period_label(days))
        self.period.set_active_id("30")
        self.period.connect("changed", self._period_changed)
        root.pack_start(self.period, False, False, 0)

        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.body)
        root.pack_start(scroll, True, True, 0)
        self.get_content_area().pack_start(root, True, True, 0)

        self._render()
        self.show_all()

    # ------------------------------------------------------------------ data

    def _period_label(self, days: int) -> str:
        if days == 7:
            returni18n.t("last 7 days")
        if days == 30:
            returni18n.t("last 30 days")
        if days == 365:
            returni18n.t("last year")
        returni18n.t("all time")

    def _period_changed(self, combo: Gtk.ComboBoxText) -> None:
        self.period_days = int(combo.get_active_id() or "30")
        self._render()

    def _rows(self) -> list[dict[str, Any]]:
        insights = self.app.insights
        cutoff = (datetime.now(timezone.utc) - timedelta(days=self.period_days)
                  if self.period_days else None)
        rows: list[dict[str, Any]] = []
        for printer in self.app.printers:
            snapshot = insights.snapshot(printer.serial, self.pl)
            history = [item for item in snapshot.get("history", [])
                       if cutoff is None or self._ended(item) >= cutoff]
            # Print hours and grams are lifetime counters, so a period view derives hours from the
            # entries themselves and only shows lifetime filament when no period is applied.
            hours = sum(float(item.get("durationSeconds", 0) or 0) for item in history) / 3600
            rows.append({
                "name": printer.name,
                "prints": len(history),
                "failed": sum(1 for item in history if item.get("result") != "completed"),
                "hours": float(snapshot.get("total_hours", 0) or 0) if not self.period_days else hours,
                "grams": float(snapshot.get("consumed_grams", 0) or 0) if not self.period_days else 0.0,
            })
        return rows

    @staticmethod
    def _ended(item: dict[str, Any]) -> datetime:
        raw = str(item.get("endedAt", ""))
        try:
            value = datetime.fromisoformat(raw)
        except ValueError:
            return datetime.min.replace(tzinfo=timezone.utc)
        return value if value.tzinfo else value.replace(tzinfo=timezone.utc)

    @staticmethod
    def _success(prints: int, failed: int) -> int | None:
        return None if prints == 0 else round((prints - failed) / prints * 100)

    # --------------------------------------------------------------- drawing

    def _render(self) -> None:
        for child in self.body.get_children():
            self.body.remove(child)

        rows = self._rows()
        prints = sum(row["prints"] for row in rows)
        failed = sum(row["failed"] for row in rows)
        hours = sum(row["hours"] for row in rows)
        grams = sum(row["grams"] for row in rows)
        success = self._success(prints, failed)
        success_text = f"{success}%" if success is not None else "—"

        lines = [
            f"{'Okres' if self.pl else 'Period'}: {self._period_label(self.period_days)}",
            (f"{'Wydruki' if self.pl else 'Prints'}: {prints} "
             f"({'nieudane' if self.pl else 'failed'}: {failed})"),
            f"{'Skuteczność' if self.pl else 'Success rate'}: {success_text}",
            f"{'Czas druku' if self.pl else 'Print time'}: {hours:.1f} h",
        ]
        if grams > 0:
            lines.append(f"Filament: {grams / 1000:.2f} kg")

        self.body.pack_start(self._caption(i18n.t("SUMMARY")), False, False, 0)
        self.body.pack_start(self._card(lines), False, False, 0)
        self.body.pack_start(self._caption(i18n.t("BY PRINTER")), False, False, 0)
        if not rows:
            self.body.pack_start(self._card([i18n.t("No printers.")]),
                                 False, False, 0)
        for row in sorted(rows, key=lambda item: item["prints"], reverse=True):
            row_success = self._success(row["prints"], row["failed"])
            detail = (f"{row['prints']} {'wydruków' if self.pl else 'prints'} · {row['hours']:.1f} h · "
                      f"{row_success}%" if row_success is not None else
                      f"{row['prints']} {'wydruków' if self.pl else 'prints'} · {row['hours']:.1f} h · —")
            self.body.pack_start(self._card([row["name"], detail], title_first=True), False, False, 0)
        self.body.show_all()

        self.rendered_text = self._plain_text(rows, prints, failed, hours, grams, success)

    def _caption(self, text: str) -> Gtk.Widget:
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class("settings-section")
        return label

    def _card(self, lines: list[str], title_first: bool = False) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        card.get_style_context().add_class("settings-card")
        for index, line in enumerate(lines):
            label = Gtk.Label(label=line, xalign=0, wrap=True)
            label.get_style_context().add_class(
                "settings-version" if title_first and index == 0 else "settings-hint")
            card.pack_start(label, False, False, 0)
        return card

    # ---------------------------------------------------------------- export

    def _plain_text(self, rows: list[dict[str, Any]], prints: int, failed: int,
                    hours: float, grams: float, success: int | None) -> str:
        stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
        success_text = f"{success}%" if success is not None else "—"
        out = [f"Gantry {'statystyki floty' if self.pl else 'fleet statistics'}",
               f"{'Wygenerowano' if self.pl else 'Generated'}: {stamp}",
               f"{'Okres' if self.pl else 'Period'}: {self._period_label(self.period_days)}",
               "",
               (f"{'Wydruki' if self.pl else 'Prints'}: {prints}  "
                f"({'nieudane' if self.pl else 'failed'}: {failed})"),
               f"{'Skuteczność' if self.pl else 'Success rate'}: {success_text}",
               f"{'Czas druku' if self.pl else 'Print time'}: {hours:.1f} h"]
        if grams > 0:
            out.append(f"Filament: {grams / 1000:.2f} kg")
        out.append("")
        out.append(i18n.t("By printer:"))
        for row in sorted(rows, key=lambda item: item["prints"], reverse=True):
            row_success = self._success(row["prints"], row["failed"])
            mark = f"{row_success}%" if row_success is not None else "—"
            out.append(f"  {row['name']}: {row['prints']} {'wydruków' if self.pl else 'prints'}, "
                       f"{row['hours']:.1f} h, {mark}")
        return "\n".join(out) + "\n"

    def _export(self, *_args: object) -> None:
        chooser = Gtk.FileChooserDialog(
            title=i18n.t("Export statistics"),
            transient_for=self, action=Gtk.FileChooserAction.SAVE)
        chooser.add_buttons(i18n.t("Cancel"), Gtk.ResponseType.CANCEL,
i18n.t("Save"), Gtk.ResponseType.ACCEPT)
        chooser.set_current_name("gantry-statystyki.txt")
        chooser.set_do_overwrite_confirmation(True)
        if chooser.run() == Gtk.ResponseType.ACCEPT:
            path = chooser.get_filename()
            if path:
                try:
                    with open(path, "w", encoding="utf-8") as handle:
                        handle.write(self.rendered_text)
                except OSError:
                    pass
        chooser.destroy()
