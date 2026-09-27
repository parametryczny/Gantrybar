from __future__ import annotations

"""GTK side of the smart sockets: the setup window with live test buttons, and the confirmations.

gi is already pinned in app.py.
"""

import threading
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from . import i18n
from .panelwindow import panel_header
from .smartplug import KINDS, SmartPlug, kind_title


def _ask(app: Any, title: str, detail: str, action: str, parent: Gtk.Window | None = None,
         default_action: bool = False) -> bool:
    dialog = Gtk.MessageDialog(transient_for=parent or app.window, modal=True,
                               message_type=Gtk.MessageType.WARNING, buttons=Gtk.ButtonsType.NONE, text=title)
    dialog.format_secondary_text(detail)
    dialog.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
    button = dialog.add_button(action, Gtk.ResponseType.OK)
    button.get_style_context().add_class("destructive-action")
    dialog.set_default_response(Gtk.ResponseType.OK if default_action else Gtk.ResponseType.CANCEL)
    result = dialog.run() == Gtk.ResponseType.OK
    dialog.destroy()
    return result


def power(app: Any, on: bool, serial: str) -> None:
    """From the card: cutting power under a running print asks first."""
    controller = app.smart_plugs
    if not on and controller.is_busy(serial):
        name = next((p.name for p in app.printers if p.serial == serial), serial)
        if not _ask(app, i18n.t("Cut the power to {0}?").format(name),
                    i18n.t("The printer is printing. Cutting the power ends the print and it cannot be resumed."),
                    i18n.t("Cut the power")):
            return
    controller.power(on, serial)


def confirm_emergency_off(app: Any) -> None:
    """The button: one question, the dangerous answer as the default, then everything off at once."""
    store = app.smart_plugs.store
    count = sum(1 for serial in store.serials() if (plug := store.plug(serial)) is not None and plug.includeInEmergency)
    if count == 0:
        dialog = Gtk.MessageDialog(transient_for=app.window, modal=True, message_type=Gtk.MessageType.INFO,
                                   buttons=Gtk.ButtonsType.OK, text=i18n.t("No smart sockets are set up"))
        dialog.format_secondary_text(i18n.t("Add a socket to a printer: its card ⋯ menu → Power → Set up socket…"))
        dialog.run(); dialog.destroy()
        return
    from .emergency import confirm
    names = sorted(next((p.name for p in app.printers if p.serial == serial), serial)
                   for serial in store.serials() if (plug := store.plug(serial)) is not None and plug.includeInEmergency)
    if not confirm(app.window, names):
        return

    def job() -> None:
        lines = app.smart_plugs.emergency_off()

        def report() -> bool:
            dialog = Gtk.MessageDialog(transient_for=app.window, modal=False, message_type=Gtk.MessageType.INFO,
                                       buttons=Gtk.ButtonsType.OK, text=i18n.t("Emergency power-off"))
            dialog.format_secondary_text("\n".join(lines))
            dialog.connect("response", lambda d, _r: d.destroy())
            dialog.show()
            return False
        GLib.idle_add(report)
    threading.Thread(target=job, daemon=True).start()


class SmartPlugDialog(Gtk.Dialog):
    """Setting up the socket that feeds one printer, with buttons that switch it for real, so a wrong IP
    or outlet number shows up here rather than in an emergency."""

    def __init__(self, app: Any, serial: str) -> None:
        name = next((p.name for p in app.printers if p.serial == serial), serial)
        title = i18n.t("Smart socket — {0}").format(name)
        super().__init__(title=title, transient_for=app.window, modal=False)
        panel_header(self, title)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_default_size(520, -1)
        self.app, self.serial = app, serial
        store = app.smart_plugs.store

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        root.get_style_context().add_class("settings-root")
        intro = Gtk.Label(label=i18n.t("The socket or power-strip outlet this printer is plugged into. Gantry switches it from the card, from automations, from Telegram, and all at once with Emergency power-off."),
                          xalign=0, wrap=True)
        intro.get_style_context().add_class("settings-hint")
        root.pack_start(intro, False, False, 0)

        self.kind = Gtk.ComboBoxText()
        for kind in KINDS:
            self.kind.append(kind, kind_title(kind))
        self.kind.connect("changed", lambda *_: self._kind_changed())
        self.host, self.channel, self.entity = Gtk.Entry(), Gtk.Entry(), Gtk.Entry()
        self.on_url, self.off_url, self.user = Gtk.Entry(), Gtk.Entry(), Gtk.Entry()
        self.secret = Gtk.Entry(visibility=False)
        self.auto_off = Gtk.Entry(placeholder_text=i18n.t("never"))
        self.channel.set_placeholder_text("1")
        self.entity.set_placeholder_text("switch.p1s_zasilanie")
        self.on_url.set_placeholder_text("http://192.168.1.60/on")
        self.off_url.set_placeholder_text("http://192.168.1.60/off")
        self.user.set_placeholder_text("admin")
        self.emergency = Gtk.CheckButton(label=i18n.t("Include in Emergency power-off"))

        grid = Gtk.Grid(row_spacing=8, column_spacing=12)
        self.rows: dict[Gtk.Widget, Gtk.Label] = {}
        entries = [(i18n.t("Type"), self.kind), (i18n.t("Address"), self.host), (i18n.t("Outlet"), self.channel),
                   (i18n.t("Entity"), self.entity), (i18n.t("URL to switch on"), self.on_url),
                   (i18n.t("URL to switch off"), self.off_url), (i18n.t("Login"), self.user),
                   (i18n.t("Password / token"), self.secret), (i18n.t("Switch off after print (min)"), self.auto_off),
                   ("", self.emergency)]
        for row, (text, widget) in enumerate(entries):
            label = Gtk.Label(label=text, xalign=1)
            label.get_style_context().add_class("settings-hint")
            widget.set_hexpand(True)
            grid.attach(label, 0, row, 1, 1)
            grid.attach(widget, 1, row, 1, 1)
            self.rows[widget] = label
        root.pack_start(grid, False, False, 0)

        tests = Gtk.Box(spacing=6)
        for text, value in ((i18n.t("Switch on"), True), (i18n.t("Switch off"), False), (i18n.t("Read state"), None)):
            button = Gtk.Button(label=text)
            button.connect("clicked", lambda _b, v=value: self._test(v))
            tests.pack_start(button, False, False, 0)
        root.pack_start(tests, False, False, 0)
        self.status = Gtk.Label(label="", xalign=0, wrap=True)
        self.status.get_style_context().add_class("settings-hint")
        root.pack_start(self.status, False, False, 0)
        self.get_content_area().pack_start(root, True, True, 0)

        self.add_button(i18n.t("Remove socket"), Gtk.ResponseType.REJECT)
        self.add_button(i18n.t("Close"), Gtk.ResponseType.CLOSE)
        self.add_button(i18n.t("Save"), Gtk.ResponseType.OK)
        self.set_default_response(Gtk.ResponseType.OK)
        self.connect("response", self._response)

        plug = store.plug(serial) or SmartPlug()
        self.kind.set_active_id(plug.kind)
        self.host.set_text(plug.host)
        self.channel.set_text(str(plug.channel))
        self.entity.set_text(plug.entityID or "")
        self.on_url.set_text(plug.onURL or "")
        self.off_url.set_text(plug.offURL or "")
        self.user.set_text(plug.username or "")
        self.secret.set_text(store.secret(serial) or "")
        self.auto_off.set_text(str(plug.autoOffMinutes) if plug.autoOffMinutes else "")
        self.emergency.set_active(plug.includeInEmergency)
        if store.plug(serial) is None:
            self.status.set_text(i18n.t("No socket saved yet."))
        self.show_all()
        self._kind_changed()

    def _show(self, widget: Gtk.Widget, visible: bool) -> None:
        widget.set_visible(visible)
        self.rows[widget].set_visible(visible)

    def _kind_changed(self) -> None:
        kind = self.kind.get_active_id() or "tasmota"
        device = kind in ("tasmota", "shelly", "shellyRPC")
        self._show(self.host, kind != "http")
        self._show(self.channel, device)
        self._show(self.entity, kind == "homeAssistant")
        self._show(self.on_url, kind == "http")
        self._show(self.off_url, kind == "http")
        self._show(self.user, device)
        self._show(self.secret, kind != "http")
        self.rows[self.host].set_text(i18n.t("Home Assistant URL") if kind == "homeAssistant" else i18n.t("Address"))
        self.host.set_placeholder_text("http://192.168.1.10:8123" if kind == "homeAssistant" else "192.168.1.60")
        self.rows[self.secret].set_text(i18n.t("Access token") if kind == "homeAssistant" else i18n.t("Password"))

    def _current(self) -> SmartPlug:
        def text(entry: Gtk.Entry) -> str | None:
            value = entry.get_text().strip()
            return value or None
        try:
            channel = max(1, int(self.channel.get_text().strip() or "1"))
        except ValueError:
            channel = 1
        try:
            minutes = int(self.auto_off.get_text().strip() or "0")
        except ValueError:
            minutes = 0
        return SmartPlug(kind=self.kind.get_active_id() or "tasmota", host=text(self.host) or "", channel=channel,
                         entityID=text(self.entity), onURL=text(self.on_url), offURL=text(self.off_url),
                         username=text(self.user), autoOffMinutes=minutes if minutes > 0 else None,
                         includeInEmergency=self.emergency.get_active())

    def _test(self, on: bool | None) -> None:
        plug = self._current()
        if plug.problem:
            self.status.set_text(plug.problem)
            return
        if on is False and self.app.smart_plugs.is_busy(self.serial):
            if not _ask(self.app, i18n.t("The printer is printing"), i18n.t("Switching the socket off now ends the print."),
                        i18n.t("Switch off"), parent=self):
                return
        secret = self.secret.get_text()
        self.status.set_text(i18n.t("Talking to the socket…"))

        def job() -> None:
            try:
                state = plug.send(on, secret)
                if state is True:
                    message = i18n.t("The socket reports: on.")
                elif state is False:
                    message = i18n.t("The socket reports: off.")
                elif on is None:
                    message = i18n.t("The socket answered but did not say whether it is on.")
                else:
                    message = i18n.t("Sent. The socket did not report its state.")
            except RuntimeError as error:
                message = str(error)
            GLib.idle_add(lambda: (self.status.set_text(message), False)[1])
        threading.Thread(target=job, daemon=True).start()

    def _response(self, _dialog: Gtk.Dialog, response: int) -> None:
        store = self.app.smart_plugs.store
        if response == Gtk.ResponseType.OK:
            plug = self._current()
            if plug.problem:
                self.status.set_text(plug.problem)
                return
            store.set(self.serial, plug, self.secret.get_text())
        elif response == Gtk.ResponseType.REJECT:
            store.set(self.serial, None, None)
        self.destroy()
