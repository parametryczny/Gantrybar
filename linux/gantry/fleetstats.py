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

from . import i18n, printcost
from .panelwindow import panel_header

PERIODS = (7, 30, 365, 0)   # 0 = all time


class FleetStatsDialog(Gtk.Dialog):
    def __init__(self, app: Any) -> None:
        super().__init__(title=i18n.t("Fleet statistics"),
                         transient_for=app.window, modal=False)
        panel_header(self, i18n.t("Fleet statistics"))
        self.set_position(Gtk.WindowPosition.CENTER)
        self.app = app
        self.pl = app.language == "pl"
        self.period_days = 30
        self.rendered_text = ""
        self.set_default_size(560, 640)
        self.set_size_request(420, 420)

        self.add_button(i18n.t("Done"), Gtk.ResponseType.OK)
        self.connect("response", lambda dialog, response: dialog.destroy() if response != Gtk.ResponseType.APPLY else None)
        export = self.add_button(i18n.t("Export to file…"),
                                 Gtk.ResponseType.APPLY)
        export.connect("clicked", self._export)
        self.rendered_csv = ""

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        root.get_style_context().add_class("settings-root")

        self.period = Gtk.ComboBoxText()
        for days in PERIODS:
            self.period.append(str(days), self._period_label(days))
        self.period.set_active_id("30")
        self.period.connect("changed", self._period_changed)
        controls = Gtk.Box(spacing=6)
        controls.pack_start(self.period, True, True, 0)
        prices = Gtk.Button(label=i18n.t("Prices…"))
        prices.connect("clicked", self._edit_prices)
        csv_button = Gtk.Button(label=i18n.t("CSV…"))
        csv_button.connect("clicked", self._export_csv)
        controls.pack_start(prices, False, False, 0)
        controls.pack_start(csv_button, False, False, 0)
        root.pack_start(controls, False, False, 0)

        self.body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.body)
        root.pack_start(scroll, True, True, 0)
        self.get_content_area().pack_start(root, True, True, 0)

        self._render()
        self.get_child().show_all()

    # ------------------------------------------------------------------ data

    def _period_label(self, days: int) -> str:
        if days == 7:
            return i18n.t("last 7 days")
        if days == 30:
            return i18n.t("last 30 days")
        if days == 365:
            return i18n.t("last year")
        return i18n.t("all time")

    def _period_changed(self, combo: Gtk.ComboBoxText) -> None:
        self.period_days = int(combo.get_active_id() or "30")
        self._render()

    def _lines(self, days: int) -> list[dict[str, Any]]:
        """Every finished (or failed) print in the period with what it cost, newest first."""
        settings = printcost.load(self.app.config)
        cutoff = datetime.now(timezone.utc) - timedelta(days=days) if days else None
        lines: list[dict[str, Any]] = []
        for printer in self.app.printers:
            for item in self.app.insights.snapshot(printer.serial, self.pl).get("history", []):
                ended = self._ended(item)
                if cutoff is not None and ended < cutoff:
                    continue
                started = self._started(item, ended)
                used = printcost.uses(self.app, printer.serial, started, ended)
                lines.append({"printer": printer.name, "serial": printer.serial, "entry": item,
                              "ended": ended, "started": started, "uses": used,
                              "ok": item.get("result") == "completed",
                              "cost": printcost.compute(float(item.get("durationSeconds", 0) or 0), used,
                                                        printer.serial, settings)})
        return sorted(lines, key=lambda line: line["ended"], reverse=True)

    def _rows(self, lines: list[dict[str, Any]]) -> list[dict[str, Any]]:
        now = datetime.now(timezone.utc)
        rows: list[dict[str, Any]] = []
        for printer in self.app.printers:
            mine = [line for line in lines if line["serial"] == printer.serial]
            hours = sum(float(line["entry"].get("durationSeconds", 0) or 0) for line in mine) / 3600
            # Share of the period spent printing; "all time" starts at the printer's first recorded print.
            start = (min((line["started"] for line in mine), default=None) if not self.period_days
                     else now - timedelta(days=self.period_days))
            span = (now - start).total_seconds() / 3600 if start is not None else 0
            rows.append({"name": printer.name, "prints": len(mine),
                         "failed": sum(1 for line in mine if not line["ok"]), "hours": hours,
                         "grams": sum(line["cost"].grams or 0 for line in mine),
                         "cost": sum(line["cost"].total for line in mine),
                         "utilization": min(1.0, hours / span) if span > 1 else None})
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
    def _started(item: dict[str, Any], ended: datetime) -> datetime:
        try:
            value = datetime.fromisoformat(str(item.get("startedAt", "")))
            return value if value.tzinfo else value.replace(tzinfo=timezone.utc)
        except ValueError:
            return ended - timedelta(seconds=float(item.get("durationSeconds", 0) or 0))

    @staticmethod
    def _success(prints: int, failed: int) -> int | None:
        return None if prints == 0 else round((prints - failed) / prints * 100)

    def _money(self, value: float) -> str:
        return f"{value:.2f} {printcost.load(self.app.config).currency}"

    @staticmethod
    def _weekly(lines: list[dict[str, Any]]) -> tuple[str, list[int]]:
        """Prints per week for the last eight weeks, oldest first, as a one-line bar chart."""
        counts = [0] * 8
        now = datetime.now(timezone.utc)
        for line in lines:
            age = int((now - line["ended"]).total_seconds() // (7 * 86400))
            if 0 <= age < 8:
                counts[7 - age] += 1
        ticks, top = "▁▂▃▄▅▆▇█", max(1, max(counts))
        return "".join("·" if c == 0 else ticks[min(7, (c * 8 - 1) // top)] for c in counts), counts

    # --------------------------------------------------------------- drawing

    def _render(self) -> None:
        for child in self.body.get_children():
            self.body.remove(child)

        lines = self._lines(self.period_days)
        rows = self._rows(lines)
        prints = len(lines)
        failed = sum(1 for line in lines if not line["ok"])
        hours = sum(float(line["entry"].get("durationSeconds", 0) or 0) for line in lines) / 3600
        grams = sum(line["cost"].grams or 0 for line in lines)
        success = self._success(prints, failed)
        success_text = f"{success}%" if success is not None else "—"
        cost = sum(line["cost"].total for line in lines)
        completed = [line for line in lines if line["ok"]]

        summary = [
            i18n.t("Period: {0}").format(self._period_label(self.period_days)),
            i18n.t("Prints: {0} (failed: {1})").format(prints, failed),
            i18n.t("Success rate: {0}").format(success_text),
            i18n.t("Print time: {0} h").format(f"{hours:.1f}"),
        ]
        if grams > 0:
            summary.append(f"Filament: {grams / 1000:.2f} kg")
        used = [row["utilization"] for row in rows if row["utilization"] is not None]
        if used:
            summary.append(i18n.t("Printer utilization: {0}%").format(round(sum(used) / len(used) * 100)))
        self.body.pack_start(self._caption(i18n.t("SUMMARY")), False, False, 0)
        self.body.pack_start(self._card(summary), False, False, 0)

        costs = [i18n.t("Total: {0}").format(self._money(cost)),
                 i18n.t("Filament {0} · electricity {1} · machine time {2}").format(
                     self._money(sum(line["cost"].filament or 0 for line in lines)),
                     self._money(sum(line["cost"].energy for line in lines)),
                     self._money(sum(line["cost"].machine for line in lines)))]
        if completed:
            costs.append(i18n.t("Average successful print: {0}").format(
                self._money(sum(line["cost"].total for line in completed) / len(completed))))
        wasted = sum(line["cost"].total for line in lines if not line["ok"])
        if wasted > 0:
            costs.append(i18n.t("Lost on failed prints: {0}").format(self._money(wasted)))
        unknown = sum(1 for line in lines if line["cost"].filament is None)
        if unknown:
            costs.append(i18n.t("{0} prints without filament data — assign rolls in Spoolbase to count it.").format(unknown))
        self.body.pack_start(self._caption(i18n.t("COSTS")), False, False, 0)
        self.body.pack_start(self._card(costs), False, False, 0)

        bars, counts = self._weekly(self._lines(56) if 0 < self.period_days <= 30 else lines)
        production = [i18n.t("Prints per week (8 weeks): {0}  {1}").format(bars, " ".join(map(str, counts)))]
        materials: dict[str, float] = {}
        for line in lines:
            for use in line["uses"]:
                key = (use.material or "?").upper()
                materials[key] = materials.get(key, 0.0) + use.grams
        if materials:
            production.append(i18n.t("By material: {0}").format(" · ".join(
                f"{name} {value / 1000:.2f} kg" for name, value in sorted(materials.items(), key=lambda kv: -kv[1]))))
        jobs: dict[str, int] = {}
        for line in completed:
            job = str(line["entry"].get("job") or "")
            if job:
                jobs[job] = jobs.get(job, 0) + 1
        if jobs:
            production.append(i18n.t("Most printed: {0}").format(" · ".join(
                f"{job} ×{count}" for job, count in sorted(jobs.items(), key=lambda kv: (-kv[1], kv[0]))[:5])))
        cancelled = sum(1 for line in lines if line["entry"].get("result") == "cancelled")
        if failed:
            production.append(i18n.t("Unsuccessful: {0} errors · {1} cancelled").format(failed - cancelled, cancelled))
        self.body.pack_start(self._caption(i18n.t("PRODUCTION")), False, False, 0)
        self.body.pack_start(self._card(production), False, False, 0)

        self.body.pack_start(self._caption(i18n.t("BY PRINTER")), False, False, 0)
        if not rows:
            self.body.pack_start(self._card([i18n.t("No printers.")]),
                                 False, False, 0)
        for row in sorted(rows, key=lambda item: item["prints"], reverse=True):
            row_success = self._success(row["prints"], row["failed"])
            detail = i18n.t("{0} prints · {1} h · {2}").format(
                row["prints"], f"{row['hours']:.1f}",
                f"{row_success}%" if row_success is not None else "—") + " · " + self._money(row["cost"])
            if row["utilization"] is not None:
                detail += " · " + i18n.t("utilization {0}%").format(round(row["utilization"] * 100))
            self.body.pack_start(self._card([row["name"], detail], title_first=True), False, False, 0)

        if lines:
            recent = []
            for line in lines[:15]:
                grams_text = f" · {line['cost'].grams:.0f} g" if line["cost"].grams is not None else ""
                recent.append(f"{'✓' if line['ok'] else '✕'} {line['ended'].astimezone().strftime('%d.%m %H:%M')} · "
                              f"{line['printer']} · {line['entry'].get('job') or '—'} · "
                              f"{float(line['entry'].get('durationSeconds', 0) or 0) / 3600:.1f} h{grams_text} · "
                              f"{self._money(line['cost'].total)}")
            self.body.pack_start(self._caption(i18n.t("RECENT PRINTS")), False, False, 0)
            self.body.pack_start(self._card(recent), False, False, 0)
        self.body.show_all()

        self.rendered_text = self._plain_text(rows, prints, failed, hours, grams, success)
        self.rendered_csv = self._csv(lines)

    def _csv(self, lines: list[dict[str, Any]]) -> str:
        """One row per print. Semicolons and a decimal comma in Polish, so a spreadsheet opens it in columns."""
        sep = ";" if self.pl else ","

        def num(value: float | None) -> str:
            if value is None:
                return ""
            text = f"{value:.2f}"
            return text.replace(".", ",") if self.pl else text

        def field(text: str) -> str:
            return '"' + text.replace('"', '""') + '"' if any(c in text for c in (sep, '"', "\n")) else text
        currency = printcost.load(self.app.config).currency
        out = [sep.join(["start", "end", "printer", "job", "result", "hours", "grams", "kWh",
                         f"filament_{currency}", f"energy_{currency}", f"machine_{currency}", f"total_{currency}"])]
        for line in reversed(lines):
            c = line["cost"]
            out.append(sep.join([line["started"].astimezone().strftime("%Y-%m-%d %H:%M"),
                                 line["ended"].astimezone().strftime("%Y-%m-%d %H:%M"),
                                 field(line["printer"]), field(str(line["entry"].get("job") or "")),
                                 str(line["entry"].get("result") or ""),
                                 num(float(line["entry"].get("durationSeconds", 0) or 0) / 3600),
                                 num(c.grams), num(c.kwh), num(c.filament), num(c.energy), num(c.machine), num(c.total)]))
        return "\n".join(out) + "\n"

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
        out = [i18n.t("Gantry fleet statistics"),
               i18n.t("Generated: {0}").format(stamp),
               i18n.t("Period: {0}").format(self._period_label(self.period_days)),
               "",
               i18n.t("Prints: {0} (failed: {1})").format(prints, failed),
               i18n.t("Success rate: {0}").format(success_text),
               i18n.t("Print time: {0} h").format(f"{hours:.1f}")]
        if grams > 0:
            out.append(f"Filament: {grams / 1000:.2f} kg")
        out.append(f"{i18n.t('Cost')}: {self._money(sum(row['cost'] for row in rows))}")
        out.append("")
        out.append(i18n.t("By printer:"))
        for row in sorted(rows, key=lambda item: item["prints"], reverse=True):
            row_success = self._success(row["prints"], row["failed"])
            mark = f"{row_success}%" if row_success is not None else "—"
            out.append("  " + i18n.t("{0}: {1} prints, {2} h, {3}").format(
                row["name"], row["prints"], f"{row['hours']:.1f}", mark) + f", {self._money(row['cost'])}")
        return "\n".join(out) + "\n"

    def _export_csv(self, *_args: object) -> None:
        chooser = Gtk.FileChooserDialog(title=i18n.t("CSV…"), transient_for=self, action=Gtk.FileChooserAction.SAVE)
        chooser.add_buttons(i18n.t("Cancel"), Gtk.ResponseType.CANCEL, i18n.t("Save"), Gtk.ResponseType.ACCEPT)
        chooser.set_current_name("gantry-wydruki.csv")
        chooser.set_do_overwrite_confirmation(True)
        if chooser.run() == Gtk.ResponseType.ACCEPT and chooser.get_filename():
            try:
                # BOM, so a spreadsheet reads Polish letters in job names as UTF-8.
                with open(chooser.get_filename(), "w", encoding="utf-8-sig") as handle:
                    handle.write(self.rendered_csv)
            except OSError:
                pass
        chooser.destroy()

    def _edit_prices(self, *_args: object) -> None:
        settings = printcost.load(self.app.config)
        dialog = Gtk.Dialog(title=i18n.t("Print cost prices"), transient_for=self, modal=True)
        dialog.add_buttons(i18n.t("Cancel"), Gtk.ResponseType.CANCEL, i18n.t("Save"), Gtk.ResponseType.OK)
        dialog.set_default_response(Gtk.ResponseType.OK)
        grid = Gtk.Grid(row_spacing=8, column_spacing=12, margin=16)

        def number(value: float) -> str:
            return f"{value:g}"
        fields = [(i18n.t("Currency"), settings.currency),
                  (i18n.t("Filament per kg"), number(settings.filamentPerKg)),
                  (i18n.t("Per material (per kg)"), ", ".join(f"{k}={number(v)}" for k, v in sorted((settings.materialPerKg or {}).items()))),
                  (i18n.t("Electricity per kWh"), number(settings.electricityPerKWh)),
                  (i18n.t("Average printer power (W)"), number(settings.printerWatts)),
                  (i18n.t("Machine time per hour"), number(settings.machinePerHour))]
        entries = []
        for row, (label, value) in enumerate(fields):
            text = Gtk.Label(label=label, xalign=1)
            entry = Gtk.Entry(text=value, hexpand=True, activates_default=True)
            grid.attach(text, 0, row, 1, 1); grid.attach(entry, 1, row, 1, 1)
            entries.append(entry)
        entries[2].set_placeholder_text("PETG=90, ASA=120")
        hint = Gtk.Label(label=i18n.t("Used to price every print: filament from Spoolbase usage, electricity and machine time from its duration."),
                         xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        grid.attach(hint, 0, len(fields), 2, 1)
        dialog.get_content_area().pack_start(grid, True, True, 0)
        dialog.show_all()
        if dialog.run() == Gtk.ResponseType.OK:
            if entries[0].get_text().strip():
                settings.currency = entries[0].get_text().strip()[:8]
            for entry, key in ((entries[1], "filamentPerKg"), (entries[3], "electricityPerKWh"),
                               (entries[4], "printerWatts"), (entries[5], "machinePerHour")):
                value = printcost.parse_amount(entry.get_text())
                if value is not None:
                    setattr(settings, key, value)
            settings.materialPerKg = printcost.parse_material_prices(entries[2].get_text())
            printcost.save(self.app.config, settings)
            self._render()
        dialog.destroy()

    def _export(self, *_args: object) -> None:
        chooser = Gtk.FileChooserDialog(
            title=i18n.t("Export statistics"),
            transient_for=self if self.get_visible() else self.app.window, action=Gtk.FileChooserAction.SAVE)
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
