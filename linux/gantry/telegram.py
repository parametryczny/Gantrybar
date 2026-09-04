"""Telegram integration for Gantry (Linux): outbound notifications + a two-way bot.

The Python mirror of the macOS/Windows TelegramService + TelegramBot. Same shared config keys
(telegram-enabled / telegram-bot-token / telegram-chat-id) and the same message format, so one account
works across a user's machines. See docs/telegram.md.

Only the configured chat id may drive the bot. HTTP uses urllib (stdlib); the poll loop runs on a daemon
thread and marshals printer control back to the GTK main loop via GLib.idle_add.
/photo (camera snapshot) is stubbed on Linux for now (Etap 2b).
"""
from __future__ import annotations

import json
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

from gi.repository import GLib  # type: ignore

from . import i18n
from .core import PrinterKind, PrinterState

_API = "https://api.telegram.org/bot{token}/{method}"


def _post(token: str, method: str, params: dict[str, str], timeout: int = 20) -> dict | None:
    try:
        data = urllib.parse.urlencode(params).encode()
        request = urllib.request.Request(_API.format(token=token, method=method), data=data)
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except Exception:
        return None


def command_keyboard() -> str:
    """Persistent bottom bar of commands, shared with the bot. Every outgoing message carries it, so it
    installs itself on the user's very first alert: the printer picker is an inline keyboard glued to one
    message, and once the chat scrolls past it there is no way back without scrolling up."""
    return json.dumps({"keyboard": [[{"text": t} for t in row] for row in
                       [["/status", "/all"], ["/spools", "/history"],
                        ["/watch 10m", "/mute 2h"], ["/help"]]],
                       "resize_keyboard": True})


def format_message(printer: str, title: str, body: str) -> str:
    return f"🖨 {printer} — {title}" + (f"\n{body}" if body else "")


def _muted(cfg: dict) -> bool:
    stamp = cfg.get("telegram-mute-until")
    if not stamp:
        return False
    try:
        return datetime.fromisoformat(stamp) > datetime.now(timezone.utc)
    except Exception:
        return False


def notify(app, printer: str, title: str, body: str) -> None:
    """Send one event to Telegram, when enabled, configured and not muted. Fire-and-forget on a thread."""
    cfg = app.config.data
    if not cfg.get("telegram-enabled") or _muted(cfg):
        return
    token = (cfg.get("telegram-bot-token") or "").strip()
    chat = (cfg.get("telegram-chat-id") or "").strip()
    if not token or not chat:
        return
    text = format_message(printer, title, body)
    threading.Thread(
        target=_post, daemon=True,
        args=(token, "sendMessage", {"chat_id": chat, "text": text, "disable_web_page_preview": "true",
                                    "reply_markup": command_keyboard()}),
    ).start()


def send_test(token: str, chat: str, title: str, body: str) -> bool:
    result = _post(token, "sendMessage", {"chat_id": chat, "text": format_message("Gantry", title, body),
                                          "reply_markup": command_keyboard()})
    return bool(result and result.get("ok"))


def record_history(app, serial: str, printer: str, job: str) -> None:
    cfg = app.config.data
    history = list(cfg.get("print-history-v1") or [])
    history.append({"serial": serial, "printer": printer, "job": job, "date": datetime.now().isoformat()})
    cfg["print-history-v1"] = history[-30:]
    app.config.save()


def _color_dot(hex_value: str | None) -> str:
    if not hex_value:
        return "⚪️"
    clean = hex_value.replace("#", "")[:6]
    try:
        value = int(clean, 16)
    except ValueError:
        return "⚪️"
    r, g, b = (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF
    hi, lo = max(r, g, b), min(r, g, b)
    if hi < 55:
        return "⚫️"
    if lo > 205 or hi - lo < 34:
        return "⚪️"
    if r >= g and r >= b:
        return "🟤" if hi < 150 else ("🟠" if g > 110 else "🔴")
    if g >= r and g >= b:
        return "🟢"
    if b >= r and b >= g:
        return "🟣" if r > 110 else "🔵"
    return "🟡"


def _parse_duration(text: str | None) -> float | None:
    if not text:
        return None
    lower = text.lower()
    try:
        if lower.endswith("h"):
            return float(lower[:-1]) * 3600
        if lower.endswith("m"):
            return float(lower[:-1]) * 60
        return float(lower) * 60
    except ValueError:
        return None


class TelegramBot:
    """Two-way bot: long-polls getUpdates and maps a printer picker + controls to the app."""

    def __init__(self, app) -> None:
        self.app = app
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._watch_stop: threading.Event | None = None
        self._offset = 0

    def sync(self) -> None:
        cfg = self.app.config.data
        configured = bool(cfg.get("telegram-enabled")) and bool((cfg.get("telegram-bot-token") or "").strip()) \
            and bool((cfg.get("telegram-chat-id") or "").strip())
        if configured and self._thread is None:
            self._stop.clear()
            self._thread = threading.Thread(target=self._loop, daemon=True)
            self._thread.start()
        elif not configured and self._thread is not None:
            self._stop.set()
            self._thread = None
            self._stop_watch()

    @property
    def _token(self) -> str:
        return (self.app.config.data.get("telegram-bot-token") or "").strip()

    @property
    def _chat(self) -> str:
        return (self.app.config.data.get("telegram-chat-id") or "").strip()

    # Poll loop

    def _loop(self) -> None:
        while not self._stop.is_set() and self.app.config.data.get("telegram-enabled") and self._token and self._chat:
            root = _post(self._token, "getUpdates",
                         {"offset": str(self._offset), "timeout": "25",
                          "allowed_updates": '["message","callback_query"]'}, timeout=60)
            if not root or not root.get("ok"):
                time.sleep(3)
                continue
            for update in root.get("result", []):
                if self._stop.is_set():
                    break
                self._offset = max(self._offset, update.get("update_id", 0) + 1)
                self._handle(update)

    def _handle(self, update: dict) -> None:
        if "message" in update:
            if not self._authorized(update["message"].get("chat")):
                return
            self._handle_text((update["message"].get("text") or "").strip())
        elif "callback_query" in update:
            callback = update["callback_query"]
            cb_id = callback.get("id", "")
            message = callback.get("message") or {}
            if not self._authorized(message.get("chat")):
                self._answer(cb_id, "Brak dostępu")
                return
            self._handle_callback(callback.get("data") or "", cb_id, message.get("message_id"))

    def _authorized(self, chat: dict | None) -> bool:
        return bool(chat) and str(chat.get("id")) == self._chat

    def _t(self, english: str) -> str:
        return i18n.t(english)

    # Command routing

    def _handle_text(self, text: str) -> None:
        parts = text.split()
        command = (parts[0].split("@")[0].lower() if parts else "")
        argument = parts[1] if len(parts) > 1 else None
        if command in ("/help", "/start"):
            self._send_help()
        elif command == "/all":
            self._send_all()
        elif command == "/spools":
            self._send_spools()
        elif command == "/history":
            self._send_history()
        elif command == "/mute":
            self._handle_mute(argument)
        elif command == "/watch":
            self._handle_watch(argument)
        else:
            self._send_printer_menu(None)

    def _handle_callback(self, data: str, cb_id: str, message_id: int | None) -> None:
        parts = data.split(":")
        head = parts[0] if parts else ""
        if head == "p" and len(parts) > 1:
            self._show_status(parts[1], message_id)
            self._answer(cb_id, "")
        elif head == "menu":
            self._send_printer_menu(message_id)
            self._answer(cb_id, "")
        elif head == "a" and len(parts) >= 3:
            self._run_action(parts[1], parts[2], cb_id, message_id)
        elif head == "photo" and len(parts) > 1:
            self._answer(cb_id, "📷")
            self._handle_photo(parts[1])
        else:
            self._answer(cb_id, "")

    def _handle_photo(self, serial: str) -> None:
        name = next((p.name for p in self.app.printers if p.serial == serial), serial)
        self._send(self._t(f"📷 Robię zdjęcie z kamery {name}…",
                           f"📷 Grabbing a camera snapshot from {name}…"), None)
        from .snapshot import capture
        jpeg = capture(self.app, serial)
        if jpeg:
            self._send_photo(jpeg, name)
        else:
            self._send(self._t("Couldn't grab a snapshot (camera unavailable)."), self._command_keyboard())

    def _send_photo(self, jpeg: bytes, caption: str) -> None:
        """sendPhoto is multipart/form-data, so it cannot go through the urlencoded _post helper."""
        boundary = "----gantry" + str(int(time.time() * 1000))
        parts: list[bytes] = []
        for field, value in (("chat_id", self._chat), ("caption", caption)):
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"\r\n\r\n{value}\r\n'.encode())
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="photo"; '
                     f'filename="snapshot.jpg"\r\nContent-Type: image/jpeg\r\n\r\n'.encode())
        parts.append(jpeg)
        parts.append(f"\r\n--{boundary}--\r\n".encode())
        body = b"".join(parts)
        try:
            request = urllib.request.Request(
                _API.format(token=self._token, method="sendPhoto"), data=body,
                headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
            urllib.request.urlopen(request, timeout=30).read()
        except Exception:      # noqa: BLE001 - a failed photo must not kill the poll loop
            self._send(self._t("Could not send the photo."), None)

    # Screens

    def _send_printer_menu(self, message_id: int | None) -> None:
        printers = list(self.app.printers)
        if not printers:
            self._send(self._t("No printers."), self._command_keyboard())
            return
        rows = [[self._btn(f"{self._icon(p.serial)} {p.name}", f"p:{p.serial}")] for p in printers]
        text = self._t("Pick a printer:")
        if message_id is not None:
            self._edit(message_id, text, self._keyboard(rows))
        else:
            self._send(text, self._keyboard(rows))

    def _show_status(self, serial: str, message_id: int | None) -> None:
        text = self._status_text(serial)
        markup = self._action_keyboard(serial)
        if message_id is not None:
            self._edit(message_id, text, markup)
        else:
            self._send(text, markup)

    def _run_action(self, action: str, serial: str, cb_id: str, message_id: int | None) -> None:
        name = next((p.name for p in self.app.printers if p.serial == serial), serial)
        if action == "stopask":
            if message_id is not None:
                self._edit(message_id,
                           self._t(f"⏹ Zatrzymać wydruk na {name}? Tego nie cofniesz.",
                                   f"⏹ Cancel the print on {name}? This cannot be undone."),
                           self._keyboard([[self._btn(self._t("Yes, cancel"), f"a:stop:{serial}"),
                                            self._btn(self._t("Back"), f"p:{serial}")]]))
            self._answer(cb_id, "")
            return
        mapping = {"pause": "⏸ Wstrzymano", "resume": "▶️ Wznowiono", "stop": "⏹ Zatrzymano",
                   "lighton": "💡 Włączono", "lightoff": "🌑 Wyłączono"}
        control = {"pause": "pause", "resume": "resume", "stop": "stop", "lighton": "light_on", "lightoff": "light_off"}
        if action not in control:
            self._answer(cb_id, "")
            return
        self._control(serial, control[action])
        self._answer(cb_id, mapping[action])
        time.sleep(0.7)
        self._show_status(serial, message_id)

    def _control(self, serial: str, action: str) -> None:
        def do() -> bool:
            app = self.app
            printer = next((p for p in app.printers if p.serial == serial), self._command_keyboard())
            is_klipper = printer is not None and printer.kind == PrinterKind.KLIPPER
            from .automation import _PAUSE, _RESUME, _STOP
            if action == "pause":
                app.send_gcode(serial, "PAUSE") if is_klipper else app.send_command(serial, _PAUSE)
            elif action == "resume":
                app.send_gcode(serial, "RESUME") if is_klipper else app.send_command(serial, _RESUME)
            elif action == "stop":
                app.send_gcode(serial, "CANCEL_PRINT") if is_klipper else app.send_command(serial, _STOP)
            elif action == "light_on":
                app.set_chamber_light(serial, True)
            elif action == "light_off":
                app.set_chamber_light(serial, False)
            return False
        GLib.idle_add(do)

    # Commands

    def _send_help(self) -> None:
        text = self._t(
            "🖨 Gantry — komendy:\n/status — wybór drukarki + sterowanie\n/all — cała flota w skrócie\n"
            "/spools — rolki na wyczerpaniu\n/history — ostatnie wydruki\n/watch 10m — zdjęcia co 10 min (/watch off)\n"
            "/mute 2h — wycisz alerty (/mute off)\n/help — to menu",
            "🖨 Gantry — commands:\n/status — pick a printer + controls\n/all — whole fleet at a glance\n"
            "/spools — spools running low\n/history — recent prints\n/watch 10m — a photo every 10 min (/watch off)\n"
            "/mute 2h — silence alerts (/mute off)\n/help — this menu")
        _post(self._token, "sendMessage",
              {"chat_id": self._chat, "text": text, "reply_markup": self._command_keyboard()})

    @staticmethod
    def _command_keyboard() -> str:
        """Defined once at module level so notifications and bot replies agree."""
        return command_keyboard()

    def _send_all(self) -> None:
        printers = list(self.app.printers)
        if not printers:
            self._send(self._t("No printers."), self._command_keyboard())
            return
        lines = []
        for printer in printers:
            tel = self.app.telemetry.get(printer.serial)
            line = f"{self._icon(printer.serial)} {printer.name}: {self._state_label(tel.state if tel else PrinterState.OFFLINE)}"
            if tel and tel.state in (PrinterState.PRINTING, PrinterState.PAUSED):
                line += f" · {tel.progress}%"
                if tel.remaining_minutes:
                    line += f" · ETA {tel.remaining_minutes // 60}h {tel.remaining_minutes % 60}m"
            lines.append(line)
        self._send(self._t("🖨 Fleet:") + "\n" + "\n".join(lines), self._command_keyboard())

    def _send_spools(self) -> None:
        low: list[tuple[int, str]] = []
        for printer in self.app.printers:
            tel = self.app.telemetry.get(printer.serial)
            if not tel:
                continue
            for group in tel.filament_groups:
                for slot in group.slots:
                    present = bool(slot.material) and slot.material != "—"
                    if present and slot.remaining_weight_g is not None and slot.remaining is not None and slot.remaining <= 20:
                        low.append((slot.remaining, f"{_color_dot(slot.color)} {slot.material} · {printer.name}/{slot.label} · {slot.remaining}%"))
        if not low:
            self._send(self._t("✅ Żadna rolka nie kończy się (≤20%).", "✅ No spools running low (≤20%)."), self._command_keyboard())
            return
        low.sort(key=lambda item: item[0])
        self._send(self._t("🧵 Spools running low:") + "\n"
                   + "\n".join(text for _, text in low[:15]), self._command_keyboard())

    def _send_history(self) -> None:
        entries = list(reversed(self.app.config.data.get("print-history-v1") or []))[:10]
        if not entries:
            self._send(self._t("No print history yet."), self._command_keyboard())
            return
        lines = []
        for entry in entries:
            try:
                stamp = datetime.fromisoformat(entry.get("date", "")).strftime("%d.%m %H:%M")
            except Exception:
                stamp = "—"
            job = entry.get("job") or ""
            lines.append(f"{stamp} · {entry.get('printer', '')}" + (f" · {job}" if job else ""))
        self._send(self._t("📜 Recent prints:") + "\n" + "\n".join(lines), self._command_keyboard())

    def _handle_mute(self, argument: str | None) -> None:
        cfg = self.app.config.data
        if argument and argument.lower() == "off":
            cfg["telegram-mute-until"] = ""
            self.app.config.save()
            self._send(self._t("🔔 Mute off."), self._command_keyboard())
            return
        seconds = _parse_duration(argument)
        if seconds is None:
            self._send(self._t("Give a duration, e.g. /mute 2h or /mute 30m. Turn off: /mute off"), self._command_keyboard())
            return
        from datetime import timedelta
        until = datetime.now(timezone.utc) + timedelta(seconds=seconds)
        cfg["telegram-mute-until"] = until.isoformat()
        self.app.config.save()
        self._send(self._t(f"🔕 Alerty wyciszone do {until.astimezone().strftime('%H:%M')}.",
                           f"🔕 Alerts muted until {until.astimezone().strftime('%H:%M')}."), self._command_keyboard())

    def _handle_watch(self, argument: str | None) -> None:
        if argument and argument.lower() == "off":
            self._stop_watch()
            self._send(self._t("📷 Watch off."), self._command_keyboard())
            return
        seconds = _parse_duration(argument)
        if seconds is None or seconds < 60:
            self._send(self._t("Give an interval ≥ 1 min, e.g. /watch 10m. Turn off: /watch off"), self._command_keyboard())
            return
        self._stop_watch()
        stop = threading.Event()
        self._watch_stop = stop
        threading.Thread(target=self._watch_loop, args=(seconds, stop), daemon=True).start()
        self._send(self._t(f"📷 Watch: zdjęcia drukujących drukarek co {argument}. Wyłącz: /watch off",
                           f"📷 Watch: photos of printing machines every {argument}. Turn off: /watch off"),
                   self._command_keyboard())

    def _watch_loop(self, seconds: float, stop: threading.Event) -> None:
        from .snapshot import capture
        while not stop.wait(seconds):
            for printer in list(self.app.printers):
                if stop.is_set():
                    return
                tel = self.app.telemetry.get(printer.serial)
                if tel is None or tel.state != PrinterState.PRINTING:
                    continue
                jpeg = capture(self.app, printer.serial)
                if jpeg:
                    progress = f" · {tel.progress}%" if tel.progress else ""
                    self._send_photo(jpeg, f"{printer.name}{progress}")

    def _stop_watch(self) -> None:
        if self._watch_stop is not None:
            self._watch_stop.set()
            self._watch_stop = None

    # Content

    def _status_text(self, serial: str) -> str:
        name = next((p.name for p in self.app.printers if p.serial == serial), serial)
        tel = self.app.telemetry.get(serial)
        if tel is None:
            return f"🖨 {name} — {self._state_label(PrinterState.OFFLINE)}"

        def temp(cur: float | None, tgt: float | None) -> str:
            if cur is None:
                return "—"
            return f"{int(cur)}°" + (f"/{int(tgt)}°" if tgt else "")

        lines = [f"🖨 {name} — {self._state_label(tel.state)}"]
        if tel.state in (PrinterState.PRINTING, PrinterState.PAUSED):
            line = f"{self._t('Postęp', 'Progress')}: {tel.progress}%"
            if tel.current_layer is not None:
                line += f" · {self._t('warstwa', 'layer')} {tel.current_layer}/{tel.total_layers or 0}"
            lines.append(line)
            if tel.remaining_minutes:
                lines.append(f"ETA: {tel.remaining_minutes // 60}h {tel.remaining_minutes % 60}m")
            if tel.job_name:
                lines.append(tel.job_name)
        lines.append(
            f"{self._t('Dysza', 'Nozzle')} {temp(tel.nozzle, tel.nozzle_target)}"
            f" · {self._t('stół', 'bed')} {temp(tel.bed, tel.bed_target)}"
            + (f" · {self._t('komora', 'chamber')} {temp(tel.chamber, None)}" if tel.chamber is not None else ""))
        humidity = [f"{g.display_name} 💧{g.humidity}%" for g in tel.filament_groups if g.humidity is not None]
        if humidity:
            lines.append(" · ".join(humidity))
        return "\n".join(lines)

    def _action_keyboard(self, serial: str) -> str:
        tel = self.app.telemetry.get(serial)
        tiles = []
        if tel is not None:
            for group in tel.filament_groups:
                for slot in group.slots:
                    if bool(slot.material) and slot.material != "—":
                        active = "●" if slot.active else ""
                        pct = f"{slot.remaining}%" if slot.remaining is not None else ""
                        tiles.append(self._btn(f"{_color_dot(slot.color)}{active}{slot.material} {pct}".strip(), "noop"))
        rows = [tiles[i:i + 4] for i in range(0, len(tiles), 4)]
        rows.append([self._btn("⏸ " + self._t("Pause"), f"a:pause:{serial}"),
                     self._btn("▶️ " + self._t("Resume"), f"a:resume:{serial}"),
                     self._btn("⏹ " + self._t("Stop"), f"a:stopask:{serial}")])
        rows.append([self._btn("💡 " + self._t("On"), f"a:lighton:{serial}"),
                     self._btn("🌑 " + self._t("Off"), f"a:lightoff:{serial}"),
                     self._btn("📷 " + self._t("Photo"), f"photo:{serial}")])
        rows.append([self._btn("↻ " + self._t("Refresh"), f"p:{serial}"),
                     self._btn("‹ " + self._t("Printers"), "menu")])
        return self._keyboard(rows)

    def _state_label(self, state: PrinterState) -> str:
        return {
            PrinterState.PRINTING: self._t("Printing"),
            PrinterState.PAUSED: self._t("Paused"),
            PrinterState.FINISHED: self._t("Finished"),
            PrinterState.ERROR: self._t("Error"),
            PrinterState.IDLE: self._t("Ready"),
        }.get(state, "Offline")

    def _icon(self, serial: str) -> str:
        tel = self.app.telemetry.get(serial)
        state = tel.state if tel else PrinterState.OFFLINE
        return {PrinterState.PRINTING: "🟢", PrinterState.PAUSED: "⏸",
                PrinterState.ERROR: "🔴", PrinterState.OFFLINE: "⚪️"}.get(state, "🖨")

    # Telegram API

    @staticmethod
    def _btn(text: str, data: str) -> dict:
        return {"text": text, "callback_data": data}

    @staticmethod
    def _keyboard(rows: list[list[dict]]) -> str:
        return json.dumps({"inline_keyboard": rows})

    def _send(self, text: str, reply_markup: str | None) -> None:
        params = {"chat_id": self._chat, "text": text}
        if reply_markup:
            params["reply_markup"] = reply_markup
        _post(self._token, "sendMessage", params)

    def _edit(self, message_id: int, text: str, reply_markup: str | None) -> None:
        params = {"chat_id": self._chat, "message_id": str(message_id), "text": text}
        if reply_markup:
            params["reply_markup"] = reply_markup
        _post(self._token, "editMessageText", params)

    def _answer(self, callback_id: str, text: str) -> None:
        _post(self._token, "answerCallbackQuery", {"callback_query_id": callback_id, "text": text})
