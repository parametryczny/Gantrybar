from __future__ import annotations

"""Local print history, statistics and per-printer maintenance schedules.

Firmware vendors expose different diagnostics and no stable maintenance counter. Gantry therefore
counts time spent printing locally. Printer/HMS errors stay separate live alerts and are never
presented as completed service history.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any
import uuid

from .core import PrinterState, Telemetry


DEFINITIONS = (
    ("clean-rods", "Czyszczenie prowadnic", "Clean guide rods", 100.0),
    ("lubricate-axes", "Smarowanie osi", "Lubricate axes", 200.0),
    ("inspect-belts", "Kontrola pasków", "Inspect belts", 300.0),
    ("inspect-nozzle", "Kontrola dyszy", "Inspect nozzle", 500.0),
)


@dataclass(slots=True)
class TaskStatus:
    id: str
    title: str
    interval_hours: float
    remaining_hours: float
    overdue_hours: float
    due: bool
    urgent: bool
    snoozed_until: datetime | None


class PrinterInsights:
    KEY = "printer-insights-v1"

    def __init__(self, app: Any) -> None:
        self.app = app
        raw = app.config.data.get(self.KEY, {})
        self.records: dict[str, dict[str, Any]] = raw if isinstance(raw, dict) else {}
        self._last_seen: dict[str, datetime] = {}
        self._last_saved = datetime.min.replace(tzinfo=timezone.utc)

    @staticmethod
    def _now() -> datetime:
        return datetime.now(timezone.utc)

    @staticmethod
    def _date(value: object) -> datetime | None:
        if not isinstance(value, str) or not value:
            return None
        try:
            parsed = datetime.fromisoformat(value)
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)
        except ValueError:
            return None

    def _record(self, serial: str) -> dict[str, Any]:
        value = self.records.get(serial)
        if not isinstance(value, dict):
            value = {}
        value.setdefault("totalPrintSeconds", 0.0)
        value.setdefault("history", [])
        value.setdefault("tasks", {})
        self.records[serial] = value
        return value

    def observe(self, serial: str, previous: Telemetry, current: Telemetry) -> None:
        now = self._now()
        record = self._record(serial)
        was_active = previous.state in (PrinterState.PRINTING, PrinterState.PAUSED)
        active = current.state in (PrinterState.PRINTING, PrinterState.PAUSED)
        if active and not record.get("activeStartedAt"):
            record["activeStartedAt"] = now.isoformat()
            record["activeJob"] = current.job_name or ""
        last = self._last_seen.get(serial)
        if current.state == PrinterState.PRINTING and last is not None:
            record["totalPrintSeconds"] = float(record.get("totalPrintSeconds", 0)) + min(120.0, max(0.0, (now - last).total_seconds()))
        self._last_seen[serial] = now

        result: str | None = None
        if current.state == PrinterState.FINISHED and previous.state != PrinterState.FINISHED \
                and (was_active or record.get("activeStartedAt")):
            result = "completed"
        elif was_active and current.state == PrinterState.ERROR:
            result = "failed"
        elif was_active and current.state == PrinterState.IDLE and 0 < previous.progress < 100:
            result = "cancelled"
        if result:
            started = self._date(record.get("activeStartedAt")) or now
            job = current.job_name or previous.job_name or str(record.get("activeJob") or "")
            history = record.get("history")
            if not isinstance(history, list):
                history = []
            duplicate = bool(history and history[-1].get("result") == result and history[-1].get("job") == job
                             and (now - (self._date(history[-1].get("endedAt")) or datetime.min.replace(tzinfo=timezone.utc))).total_seconds() < 30)
            if not duplicate:
                history.append({"id": str(uuid.uuid4()), "job": job, "startedAt": started.isoformat(),
                                "endedAt": now.isoformat(), "result": result,
                                "durationSeconds": max(0.0, (now - started).total_seconds())})
                record["history"] = history[-100:]
            record.pop("activeStartedAt", None)
            record.pop("activeJob", None)
        elif not active and current.state != PrinterState.OFFLINE and not was_active:
            record.pop("activeStartedAt", None)
            record.pop("activeJob", None)
        self._save(force=result is not None)

    def snapshot(self, serial: str, polish: bool) -> dict[str, Any]:
        record = self._record(serial)
        hours = float(record.get("totalPrintSeconds", 0)) / 3600.0
        task_values = record.get("tasks") if isinstance(record.get("tasks"), dict) else {}
        tasks: list[TaskStatus] = []
        now = self._now()
        for task_id, pl, en, default in DEFINITIONS:
            state = task_values.get(task_id) if isinstance(task_values.get(task_id), dict) else {}
            interval = max(1.0, float(state.get("intervalHours", default)))
            remaining = float(state.get("completedAtPrintHours", 0)) + interval - hours
            snoozed = self._date(state.get("snoozedUntil"))
            due = remaining <= 0 and not (snoozed and snoozed > now)
            overdue = max(0.0, -remaining)
            tasks.append(TaskStatus(task_id, pl if polish else en, interval, max(0.0, remaining),
                                    overdue, due, due and overdue >= max(24.0, interval * .15), snoozed))
        history = list(reversed(record.get("history", [])))
        usage = getattr(getattr(self.app, "physical_spools", None), "usage", [])
        grams = sum(float(item.get("consumedGrams", 0)) for item in usage
                    if isinstance(item, dict) and item.get("printerSerial") == serial)
        completed = sum(1 for item in history if item.get("result") == "completed")
        success = round(completed / len(history) * 100) if history else None
        return {"total_hours": hours, "tasks": tasks, "history": history,
                "consumed_grams": grams, "completed": completed, "success": success}

    def signal(self, serial: str, _hms_codes: list[str] | None = None) -> tuple[str, int]:
        tasks = self.snapshot(serial, True)["tasks"]
        urgent = sum(1 for task in tasks if task.urgent)
        if urgent:
            return "urgent", urgent
        due = sum(1 for task in tasks if task.due)
        if due:
            return "due", due
        now = self._now()
        planned = any(not task.due and not (task.snoozed_until and task.snoozed_until > now)
                      and task.remaining_hours <= max(24.0, task.interval_hours * .1) for task in tasks)
        return ("planned", 0) if planned else ("none", 0)

    def complete(self, serial: str, task_id: str) -> None:
        self._change(serial, task_id, completed=True)

    def snooze(self, serial: str, task_id: str) -> None:
        self._change(serial, task_id, snooze=True)

    def set_interval(self, serial: str, task_id: str, hours: float) -> None:
        if hours >= 1:
            self._change(serial, task_id, interval=hours)

    def _change(self, serial: str, task_id: str, *, completed: bool = False,
                snooze: bool = False, interval: float | None = None) -> None:
        record = self._record(serial)
        tasks = record.setdefault("tasks", {})
        default = next((item[3] for item in DEFINITIONS if item[0] == task_id), 200.0)
        state = tasks.setdefault(task_id, {"intervalHours": default, "completedAtPrintHours": 0})
        if completed:
            state["completedAtPrintHours"] = float(record.get("totalPrintSeconds", 0)) / 3600.0
            state.pop("snoozedUntil", None)
        if snooze:
            state["snoozedUntil"] = (self._now() + timedelta(days=7)).isoformat()
        if interval is not None:
            state["intervalHours"] = float(interval)
        self._save(force=True)

    def _save(self, force: bool = False) -> None:
        now = self._now()
        if not force and (now - self._last_saved).total_seconds() < 60:
            return
        self.app.config.data[self.KEY] = self.records
        self.app.config.save()
        self._last_saved = now
