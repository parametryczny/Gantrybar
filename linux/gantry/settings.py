from __future__ import annotations

"""GTK port of the macOS Settings window.

Six panes picked from a sidebar, each one a two-column grid: captions trailing in the left column,
controls leading in the right, one shared vertical axis down the whole window. No cards, no custom
palette, no pill bar — the system theme draws all of it, which is the point. The window fits whichever
pane is showing rather than carrying a fixed size.

Settings apply as controls change (see _connect_live_updates), so the header bar's button only closes.
"""

import math
import threading
import subprocess
from datetime import datetime
from typing import Any

from gi.repository import Gdk, GLib, Gtk  # type: ignore

from . import __version__
from . import edition
from . import i18n
from .dockplacement import ROW_MARGIN, ROWS, position_title
from .storage import autostart_enabled, set_autostart


#: The edge-dock position picker, the same size as on macOS and Windows.
POSITION_PICKER_WIDTH = 124
POSITION_PICKER_HEIGHT = 78

NOTICE_LABELS = {"finished_notice": "Print finished", "error_notice": "Printer errors", "paused_notice": "Print paused", "low_notice": "Low filament", "finishing_soon_notice": "Print finishing in 10 minutes", "humidity_notice": "High AMS humidity", "offline_notice": "Connection lost"}


class SettingsPane(Gtk.Grid):
    """One pane. Mirrors the macOS SettingsGrid row by row, including its metrics, so the two
    platforms put a caption and its control in the same place."""

    CAPTION_COLUMN = 164
    CONTROL_COLUMN = 336
    COLUMN_SPACING = 10
    ROW_SPACING = 9
    INSET = 20

    def __init__(self) -> None:
        super().__init__(column_spacing=self.COLUMN_SPACING, row_spacing=self.ROW_SPACING)
        self.set_border_width(self.INSET)
        self.set_valign(Gtk.Align.START)
        self._row = 0

    def _caption(self, text: str) -> Gtk.Label:
        label = Gtk.Label(label=text, xalign=1)
        label.set_size_request(self.CAPTION_COLUMN, -1)
        label.set_valign(Gtk.Align.BASELINE)
        label.get_style_context().add_class("settings-label")
        return label

    def field(self, caption: str, widget: Gtk.Widget, baseline: bool = True) -> None:
        """Caption on the left, one control on the right."""
        label = self._caption(caption)
        if not baseline:
            label.set_valign(Gtk.Align.CENTER)
            widget.set_valign(Gtk.Align.CENTER)
        widget.set_halign(Gtk.Align.START)
        self.attach(label, 0, self._row, 1, 1)
        self.attach(widget, 1, self._row, 1, 1)
        self._row += 1

    def group(self, caption: str, widgets: list[Gtk.Widget]) -> None:
        """A caption once, then a column of checkboxes beside it — the macOS 'group' row."""
        if not widgets:
            return
        label = self._caption(caption)
        label.set_valign(Gtk.Align.BASELINE)
        self.attach(label, 0, self._row, 1, 1)
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        column.set_halign(Gtk.Align.START)
        for widget in widgets:
            column.pack_start(widget, False, False, 0)
        self.attach(column, 1, self._row, 1, 1)
        self._row += 1

    def aligned(self, widget: Gtk.Widget) -> None:
        """No caption: the control keeps the control column, so it lines up with the ones above."""
        widget.set_halign(Gtk.Align.START)
        self.attach(widget, 1, self._row, 1, 1)
        self._row += 1

    def wide(self, widget: Gtk.Widget) -> None:
        """Spans both columns, for text that has no caption of its own."""
        self.attach(widget, 0, self._row, 2, 1)
        self._row += 1

    def section(self, title: str) -> None:
        """A rule plus a heading across both columns, the way a preferences window separates topics."""
        rule = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        rule.set_margin_top(8)
        self.attach(rule, 0, self._row, 2, 1)
        self._row += 1
        heading = Gtk.Label(label=title, xalign=0)
        heading.get_style_context().add_class("settings-heading")
        self.attach(heading, 0, self._row, 2, 1)
        self._row += 1

    def note(self, text: str, indent: bool = True) -> Gtk.Label:
        label = Gtk.Label(label=text, xalign=0, wrap=True)
        label.set_max_width_chars(52)
        label.get_style_context().add_class("settings-hint")
        if indent:
            self.aligned(label)
        else:
            self.wide(label)
        return label


class SettingsDialog(Gtk.Dialog):
    # Same panes, same order, as the macOS window: SettingsPaneID.visible.
    PANES = ("general", "appearance", "notifications", "windows", "integrations", "advanced")
    # Integrations and Advanced are full-edition only; LITE has no Telegram, no LAN server and no
    # developer mode, so it shows four panes.
    LITE_PANES = ("general", "appearance", "notifications", "windows")

    def __init__(self, app: Any) -> None:
        # A header-bar dialog, which is what a GTK preferences window is. The button closes; the
        # settings themselves are applied as they change.
        super().__init__(title=i18n.t("Settings"), transient_for=app.window, modal=True,
                         use_header_bar=True)
        self.app = app
        self.pl = app.language == "pl"
        self._ready = False
        self._original_transparency = str(app.config.data.get("panel_transparency", "low"))
        self.add_button(i18n.t("Done"), Gtk.ResponseType.OK)
        self.set_resizable(True)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        # A Gtk.Stack asks for the size of its largest child by default, which would give every pane
        # the height of the tallest one — the opposite of a window that fits the pane on screen.
        self.stack.set_hhomogeneous(False)
        self.stack.set_vhomogeneous(False)
        sidebar = Gtk.StackSidebar()
        sidebar.set_stack(self.stack)
        sidebar.set_size_request(150, -1)

        # No padding class on the body: the sidebar runs flush to the window edge, the way a
        # preferences sidebar does, and each pane carries its own inset.
        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        body.pack_start(sidebar, False, False, 0)
        body.pack_start(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL), False, False, 0)
        body.pack_start(self.stack, True, True, 0)
        self.get_content_area().pack_start(body, True, True, 0)

        # Every pane is BUILT, including the ones this edition does not show: save() reads their
        # widgets, and a control built from the stored config writes back exactly what it read, so a
        # full Gantry sharing this config file is never edited behind the user's back.
        self.panes: dict[str, Gtk.Widget] = {}
        builders = {"general": self._general, "appearance": self._appearance,
                    "notifications": self._notifications, "windows": self._windows,
                    "integrations": self._integrations, "advanced": self._advanced}
        visible = self.PANES if edition.HAS_EXTRAS else self.LITE_PANES
        for name in self.PANES:
            pane = SettingsPane()
            builders[name](pane)
            self.panes[name] = pane
            if name in visible:
                self.stack.add_titled(self._scroller(pane), name, self._pane_title(name))

        self.stack.connect("notify::visible-child", self._pane_changed)
        self.show_all()
        self.release_link.hide()
        self.install_update.hide()
        self._connect_live_updates()
        self._ready = True
        self._pane_changed()

    @staticmethod
    def _scroller(pane: Gtk.Widget) -> Gtk.Widget:
        """The window fits its pane, so this only ever scrolls on a screen too short to show one."""
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(pane)
        return scroll

    @staticmethod
    def _pane_title(name: str) -> str:
        return {"general": i18n.t("General"), "appearance": i18n.t("Appearance"),
                "notifications": i18n.t("Notifications"), "windows": i18n.t("Windows and strip"),
                "integrations": i18n.t("Integrations"), "advanced": i18n.t("Advanced")}[name]

    def _pane_changed(self, *_args: object) -> None:
        """Title and height follow the pane, the way the macOS window does: the top edge stays put
        and the bottom moves to whatever the pane actually needs.

        The title is set here because it must be right before the pane is on screen. The fit waits
        for an idle turn: asking a pane how tall it wants to be in the same turn it became visible
        answers with the height it had a moment ago."""
        name = self.stack.get_visible_child_name()
        if name is None:
            return
        header = self.get_header_bar()
        if header is not None:
            header.set_title(self._pane_title(name))
        GLib.idle_add(self._fit_to_pane, name)

    def _fit_to_pane(self, name: str) -> bool:
        if name != self.stack.get_visible_child_name():
            return False   # switched again while we waited; that switch owns the fit
        pane = self.panes.get(name)
        if pane is None:
            return False
        width = (SettingsPane.CAPTION_COLUMN + SettingsPane.CONTROL_COLUMN
                 + SettingsPane.COLUMN_SPACING + SettingsPane.INSET * 2 + 151)
        natural = pane.get_preferred_height_for_width(width - 151)[1] + SettingsPane.INSET
        screen = self.get_screen()
        limit = (screen.get_height() - 120) if screen is not None else 760
        self.resize(width, max(240, min(limit, natural)))
        return False

    @property
    def scroll(self) -> Gtk.Widget:
        """The visible pane's scroller, for the preview renderer."""
        page = self.stack.get_visible_child()
        if page is not None:
            return page
        children = self.stack.get_children()
        return children[0] if children else self.stack

    # ----------------------------------------------------------------- panes

    def _general(self, pane: SettingsPane) -> None:
        # Wypelniane tym, co znalazl loader, wiec nowy plik i18n/<kod>.json pojawia sie sam.
        self.language = Gtk.ComboBoxText()
        for code, name in i18n.available():
            self.language.append(code, name)
        self.language.set_active_id(self.app.language)
        pane.field(i18n.t("Language"), self.language)

        self.autostart = self._check(i18n.t("Start after login"), autostart_enabled())
        self.spoolbase = self._check(i18n.t("Spoolbase — filament stock"),
                                     bool(self.app.config.data.get("spoolbase_enabled", True)))
        # Spoolbase is a full-edition tool, so LITE's basics are language and launch at login only.
        pane.group(i18n.t("Options"),
                   [self.autostart, self.spoolbase] if edition.HAS_EXTRAS else [self.autostart])

        self._build_updates(pane)
        if not edition.HAS_EXTRAS:
            self._build_about(pane)

    def _build_updates(self, pane: SettingsPane) -> None:
        """Built for every edition (save() reads auto_update and update_format), shown only by the
        full one: LITE never checks for or installs updates."""
        self.update_status = Gtk.Label(label=i18n.t("Version {0}").format(__version__),
                                       xalign=0, wrap=True)
        self.update_status.get_style_context().add_class("settings-hint")
        self.update_button = Gtk.Button(label=i18n.t("Check for updates"))
        self.update_button.connect("clicked", self._check_updates)
        self.release_link = Gtk.LinkButton.new_with_label(
            "https://github.com/parametryczny/gantrybar/releases", i18n.t("Open release"))
        self.release_link.set_halign(Gtk.Align.START)
        self.release_link.set_no_show_all(True)
        self.install_update = Gtk.Button(label=i18n.t("Download and open installer"))
        self.install_update.set_halign(Gtk.Align.START)
        self.install_update.set_no_show_all(True)
        self.install_update.connect("clicked", self._install_update)
        self._available_release: object | None = None
        self.auto_update = self._check(i18n.t("Automatically check for updates"),
                                       bool(self.app.config.data.get("auto_update_check", False)))
        self.update_format = Gtk.ComboBoxText()
        for value, label in (("auto", i18n.t("Automatically")), ("deb", i18n.t("DEB")),
                             ("rpm", i18n.t("RPM")), ("appimage", i18n.t("AppImage"))):
            self.update_format.append(value, label)
        selected = str(self.app.config.data.get("linux_update_format", "auto"))
        self.update_format.set_active_id(selected if selected in {"auto", "deb", "rpm", "appimage"} else "auto")
        self.update_format.connect("changed", self._update_format_changed)
        if not edition.HAS_EXTRAS:
            return
        pane.section(i18n.t("Updates"))
        pane.field(i18n.t("Updates"), self.update_button, baseline=False)
        pane.aligned(self.update_status)
        pane.aligned(self.release_link)
        pane.aligned(self.install_update)
        pane.aligned(self.auto_update)
        pane.field(i18n.t("Update package"), self.update_format)
        pane.note(i18n.t("Automatic selection uses DEB, RPM or AppImage according to your Linux system."))
        self._build_about(pane)

    def _build_about(self, pane: SettingsPane) -> None:
        pane.section(i18n.t("About Gantry"))
        version = Gtk.Label(label=f"Gantry • {i18n.t('Version')} {__version__}", xalign=0)
        version.get_style_context().add_class("settings-version")
        pane.aligned(version)
        links = Gtk.Box(spacing=12)
        for label, uri in (("@parametryczny on GitHub", "https://github.com/parametryczny"),
                           ("@_parametryczny on X", "https://x.com/_parametryczny")):
            link = Gtk.LinkButton.new_with_label(uri, label)
            link.set_relief(Gtk.ReliefStyle.NONE)
            links.pack_start(link, False, False, 0)
        pane.aligned(links)
        support = Gtk.LinkButton.new_with_label("https://buycoffee.to/parametryczny",
                                                i18n.t("☕  Support the project"))
        support.set_halign(Gtk.Align.START)
        support.get_style_context().add_class("settings-support")
        pane.aligned(support)
        pane.note(i18n.t("A virtual coffee gives me a caffeine kick to keep improving Gantry. 🚀"))

    def _appearance(self, pane: SettingsPane) -> None:
        self.theme = Gtk.ComboBoxText()
        self.theme.append("light", i18n.t("Light"))
        self.theme.append("dark", i18n.t("Dark"))
        self.theme.set_active_id(str(self.app.config.data.get("theme", "dark")))
        self.transparency = Gtk.ComboBoxText()
        self.transparency.append("low", i18n.t("Low"))
        self.transparency.append("medium", i18n.t("Medium"))
        self.transparency.append("high", i18n.t("High"))
        self.transparency.set_active_id(self._original_transparency)
        self.transparency.connect("changed", self._preview_transparency)
        pane.field(i18n.t("Appearance"), self.theme)
        pane.field(i18n.t("Transparency"), self.transparency)

        self.monochrome = self._check(i18n.t("Monochrome colours"),
                                      bool(self.app.config.data.get("monochrome", False)))
        self.monochrome.set_tooltip_text(i18n.t("Grey temperatures, calmer AMS colours"))
        pane.aligned(self.monochrome)

        pane.section(i18n.t("Printer cards"))
        self.card_scale = self._scale_row(i18n.t("Card size"), "card_scale_percent", 75, 150)
        pane.field(i18n.t("Card size"), self.card_scale[0], baseline=False)

        self.card_options: dict[str, Gtk.CheckButton] = {}
        for key, english, default in (("card_show_filename", "File name", True),
                                      ("card_show_progress", "Progress", True),
                                      ("card_show_temperatures", "Temperatures", True),
                                      ("card_show_filaments", "Filaments / AMS", True)):
            self.card_options[key] = self._check(i18n.t(english),
                                                 bool(self.app.config.data.get(key, default)))
        self.spool_grams = self._check(i18n.t("Grams on spool (AMS NFC / Spoolbase)"),
                                       bool(self.app.config.data.get("card_show_spool_grams", False)))
        self.details_chip = self._check(i18n.t("Details chip on the card"),
                                        bool(self.app.config.data.get("card_show_details_chip", False)))
        self.details_chip.set_tooltip_text(i18n.t("Shortcut to the detail view; the ⋯ menu always has it"))
        # The card-content switches LITE does not show would otherwise write their default back over
        # the stored value the moment the user touched any other one.
        content = list(self.card_options.values())
        if edition.HAS_EXTRAS:
            content += [self.spool_grams, self.details_chip]
        pane.group(i18n.t("Show on the card"), content)

    def _notifications(self, pane: SettingsPane) -> None:
        self.notices: dict[str, Gtk.CheckButton] = {}
        for key, config_key in (("finished_notice", "notify_finished"),
                                ("finishing_soon_notice", "notify_finishing_soon"),
                                ("error_notice", "notify_error"),
                                ("paused_notice", "notify_paused"),
                                ("low_notice", "notify_low_filament"),
                                ("humidity_notice", "notify_humidity")):
            self.notices[config_key] = self._check(i18n.t(NOTICE_LABELS[key]),
                                                   bool(self.app.config.data.get(config_key)))
        pane.group(i18n.t("Notify me"), list(self.notices.values()))

        pane.section(i18n.t("Quiet hours"))
        self.quiet = self._check(i18n.t("Quiet hours (no notifications)"),
                                 bool(self.app.config.data.get("quiet_hours_enabled", True)))
        pane.aligned(self.quiet)
        quiet_row = Gtk.Box(spacing=7)
        self.quiet_start = Gtk.Entry(text=str(self.app.config.data.get("quiet_hours_start", "22:00")))
        self.quiet_end = Gtk.Entry(text=str(self.app.config.data.get("quiet_hours_end", "07:00")))
        self.quiet_start.set_width_chars(5)
        self.quiet_end.set_width_chars(5)
        quiet_row.pack_start(Gtk.Label(label=i18n.t("from")), False, False, 0)
        quiet_row.pack_start(self.quiet_start, False, False, 0)
        quiet_row.pack_start(Gtk.Label(label=i18n.t("to")), False, False, 0)
        quiet_row.pack_start(self.quiet_end, False, False, 0)
        self.quiet.connect("toggled", lambda check: quiet_row.set_sensitive(check.get_active()))
        quiet_row.set_sensitive(self.quiet.get_active())
        pane.field(i18n.t("Hours"), quiet_row, baseline=False)

    def _windows(self, pane: SettingsPane) -> None:
        self.floating_window = self._check(i18n.t("Show Gantry in a floating window"),
                                           bool(self.app.config.data.get("floating-window-enabled", False)))
        self.always_on_top = self._check(i18n.t("Always on top"),
                                         bool(self.app.config.data.get("floating-window-always-on-top", True)))
        # LITE lives in the tray only: no second surface to offer.
        if edition.HAS_EXTRAS:
            pane.group(i18n.t("Floating window"), [self.floating_window, self.always_on_top])

        self.dock_enabled = self._check(i18n.t("Show the strip on top"),
                                        bool(self.app.config.data.get("edge-dock-enabled", False)))
        from .dockplacement import choices as display_choices
        from .edgedock import connected_displays
        self.dock_display = Gtk.ComboBoxText()
        # Ids in the order of the rows: two identical monitors share a title, and GTK ids must be unique.
        self._dock_display_ids: list[str] = []
        for index, (ident, title, selected) in enumerate(display_choices(
                connected_displays(), str(self.app.config.data.get("edge-dock-display", "")),
                str(self.app.config.data.get("edge-dock-display-name", "")))):
            self.dock_display.append_text(title)
            self._dock_display_ids.append(ident)
            if selected:
                self.dock_display.set_active(index)
        self._dock_left = str(self.app.config.data.get("edge-dock-edge", "right")) == "left"
        row = str(self.app.config.data.get("edge-dock-row", "middle"))
        self._dock_row = row if row in ROWS else "middle"
        self.dock_position = Gtk.DrawingArea()
        self.dock_position.set_size_request(POSITION_PICKER_WIDTH, POSITION_PICKER_HEIGHT)
        self.dock_position.set_halign(Gtk.Align.START)
        self.dock_position.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.dock_position.connect("draw", self._draw_dock_position)
        self.dock_position.connect("button-press-event", self._pick_dock_position)
        self.dock_position.set_tooltip_text(position_title(self._dock_left, self._dock_row))
        self.dock_scale = self._scale_row(i18n.t("Edge dock size"), "edge-dock-scale-percent", 100, 150)
        self.dock_only_printing = self._check(i18n.t("Only printing"),
                                              bool(self.app.config.data.get("edge-dock-only-printing", False)))
        self.dock_pinned = self._check(i18n.t("Keep the strip open"),
                                       bool(self.app.config.data.get("edge-dock-pinned", False)))
        self.dock_camera = self._check(i18n.t("Camera under the strip"),
                                       bool(self.app.config.data.get("edge-dock-camera", False)))
        self.dock_camera.set_tooltip_text(i18n.t("With nothing picked it follows the printer that is printing. Pick printers below and each picture sits under its own row."))
        # Only brands whose stream Gantry can decode are offered a picture, as on macOS and Windows.
        from .camera import supports_camera
        with_camera = set(str(self.app.config.data.get("edge-dock-camera-serials", "")).split("\n")) - {""}
        self.dock_cameras: dict[str, Gtk.CheckButton] = {}
        for printer in list(getattr(self.app, "printers", [])):
            if supports_camera(printer.kind):
                self.dock_cameras[printer.serial] = self._check(printer.name, printer.serial in with_camera)
        # Stored as an exclusion list, so a newly added printer shows up by itself.
        hidden = set(str(self.app.config.data.get("edge-dock-hidden", "")).split("\n")) - {""}
        self.dock_printers: dict[str, Gtk.CheckButton] = {}
        for printer in list(getattr(self.app, "printers", [])):
            self.dock_printers[printer.serial] = self._check(printer.name,
                                                             printer.serial not in hidden)
        if not edition.HAS_EXTRAS:
            return
        pane.section(i18n.t("Edge dock"))
        pane.aligned(self.dock_enabled)
        pane.field(i18n.t("Monitor"), self.dock_display)
        pane.field(i18n.t("Position"), self.dock_position, baseline=False)
        pane.field(i18n.t("Edge dock size"), self.dock_scale[0], baseline=False)
        pane.group(i18n.t("Behaviour"), [self.dock_pinned, self.dock_camera, self.dock_only_printing])
        if self.dock_printers:
            pane.group(i18n.t("Show on the card"), list(self.dock_printers.values()))
        if self.dock_cameras:
            pane.group(i18n.t("Camera for"), list(self.dock_cameras.values()))
        else:
            empty = Gtk.Label(label=i18n.t("No printers"), xalign=0)
            empty.get_style_context().add_class("settings-hint")
            pane.field(i18n.t("Printers"), empty)
        pane.note(i18n.t("A narrow strip pinned to the screen edge, always on top. Hovering expands it to names, clicking opens details."))

    def _integrations(self, pane: SettingsPane) -> None:
        self.telegram_enabled = self._check(i18n.t("Send notifications and control over Telegram"),
                                            bool(self.app.config.data.get("telegram-enabled", False)))
        self.telegram_token = Gtk.Entry(text=str(self.app.config.data.get("telegram-bot-token", "")))
        self.telegram_token.set_placeholder_text("123456:ABC…")
        self.telegram_token.set_width_chars(30)
        self.telegram_chat = Gtk.Entry(text=str(self.app.config.data.get("telegram-chat-id", "")))
        self.telegram_chat.set_placeholder_text("np. 8849748842")
        self.telegram_chat.set_width_chars(30)
        self.telegram_test = Gtk.Button(label=i18n.t("Send test"))
        self.telegram_test.connect("clicked", self._telegram_test)
        self.telegram_status = Gtk.Label(label="", xalign=0, wrap=True)
        self.telegram_status.get_style_context().add_class("settings-hint")

        self.web_enabled = self._check(i18n.t("Preview server (local network, read only)"),
                                       bool(self.app.config.data.get("web_dashboard_enabled", True)))
        from .webserver import PORT, local_ipv4
        address = local_ipv4()
        self.web_address = Gtk.Label(
            label=f"http://{address}:{PORT}" if address else i18n.t("no network address"),
            xalign=0, selectable=True)
        self.web_address.get_style_context().add_class("settings-version")
        if not edition.HAS_EXTRAS:
            return

        pane.group("Telegram", [self.telegram_enabled])
        pane.field(i18n.t("Bot token"), self.telegram_token)
        pane.field("Chat ID", self.telegram_chat)
        pane.field(i18n.t("Test"), self.telegram_test, baseline=False)
        pane.aligned(self.telegram_status)
        pane.note(i18n.t("Create your own bot with @BotFather, paste the token and your chat ID (from @userinfobot). The token stays only on this computer. Guide: docs/telegram-setup.md"))

        pane.section(i18n.t("Web dashboard"))
        pane.aligned(self.web_enabled)
        pane.field(i18n.t("Address"), self.web_address)
        pane.note(i18n.t("Open on a phone on the same Wi-Fi. View only, no control."))

    def _advanced(self, pane: SettingsPane) -> None:
        self.printer_control = self._check(i18n.t("Printer control"),
                                           bool(self.app.config.data.get("printer_control_enabled", False)))
        self.developer = self._check(i18n.t("Developer mode (control + automations)"),
                                     bool(self.app.config.data.get("developer_mode", False)))
        self.allow_scripts = self._check(i18n.t("Allow automations to run scripts and custom commands"),
                                         bool(self.app.config.data.get("allow_script_actions", False)))
        if not edition.HAS_EXTRAS:
            return
        pane.group(i18n.t("Features"), [self.printer_control, self.developer, self.allow_scripts])
        pane.note(i18n.t("Enables temperature, fan and speed controls in Details. Off by default."))
        pane.note(i18n.t("Off by default for safety. Every rule still asks for confirmation the first time it runs."))

    # ------------------------------------------------------------- helpers

    def _dock_square(self, left: bool, row: str) -> tuple[float, float]:
        """Centre of one square in the position picker: three down each side of a small screen."""
        fraction = ROW_MARGIN if row == "top" else 1 - ROW_MARGIN if row == "bottom" else 0.5
        return (14.0 if left else POSITION_PICKER_WIDTH - 14.0), POSITION_PICKER_HEIGHT * fraction

    def _draw_dock_position(self, widget: Gtk.Widget, cr: Any) -> bool:
        """The screen, the strip flush with its side and six squares with the chosen one larger, drawn as on
        macOS and Windows, in the theme's own text colour."""
        ink = widget.get_style_context().get_color(widget.get_state_flags())
        width, height = float(POSITION_PICKER_WIDTH), float(POSITION_PICKER_HEIGHT)

        def rounded(x: float, y: float, w: float, h: float, r: float) -> None:
            cr.new_sub_path()
            cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
            cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
            cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
            cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
            cr.close_path()

        def paint(alpha: float) -> None:
            cr.set_source_rgba(ink.red, ink.green, ink.blue, alpha)

        rounded(0.5, 0.5, width - 1, height - 1, 6)
        paint(0.06); cr.fill_preserve()
        paint(0.35); cr.set_line_width(1); cr.stroke()
        _x, selected_y = self._dock_square(self._dock_left, self._dock_row)
        strip_top = {"top": selected_y - 4, "bottom": selected_y + 4 - 24}.get(self._dock_row, selected_y - 12)
        rounded(2 if self._dock_left else width - 7, strip_top, 5, 24, 2.5)
        paint(0.55); cr.fill()
        for left in (True, False):
            for row in ROWS:
                chosen = left == self._dock_left and row == self._dock_row
                size = 12.0 if chosen else 9.0
                x, y = self._dock_square(left, row)
                rounded(x - size / 2, y - size / 2, size, size, 2.5)
                paint(1.0 if chosen else 0.3); cr.fill()
        return False

    def _pick_dock_position(self, _widget: Gtk.Widget, event: Any) -> bool:
        best, pick = 18.0, None
        for left in (True, False):
            for row in ROWS:
                x, y = self._dock_square(left, row)
                distance = math.hypot(x - event.x, y - event.y)
                if distance <= best:
                    best, pick = distance, (left, row)
        if pick is None or pick == (self._dock_left, self._dock_row):
            return True
        self._dock_left, self._dock_row = pick
        self.dock_position.set_tooltip_text(position_title(*pick))
        self.dock_position.queue_draw()
        self._live_changed()
        return True

    def _preview_transparency(self, combo: Gtk.ComboBoxText) -> None:
        self.app.preview_panel_transparency(combo.get_active_id() or "low")

    def _scale_row(self, label: str, key: str, minimum: int, maximum: int) -> tuple[Gtk.Widget, Gtk.Label]:
        value = max(minimum, min(maximum, round(int(self.app.config.data.get(key, 100)) / 5) * 5))
        row = Gtk.Box(spacing=6)
        minus, plus = Gtk.Button(label="−"), Gtk.Button(label="+")
        display = Gtk.Label(label=f"{value}%"); display.set_size_request(48, -1)
        def step(_button: Gtk.Button, delta: int) -> None:
            current = max(minimum, min(maximum, int(self.app.config.data.get(key, 100)) + delta))
            self.app.config.data[key] = current; display.set_text(f"{current}%")
            minus.set_sensitive(current > minimum); plus.set_sensitive(current < maximum)
            self.app.config.save()
            if key == "card_scale_percent":
                self.app.apply_theme(); self.app.rebuild_cards()
            elif getattr(self.app, "edge_dock", None) is not None:
                self.app.edge_dock.refresh()
        minus.connect("clicked", step, -5); plus.connect("clicked", step, 5)
        minus.set_sensitive(value > minimum); plus.set_sensitive(value < maximum)
        row.pack_start(minus, False, False, 0)
        row.pack_start(display, False, False, 0)
        row.pack_start(plus, False, False, 0)
        return row, display

    def _telegram_test(self, *_args: object) -> None:
        self.save()
        token = self.telegram_token.get_text().strip()
        chat = self.telegram_chat.get_text().strip()
        if not token or not chat:
            self.telegram_status.set_text(i18n.t("Enter a token and chat ID."))
            return
        self.telegram_test.set_sensitive(False)
        self.telegram_status.set_text(i18n.t("Sending…"))

        def work() -> None:
            from .telegram import send_test
            ok = send_test(token, chat, i18n.t("Test"), i18n.t("Connection works."))
            GLib.idle_add(self._telegram_test_done, ok)

        threading.Thread(target=work, daemon=True).start()

    def _telegram_test_done(self, ok: bool) -> bool:
        self.telegram_test.set_sensitive(True)
        self.telegram_status.set_text(
            (i18n.t("Sent — check Telegram.")) if ok
            else (i18n.t("Failed. Check token and chat ID.")))
        return False

    @staticmethod
    def _check(label: str, active: bool) -> Gtk.CheckButton:
        widget = Gtk.CheckButton(label=label)
        widget.set_active(active)
        return widget

    def _check_updates(self, *_args: object) -> None:
        self.update_button.set_sensitive(False)
        self.update_status.set_text(i18n.t("Checking…"))
        self.release_link.hide()
        self.install_update.hide()

        def work() -> None:
            try:
                from .updater import latest_release
                release, error = latest_release(), None
            except Exception as value:
                release, error = None, str(value)
            GLib.idle_add(self._update_check_done, release, error)

        threading.Thread(target=work, daemon=True).start()

    def _update_check_done(self, release: object | None, error: str | None) -> bool:
        from .updater import is_newer
        self.update_button.set_sensitive(True)
        if error or release is None:
            self.update_status.set_text(i18n.t("Could not check for updates."))
            return False
        if is_newer(release.version, __version__):
            self._available_release = release
            self.update_status.set_text(
                i18n.t("Version {0} is available.").format(release.version))
            self._refresh_update_asset()
        else:
            self.update_status.set_text(
                i18n.t("You have the latest version ({0}).").format(__version__))
        return False

    def _update_format_changed(self, *_args: object) -> None:
        if self._available_release is not None:
            self._refresh_update_asset()

    def _refresh_update_asset(self) -> None:
        release = self._available_release
        if release is None: return
        from .updater import select_package_format
        package_format = select_package_format(release, self.update_format.get_active_id() or "auto")
        package_url = release.asset(package_format)[0] if package_format else None
        self.release_link.set_uri(package_url or release.page_url)
        self.release_link.show()
        self.install_update.set_visible(bool(package_url))

    def _install_update(self, *_args: object) -> None:
        release = self._available_release
        if release is None:
            return
        self.install_update.set_sensitive(False)
        self.update_status.set_text(i18n.t("Downloading package…"))

        def work() -> None:
            try:
                from .updater import download_package
                path, error = download_package(release, self.update_format.get_active_id() or "auto"), None
            except Exception as value:
                path, error = None, str(value)
            GLib.idle_add(self._download_done, path, error)

        threading.Thread(target=work, daemon=True).start()

    def _download_done(self, path: object | None, error: str | None) -> bool:
        self.install_update.set_sensitive(True)
        if error or path is None:
            self.update_status.set_text(i18n.t("Could not download package."))
            return False
        self.update_status.set_text(i18n.t("Package downloaded — confirm installation in the system dialog."))
        try:
            subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            self.release_link.show()
        return False

    def _connect_live_updates(self) -> None:
        """macOS applies settings as controls change; GTK now follows the same Done-only flow."""
        for combo in (self.language, self.theme, self.transparency, self.dock_display, self.update_format):
            combo.connect("changed", self._live_changed)
        checks = [self.autostart, self.spoolbase, self.developer, self.allow_scripts,
                  self.spool_grams, self.monochrome, self.quiet, self.auto_update,
                  self.telegram_enabled, self.dock_enabled, self.dock_only_printing,
                  self.web_enabled]
        checks.extend(self.card_options.values())
        checks.extend(self.dock_printers.values())
        checks.extend(self.notices.values())
        for check in checks:
            check.connect("toggled", self._live_changed)
        self.quiet_start.connect("focus-out-event", self._live_changed)
        self.quiet_end.connect("focus-out-event", self._live_changed)
        self.telegram_token.connect("focus-out-event", self._live_changed)
        self.telegram_chat.connect("focus-out-event", self._live_changed)

    def _live_changed(self, *_args: object) -> bool:
        if self._ready:
            self.save()
        return False

    def save(self) -> bool:
        try:
            datetime.strptime(self.quiet_start.get_text().strip(), "%H:%M")
            datetime.strptime(self.quiet_end.get_text().strip(), "%H:%M")
        except ValueError:
            return False
        before = dict(self.app.config.data)
        self.app.config.data["floating-window-enabled"] = self.floating_window.get_active()
        self.app.config.data["floating-window-always-on-top"] = self.always_on_top.get_active()
        self.app.config.data.update(
            language=self.language.get_active_id(),
            theme=self.theme.get_active_id(),
            panel_transparency=self.transparency.get_active_id() or "low",
            quiet_hours_enabled=self.quiet.get_active(),
            quiet_hours_start=self.quiet_start.get_text().strip(),
            quiet_hours_end=self.quiet_end.get_text().strip(),
            spoolbase_enabled=self.spoolbase.get_active(),
            card_show_spool_grams=self.spool_grams.get_active(),
            card_show_details_chip=self.details_chip.get_active(),
            monochrome=self.monochrome.get_active(),
            printer_control_enabled=self.printer_control.get_active(),
            developer_mode=self.developer.get_active(),
            allow_script_actions=self.allow_scripts.get_active(),
            auto_update_check=self.auto_update.get_active(),
            linux_update_format=self.update_format.get_active_id() or "auto",
        )
        self.app.config.data["web_dashboard_enabled"] = self.web_enabled.get_active()
        self.app.config.data["edge-dock-enabled"] = self.dock_enabled.get_active()
        self.app.config.data["edge-dock-edge"] = "left" if self._dock_left else "right"
        self.app.config.data["edge-dock-row"] = self._dock_row
        display_index = self.dock_display.get_active()
        if 0 <= display_index < len(self._dock_display_ids):
            from .edgedock import choose_display
            choose_display(self.app.config.data, self._dock_display_ids[display_index])
        self.app.config.data["edge-dock-only-printing"] = self.dock_only_printing.get_active()
        self.app.config.data["edge-dock-scale-percent"] = max(100, min(150, round(int(self.app.config.data.get("edge-dock-scale-percent", 100)) / 5) * 5))
        self.app.config.data["card_scale_percent"] = max(75, min(150, round(int(self.app.config.data.get("card_scale_percent", 100)) / 5) * 5))
        hidden = sorted(serial for serial, widget in self.dock_printers.items() if not widget.get_active())
        self.app.config.data["edge-dock-hidden"] = "\n".join(hidden)
        self.app.config.data["edge-dock-pinned"] = self.dock_pinned.get_active()
        self.app.config.data["edge-dock-camera"] = self.dock_camera.get_active()
        self.app.config.data["edge-dock-camera-serials"] = "\n".join(
            sorted(serial for serial, widget in self.dock_cameras.items() if widget.get_active()))
        self.app.config.data["telegram-enabled"] = self.telegram_enabled.get_active()
        self.app.config.data["telegram-bot-token"] = self.telegram_token.get_text().strip()
        self.app.config.data["telegram-chat-id"] = self.telegram_chat.get_text().strip()
        for key, widget in self.notices.items():
            self.app.config.data[key] = widget.get_active()
        for key, widget in self.card_options.items():
            self.app.config.data[key] = widget.get_active()
        self.app.config.save()
        set_autostart(self.autostart.get_active())
        language_changed = before.get("language") != self.app.config.data.get("language")
        appearance_changed = any(before.get(key) != self.app.config.data.get(key)
                                 for key in ("theme", "panel_transparency"))
        # spoolbase_enabled belongs here too: it decides whether a slot shows its assigned roll and
        # whether the slot is clickable at all, so the cards have to be rebuilt when it flips.
        card_changed = appearance_changed or any(before.get(key) != self.app.config.data.get(key)
                                                  for key in (*self.card_options.keys(),
                                                              "card_show_spool_grams",
                                                              "card_show_details_chip", "monochrome",
                                                              "spoolbase_enabled"))
        # The tray offers the strip's submenu only while the strip is on, and ticks its display and place.
        menu_changed = language_changed or any(before.get(key) != self.app.config.data.get(key) for key in
                                               ("spoolbase_enabled", "edge-dock-enabled", "edge-dock-edge",
                                                "edge-dock-row", "edge-dock-display"))
        if language_changed:
            self.app.language = str(self.app.config.data.get("language", "pl"))
        if appearance_changed:
            self.app.apply_theme(animate=True)
        if card_changed or language_changed:
            self.app.rebuild_cards()
        if any(before.get(key) != self.app.config.data.get(key) for key in
               ("floating-window-enabled", "floating-window-always-on-top")):
            self.app.window.close_panel()
            self.app.window.apply_window_mode()
            self.app.show()
        if menu_changed:
            self.app._tray()
        if self.auto_update.get_active():
            checker = getattr(self.app, "check_updates_background", None)
            if callable(checker):
                checker()
        bot = getattr(self.app, "telegram_bot", None)
        if bot is not None:
            bot.sync()
        dock = getattr(self.app, "edge_dock", None)
        if dock is not None:
            dock.refresh()
        # Starting or stopping the LAN server has to follow the switch immediately: leaving a socket
        # listening after the user turned it off is exactly the problem this section was added for.
        server = getattr(self.app, "web_server", None)
        if server is not None:
            if self.web_enabled.get_active():
                server.start()
            else:
                server.stop()
        return True
