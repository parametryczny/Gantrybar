from __future__ import annotations

"""The Wi-Fi socket or power-strip outlet that feeds a printer.

Same JSON as macOS and Windows (``smart-plugs-v1`` in the config, keyed by printer serial). The password
or Home Assistant token goes to the Secret Service under ``smart-plug:<serial>``, never into the config.

This module has no GTK import, so the request building and the parsing are unit-tested headless. The
confirmation dialogs and the setup window live in ``smartplugdialog``.
"""

import json
import threading
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable

from . import i18n
from .core import PrinterState

KINDS = ("tasmota", "shelly", "shellyRPC", "homeAssistant", "http")
CONFIG_KEY = "smart-plugs-v1"
TIMEOUT = 6


def kind_title(kind: str) -> str:
    return {"tasmota": "Tasmota", "shelly": "Shelly Gen1", "shellyRPC": "Shelly Plus / Pro / Gen3",
            "homeAssistant": "Home Assistant"}.get(kind) or i18n.t("Custom URLs")


@dataclass
class SmartPlug:
    kind: str = "tasmota"
    host: str = ""
    channel: int = 1
    entityID: str | None = None
    onURL: str | None = None
    offURL: str | None = None
    username: str | None = None
    autoOffMinutes: int | None = None
    includeInEmergency: bool = True

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "SmartPlug":
        kind = data.get("kind") if data.get("kind") in KINDS else "http"
        try:
            channel = max(1, int(data.get("channel", 1) or 1))
        except (TypeError, ValueError):
            channel = 1
        minutes = data.get("autoOffMinutes")
        return cls(kind=kind, host=str(data.get("host") or ""), channel=channel,
                   entityID=data.get("entityID"), onURL=data.get("onURL"), offURL=data.get("offURL"),
                   username=data.get("username"),
                   autoOffMinutes=int(minutes) if isinstance(minutes, (int, float)) and minutes > 0 else None,
                   includeInEmergency=bool(data.get("includeInEmergency", True)))

    def to_dict(self) -> dict[str, Any]:
        return {key: value for key, value in self.__dict__.items() if value is not None}

    @property
    def problem(self) -> str | None:
        if self.kind in ("tasmota", "shelly", "shellyRPC"):
            return None if self.host.strip() else i18n.t("Enter the socket's IP address.")
        if self.kind == "homeAssistant":
            if not self.host.strip():
                return i18n.t("Enter the Home Assistant address.")
            if not (self.entityID or "").strip():
                return i18n.t("Enter the Home Assistant entity, e.g. switch.printer.")
            return None
        return None if (self.onURL or "").strip() and (self.offURL or "").strip() else i18n.t("Enter both URLs.")

    def _base(self) -> str:
        raw = self.host.strip()
        with_scheme = raw if "://" in raw else f"http://{raw}"
        return with_scheme.rstrip("/")

    def request(self, on: bool | None, secret: str | None) -> urllib.request.Request | None:
        """The request that switches the socket, or reads it when ``on`` is None."""
        channel = max(1, int(self.channel))
        headers: dict[str, str] = {}
        data: bytes | None = None
        method = "GET"
        if self.kind == "tasmota":
            command = f"Power{channel}" + ("" if on is None else (" On" if on else " Off"))
            query = {"cmnd": command}
            if secret:
                query.update({"user": self.username or "admin", "password": secret})
            url = f"{self._base()}/cm?{urllib.parse.urlencode(query, quote_via=urllib.parse.quote)}"
        elif self.kind == "shelly":
            url = f"{self._base()}/relay/{channel - 1}" + ("" if on is None else f"?turn={'on' if on else 'off'}")
        elif self.kind == "shellyRPC":
            url = (f"{self._base()}/rpc/Switch.GetStatus?id={channel - 1}" if on is None
                   else f"{self._base()}/rpc/Switch.Set?id={channel - 1}&on={'true' if on else 'false'}")
        elif self.kind == "homeAssistant":
            entity = (self.entityID or "").strip()
            if on is None:
                url = f"{self._base()}/api/states/{urllib.parse.quote(entity)}"
            else:
                # homeassistant.turn_on/off works for switch, light, fan and input_boolean alike.
                url = f"{self._base()}/api/services/homeassistant/turn_{'on' if on else 'off'}"
                method = "POST"
                data = json.dumps({"entity_id": entity}).encode("utf-8")
                headers["Content-Type"] = "application/json"
            if secret:
                headers["Authorization"] = f"Bearer {secret}"
        else:
            if on is None:
                return None
            url = ((self.onURL if on else self.offURL) or "").strip()
            if not url.lower().startswith(("http://", "https://")):
                return None
        return urllib.request.Request(url, data=data, headers=headers, method=method)

    def send(self, on: bool | None, secret: str | None) -> bool | None:
        """Switches (or reads) the socket and returns the state it reports. Raises RuntimeError."""
        if self.problem:
            raise RuntimeError(self.problem)
        request = self.request(on, secret)
        if request is None:
            raise RuntimeError(i18n.t("The address is not a valid URL."))
        handlers: list[Any] = []
        if secret and self.kind in ("shelly", "shellyRPC"):
            # Basic for Shelly Gen1, digest for Gen2 and later; both answer the same challenge.
            passwords = urllib.request.HTTPPasswordMgrWithDefaultRealm()
            passwords.add_password(None, request.full_url, self.username or "admin", secret)
            handlers += [urllib.request.HTTPBasicAuthHandler(passwords), urllib.request.HTTPDigestAuthHandler(passwords)]
        opener = urllib.request.build_opener(*handlers)
        try:
            with opener.open(request, timeout=TIMEOUT) as response:
                body = response.read(64 * 1024).decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise RuntimeError(i18n.t("The socket refused the login. Check the password or token.")) from error
            raise RuntimeError(i18n.t("The socket answered with HTTP {0}.").format(error.code)) from error
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise RuntimeError(str(getattr(error, "reason", error))) from error
        return parse_state(self.kind, self.channel, body)


def parse_state(kind: str, channel: int, body: str) -> bool | None:
    """Reads "on" out of a device's reply; None when the reply does not say."""
    try:
        data = json.loads(body)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None

    def word(value: Any) -> bool | None:
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return value != 0
        if isinstance(value, str):
            return {"on": True, "true": True, "1": True, "off": False, "false": False, "0": False}.get(value.lower())
        return None

    if kind == "tasmota":
        value = word(data.get(f"POWER{channel}"))
        return value if value is not None or channel != 1 else word(data.get("POWER"))
    return word(data.get({"shelly": "ison", "shellyRPC": "output", "homeAssistant": "state"}.get(kind, "")))


def secret_key(serial: str) -> str:
    return f"smart-plug:{serial}"


class SmartPlugStore:
    def __init__(self, app: Any) -> None:
        self.app = app

    def _all(self) -> dict[str, dict[str, Any]]:
        value = self.app.config.data.get(CONFIG_KEY)
        return value if isinstance(value, dict) else {}

    def plug(self, serial: str) -> SmartPlug | None:
        raw = self._all().get(serial)
        return SmartPlug.from_dict(raw) if isinstance(raw, dict) else None

    def serials(self) -> list[str]:
        return list(self._all().keys())

    def is_empty(self) -> bool:
        return not self._all()

    def secret(self, serial: str) -> str | None:
        try:
            return self.app.secrets.get(secret_key(serial))
        except Exception:   # the Secret Service may be missing or locked; the socket can still work without
            return None

    def set(self, serial: str, plug: SmartPlug | None, secret: str | None) -> None:
        values = dict(self._all())
        if plug is None:
            values.pop(serial, None)
        else:
            values[serial] = plug.to_dict()
        self.app.config.data[CONFIG_KEY] = values
        self.app.config.save()
        try:
            if plug is not None and secret:
                self.app.secrets.set(secret_key(serial), secret)
            else:
                self.app.secrets.delete(secret_key(serial))
        except Exception:
            pass


@dataclass
class SmartPlugController:
    """Switches sockets, the emergency "everything off", and switching off after a print. Mirrors macOS.

    ``run_async`` and ``on_main`` are injected so tests run without threads or a GLib main loop.
    """
    app: Any
    notify: Callable[[str, str], None]
    telegram: Callable[[str, str, str], None]
    run_async: Callable[[Callable[[], None]], None] = field(
        default=lambda job: threading.Thread(target=job, daemon=True).start())
    on_main: Callable[[Callable[[], None]], None] = field(default=lambda job: job())
    schedule: Callable[[float, Callable[[], None]], Any] | None = None
    cancel: Callable[[Any], None] | None = None
    _last: dict[str, PrinterState] = field(default_factory=dict)
    _auto_off: dict[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.store = SmartPlugStore(self.app)

    def _name(self, serial: str) -> str:
        return next((p.name for p in self.app.printers if p.serial == serial), serial)

    def is_busy(self, serial: str) -> bool:
        telemetry = self.app.telemetry.get(serial)
        return telemetry is not None and telemetry.state in (PrinterState.PRINTING, PrinterState.PAUSED)

    def _cancel_auto_off(self, serial: str) -> None:
        handle = self._auto_off.pop(serial, None)
        if handle is not None and self.cancel is not None:
            self.cancel(handle)

    def power(self, on: bool, serial: str, reason: str | None = None) -> None:
        """Switches one socket. Confirmation, when wanted, is the caller's (see smartplugdialog)."""
        plug = self.store.plug(serial)
        printer = self._name(serial)
        if plug is None:
            self.notify(printer, i18n.t("No smart socket is set up for this printer."))
            return
        if not on:
            self._cancel_auto_off(serial)
        secret = self.store.secret(serial)

        def job() -> None:
            try:
                plug.send(on, secret)
            except RuntimeError as error:
                message = str(error)
                self.on_main(lambda: self.notify(i18n.t("Could not switch the socket"), f"{printer}: {message}"))
                self.telegram(printer, i18n.t("Could not switch the socket"), message)
                return
            title = i18n.t("Socket switched on") if on else i18n.t("Socket switched off")
            body = i18n.t("Automation: {0}").format(reason) if reason else printer
            self.on_main(lambda: self.notify(title, body))
            self.telegram(printer, title, reason or "")
        self.run_async(job)

    def emergency_off(self) -> list[str]:
        """Every socket marked for emergencies, off at once. Blocks until all answered or timed out."""
        for serial in list(self._auto_off):
            self._cancel_auto_off(serial)
        jobs = []
        for serial in self.store.serials():
            plug = self.store.plug(serial)
            if plug is not None and plug.includeInEmergency:
                jobs.append((self._name(serial), plug, self.store.secret(serial)))
        results: list[tuple[str, str | None]] = []
        lock = threading.Lock()

        def switch(printer: str, plug: SmartPlug, secret: str | None) -> None:
            try:
                plug.send(False, secret)
                outcome: str | None = None
            except RuntimeError as error:
                outcome = str(error)
            with lock:
                results.append((printer, outcome))
        # Every request leaves at once; a socket that does not answer must not hold up the others.
        threads = [threading.Thread(target=switch, args=job, daemon=True) for job in jobs]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(TIMEOUT + 2)
        lines = [f"✓ {printer}" if failure is None else f"✕ {printer}: {failure}"
                 for printer, failure in sorted(results)]
        failed = sum(1 for _, failure in results if failure is not None) + (len(jobs) - len(results))
        title = (i18n.t("Emergency: every socket is off") if failed == 0
                 else i18n.t("Emergency: {0} sockets did not switch off").format(failed))
        self.on_main(lambda: self.notify(title, "\n".join(lines)))
        self.telegram("Gantry", title, "\n".join(lines))
        return lines

    def observe(self, serial: str, current_state: PrinterState) -> None:
        """Called for every telemetry update; arms the switch-off some minutes after a finished print."""
        previous = self._last.get(serial)
        self._last[serial] = current_state
        if current_state in (PrinterState.PRINTING, PrinterState.PAUSED):
            self._cancel_auto_off(serial)
            return
        if current_state != PrinterState.FINISHED or previous is None or previous == PrinterState.FINISHED:
            return
        plug = self.store.plug(serial)
        if plug is None or not plug.autoOffMinutes or self.schedule is None:
            return
        self._cancel_auto_off(serial)
        minutes = plug.autoOffMinutes

        def fire() -> bool:
            self._auto_off.pop(serial, None)
            # Somebody may have started the next print in the meantime.
            if not self.is_busy(serial):
                self.power(False, serial, reason=i18n.t("{0} min after the print finished").format(minutes))
            return False
        self._auto_off[serial] = self.schedule(minutes * 60, fire)
