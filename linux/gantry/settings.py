from __future__ import annotations

"""GTK port of the current macOS Settings window (excluding web and device pairing)."""

import threading
import subprocess
from datetime import datetime
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from . import __version__
from . import i18n
from .storage import autostart_enabled, set_autostart


NOTICE_LABELS = {"finished_notice": "Print finished", "error_notice": "Printer errors", "paused_notice": "Print paused", "low_notice": "Low filament", "finishing_soon_notice": "Print finishing in 10 minutes", "humidity_notice": "High AMS humidity", "offline_notice": "Connection lost"}


class SettingsDialog(Gtk.Dialog):
    def __init__(self, app: Any) -> None:
        super().__init__(title=i18n.t("Settings"), transient_for=app.window, modal=True)
        self.app = app
        self.pl = app.language == "pl"
        self._ready = False
        self._original_transparency = str(app.config.data.get("panel_transparency", "low"))
        self.add_button(i18n.t("Done"), Gtk.ResponseType.OK)
        self.set_default_size(640, 720)
        self.set_size_request(600, 520)
        self.set_resizable(True)

        # Three tabs instead of one long column, matching the macOS window. GTK's StackSwitcher
        # already renders as a segmented pill bar, so no custom widget is needed here.
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        outer.get_style_context().add_class("settings-root")
        outer.pack_start(self._header(), False, False, 0)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.NONE)
        switcher = Gtk.StackSwitcher(stack=self.stack)
        switcher.set_halign(Gtk.Align.FILL)
        switcher.set_homogeneous(True)
        outer.pack_start(switcher, False, False, 0)
        outer.pack_start(self.stack, True, True, 0)
        self.get_content_area().pack_start(outer, True, True, 0)

        self.stack.add_titled(self._page([self._basics(), self._notifications(),
                                          self._updates(), self._about()]),
                              "general",i18n.t("General"))
        self.stack.add_titled(self._page([self._appearance(), self._cards(), self._dock()]),
                              "appearance",i18n.t("Appearance"))
        self.stack.add_titled(self._page([self._developer(), self._telegram(),
                                          self._web()]),
                              "advanced",i18n.t("Advanced"))
        self.show_all()
        self.release_link.hide()
        self._connect_live_updates()
        self._ready = True

    @property
    def scroll(self) -> Gtk.Widget:
        """The visible tab's scroller. Each tab has its own, so callers that used to reach for a
        single `scroll` (the preview renderer) get the one currently on screen."""
        page = self.stack.get_visible_child()
        if page is not None:
            return page
        children = self.stack.get_children()
        return children[0] if children else self.stack

    def _header(self) -> Gtk.Widget:
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        header.get_style_context().add_class("settings-header")
        title = Gtk.Label(label=i18n.t("Settings"), xalign=0)
        title.get_style_context().add_class("settings-title")
        author = Gtk.Label(label="Gantry · @_parametryczny", xalign=0)
        author.get_style_context().add_class("settings-author")
        profiles = Gtk.Box(spacing=12)
        profiles.get_style_context().add_class("settings-links")
        for label, uri in (("@parametryczny on GitHub", "https://github.com/parametryczny"),
                           ("@_parametryczny on X", "https://x.com/_parametryczny")):
            link = Gtk.LinkButton.new_with_label(uri, label)
            link.set_relief(Gtk.ReliefStyle.NONE)
            profiles.pack_start(link, False, False, 0)
        header.pack_start(title, False, False, 0)
        header.pack_start(author, False, False, 0)
        header.pack_start(profiles, False, False, 0)
        return header

    def _appearance(self) -> Gtk.Widget:
        self.theme = Gtk.ComboBoxText()
        self.theme.append("light", i18n.t("Light"))
        self.theme.append("dark", i18n.t("Dark"))
        self.theme.set_active_id(str(self.app.config.data.get("theme", "dark")))
        self.transparency = Gtk.ComboBoxText()
        self.transparency.append("low",i18n.t("Low"))
        self.transparency.append("medium",i18n.t("Medium"))
        self.transparency.append("high",i18n.t("High"))
        self.transparency.set_active_id(self._original_transparency)
        self.transparency.connect("changed", self._preview_transparency)

        form = Gtk.Grid(column_spacing=14, row_spacing=10)
        # Language lives in Basics on macOS and Windows, so it is not listed here.
        rows = ((i18n.t("Appearance"), self.theme),
                (i18n.t("Transparency"), self.transparency))
        for row, (text, widget) in enumerate(rows):
            label = Gtk.Label(label=text, xalign=1)
            label.get_style_context().add_class("settings-label")
            widget.set_hexpand(True)
            form.attach(label, 0, row, 1, 1)
            form.attach(widget, 1, row, 1, 1)
        return self._section(i18n.t("APPEARANCE"), [form])

    def _preview_transparency(self, combo: Gtk.ComboBoxText) -> None:
        self.app.preview_panel_transparency(combo.get_active_id() or "low")

    def _page(self, sections: list[Gtk.Widget]) -> Gtk.Widget:
        """One tab: a scrolling column of section cards."""
        column = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        for section in sections:
            column.pack_start(section, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(column)
        return scroll

    def _basics(self) -> Gtk.Widget:
        # Wypelniane tym, co znalazl loader, wiec nowy plik i18n/<kod>.json pojawia sie sam.
        self.language = Gtk.ComboBoxText()
        for code, name in i18n.available():
            self.language.append(code, name)
        self.language.set_active_id(self.app.language)
        language_row = Gtk.Box(spacing=10)
        language_row.pack_start(Gtk.Label(label=i18n.t("Language"), xalign=0), False, False, 0)
        language_row.pack_end(self.language, False, False, 0)
        self.autostart = self._check(i18n.t("Start after login"), autostart_enabled())
        self.spoolbase = self._check(
i18n.t("Spoolbase — filament stock"),
            bool(self.app.config.data.get("spoolbase_enabled", True)))
        return self._section(i18n.t("BASICS"),
                             [language_row, self.autostart, self.spoolbase])

    def _developer(self) -> Gtk.Widget:
        self.developer = self._check(i18n.t("Developer mode (control + automations)"),
            bool(self.app.config.data.get("developer_mode", False)))
        self.allow_scripts = self._check(i18n.t("Allow automations to run scripts and custom commands"),
            bool(self.app.config.data.get("allow_script_actions", False)))
        hint = Gtk.Label(
            label=i18n.t("Off by default for safety. Every rule still asks for confirmation the first time it runs."),
            xalign=0, wrap=True)
        hint.set_margin_start(24)
        hint.get_style_context().add_class("settings-hint")
        return self._section(i18n.t("DEVELOPER"),
                             [self.developer, self.allow_scripts, hint])

    def _dock(self) -> Gtk.Widget:
        """Edge dock: enable, which edge, and which printers appear on the strip."""
        self.dock_enabled = self._check(
i18n.t("Show the strip on top"),
            bool(self.app.config.data.get("edge-dock-enabled", False)))
        self.dock_edge = Gtk.ComboBoxText()
        self.dock_edge.append("left",i18n.t("Left"))
        self.dock_edge.append("right",i18n.t("Right"))
        edge = str(self.app.config.data.get("edge-dock-edge", "right"))
        self.dock_edge.set_active_id("left" if edge == "left" else "right")
        edge_row = Gtk.Box(spacing=10)
        edge_row.pack_start(Gtk.Label(label=i18n.t("Edge"), xalign=0), False, False, 0)
        edge_row.pack_end(self.dock_edge, False, False, 0)
        self.dock_only_printing = self._check(
i18n.t("Only printing"),
            bool(self.app.config.data.get("edge-dock-only-printing", False)))

        # Stored as an exclusion list, so a newly added printer shows up by itself.
        hidden = set(str(self.app.config.data.get("edge-dock-hidden", "")).split("\n")) - {""}
        caption = Gtk.Label(label=i18n.t("WHICH PRINTERS"), xalign=0)
        caption.get_style_context().add_class("settings-section")
        self.dock_printers: dict[str, Gtk.CheckButton] = {}
        widgets: list[Gtk.Widget] = [self.dock_enabled, edge_row, self.dock_only_printing, caption]
        printers = list(getattr(self.app, "printers", []))
        if not printers:
            empty = Gtk.Label(label=i18n.t("No printers"), xalign=0)
            empty.get_style_context().add_class("settings-hint")
            widgets.append(empty)
        for printer in printers:
            check = self._check(printer.name, printer.serial not in hidden)
            self.dock_printers[printer.serial] = check
            widgets.append(check)
        hint = Gtk.Label(
            label=(i18n.t("A narrow strip pinned to the screen edge, always on top. Hovering expands it to names, clicking opens details.")),
            xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        widgets.append(hint)
        return self._section(i18n.t("EDGE DOCK"), widgets)

    def _cards(self) -> Gtk.Widget:
        self.card_options: dict[str, Gtk.CheckButton] = {}
        widgets: list[Gtk.Widget] = []
        for key, polish, english in (
            ("card_show_filename", "Nazwa pliku", "File name"),
            ("card_show_progress", "Postęp", "Progress"),
            ("card_show_temperatures", "Temperatury", "Temperatures"),
            ("card_show_filaments", "Filamenty / AMS", "Filaments / AMS"),
        ):
            check = self._check(i18n.t(english),
                                bool(self.app.config.data.get(key, True)))
            self.card_options[key] = check
            widgets.append(check)
        self.spool_grams = self._check(i18n.t("Grams on spool (AMS NFC / Spoolbase)"),
            bool(self.app.config.data.get("card_show_spool_grams", False)))
        self.monochrome = self._check(
i18n.t("Monochrome colours"),
            bool(self.app.config.data.get("monochrome", False)))
        self.monochrome.set_tooltip_text(i18n.t("Grey temperatures, calmer AMS colours"))
        widgets.extend((self.spool_grams, self.monochrome))
        return self._section(i18n.t("PRINTER CARDS"), widgets)

    def _notifications(self) -> Gtk.Widget:
        self.notices: dict[str, Gtk.CheckButton] = {}
        widgets: list[Gtk.Widget] = []
        for key, config_key in (("finished_notice", "notify_finished"),
                                ("error_notice", "notify_error"),
                                ("paused_notice", "notify_paused"),
                                ("finishing_soon_notice", "notify_finishing_soon"),
                                ("low_notice", "notify_low_filament"),
                                ("humidity_notice", "notify_humidity")):
            check = self._check(i18n.t(NOTICE_LABELS[key]), bool(self.app.config.data.get(config_key)))
            self.notices[config_key] = check
            widgets.append(check)
        separator = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        separator.get_style_context().add_class("section-rule")
        self.quiet = self._check(
i18n.t("Quiet hours (no notifications)"),
            bool(self.app.config.data.get("quiet_hours_enabled", True)))
        quiet_row = Gtk.Box(spacing=7)
        quiet_row.set_margin_start(24)
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
        widgets.extend((separator, self.quiet, quiet_row))
        return self._section(i18n.t("NOTIFICATIONS"), widgets)

    def _web(self) -> Gtk.Widget:
        """Read-only LAN dashboard. Until now the server started from the config key with no visible
        switch anywhere on Linux, which meant a listening socket the user could not turn off."""
        self.web_enabled = self._check(i18n.t("Preview server (local network, read only)"),
            bool(self.app.config.data.get("web_dashboard_enabled", True)))
        from .webserver import PORT, local_ipv4
        address = local_ipv4()
        self.web_address = Gtk.Label(
            label=f"http://{address}:{PORT}" if address else ("brak adresu w sieci" if self.pl
                                                              else "no network address"),
            xalign=0, selectable=True)
        self.web_address.get_style_context().add_class("settings-version")
        hint = Gtk.Label(
            label=(i18n.t("Open on a phone on the same Wi-Fi. View only, no control.")),
            xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        return self._section(i18n.t("WEB DASHBOARD"),
                             [self.web_enabled, self.web_address, hint])

    def _telegram(self) -> Gtk.Widget:
        self.telegram_enabled = self._check(i18n.t("Send notifications and control over Telegram"),
            bool(self.app.config.data.get("telegram-enabled", False)))
        form = Gtk.Grid(column_spacing=14, row_spacing=10)
        self.telegram_token = Gtk.Entry(text=str(self.app.config.data.get("telegram-bot-token", "")))
        self.telegram_token.set_placeholder_text("123456:ABC…")
        self.telegram_token.set_hexpand(True)
        self.telegram_chat = Gtk.Entry(text=str(self.app.config.data.get("telegram-chat-id", "")))
        self.telegram_chat.set_placeholder_text("np. 8849748842")
        self.telegram_chat.set_hexpand(True)
        rows = ((i18n.t("Bot token"), self.telegram_token),
                ("Chat ID", self.telegram_chat))
        for row, (text, widget) in enumerate(rows):
            label = Gtk.Label(label=text, xalign=1)
            label.get_style_context().add_class("settings-label")
            form.attach(label, 0, row, 1, 1)
            form.attach(widget, 1, row, 1, 1)
        test_row = Gtk.Box(spacing=10)
        self.telegram_test = Gtk.Button(label=i18n.t("Send test"))
        self.telegram_test.connect("clicked", self._telegram_test)
        self.telegram_status = Gtk.Label(label="", xalign=0, wrap=True)
        self.telegram_status.get_style_context().add_class("settings-hint")
        test_row.pack_start(self.telegram_test, False, False, 0)
        test_row.pack_start(self.telegram_status, True, True, 0)
        hint = Gtk.Label(
            label=(i18n.t("Create your own bot with @BotFather, paste the token and your chat ID (from @userinfobot). The token stays only on this computer. Guide: docs/telegram-setup.md")),
            xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        return self._section("TELEGRAM", [self.telegram_enabled, form, test_row, hint])

    def _telegram_test(self, *_args: object) -> None:
        self.save()
        token = self.telegram_token.get_text().strip()
        chat = self.telegram_chat.get_text().strip()
        if not token or not chat:
            self.telegram_status.set_text(
i18n.t("Enter a token and chat ID."))
            return
        self.telegram_test.set_sensitive(False)
        self.telegram_status.set_text(i18n.t("Sending…"))

        def work() -> None:
            from .telegram import send_test
            ok = send_test(token, chat,i18n.t("Test"),
i18n.t("Connection works."))
            GLib.idle_add(self._telegram_test_done, ok)

        threading.Thread(target=work, daemon=True).start()

    def _telegram_test_done(self, ok: bool) -> bool:
        self.telegram_test.set_sensitive(True)
        self.telegram_status.set_text(
            (i18n.t("Sent — check Telegram.")) if ok
            else (i18n.t("Failed. Check token and chat ID.")))
        return False

    def _updates(self) -> Gtk.Widget:
        row = Gtk.Box(spacing=10)
        self.update_status = Gtk.Label(
            label=i18n.t("Version {0}").format(__version__),
            xalign=0, wrap=True)
        self.update_status.get_style_context().add_class("settings-hint")
        self.update_button = Gtk.Button(
            label=i18n.t("Check for updates"))
        self.update_button.connect("clicked", self._check_updates)
        row.pack_start(self.update_status, True, True, 0)
        row.pack_start(self.update_button, False, False, 0)
        self.release_link = Gtk.LinkButton.new_with_label(
            "https://github.com/parametryczny/gantrybar/releases",
i18n.t("Open release"))
        self.release_link.set_halign(Gtk.Align.START)
        self.release_link.set_no_show_all(True)
        self.install_update = Gtk.Button(
            label=i18n.t("Download and open installer"))
        self.install_update.set_halign(Gtk.Align.START)
        self.install_update.set_no_show_all(True)
        self.install_update.connect("clicked", self._install_update)
        self._available_release: object | None = None
        self.auto_update = self._check(i18n.t("Automatically check for updates"),
            bool(self.app.config.data.get("auto_update_check", False)))
        hint = Gtk.Label(
            label=(i18n.t("The system package manager confirms installation of the .deb package.")),
            xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        return self._section(i18n.t("UPDATES"),
                             [row, self.release_link, self.install_update, self.auto_update, hint])

    def _about(self) -> Gtk.Widget:
        wrapper = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        version = Gtk.Label(
            label=f"Gantry • {i18n.t('Version')} {__version__} • Secret Service", xalign=0)
        version.get_style_context().add_class("settings-version")
        support = Gtk.LinkButton.new_with_label(
            "https://buycoffee.to/parametryczny",
i18n.t("☕  Support the project"))
        support.get_style_context().add_class("settings-support")
        support.set_halign(Gtk.Align.CENTER)
        note = Gtk.Label(
            label=(i18n.t("A virtual coffee gives me a caffeine kick to keep improving Gantry. 🚀")),
            xalign=0.5, wrap=True, justify=Gtk.Justification.CENTER)
        note.get_style_context().add_class("settings-hint")
        wrapper.pack_start(version, False, False, 0)
        wrapper.pack_start(support, False, False, 0)
        wrapper.pack_start(note, False, False, 0)
        return wrapper

    @staticmethod
    def _check(label: str, active: bool) -> Gtk.CheckButton:
        widget = Gtk.CheckButton(label=label)
        widget.set_active(active)
        return widget

    @staticmethod
    def _section(title: str, widgets: list[Gtk.Widget]) -> Gtk.Widget:
        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        card.get_style_context().add_class("settings-card")
        heading = Gtk.Label(label=title, xalign=0)
        heading.get_style_context().add_class("settings-section")
        card.pack_start(heading, False, False, 0)
        for widget in widgets:
            card.pack_start(widget, False, False, 0)
        return card

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
            self.release_link.set_uri(release.deb_url or release.page_url)
            self.release_link.show()
            if release.deb_url:
                self.install_update.show()
        else:
            self.update_status.set_text(
                i18n.t("You have the latest version ({0}).").format(__version__))
        return False

    def _install_update(self, *_args: object) -> None:
        release = self._available_release
        if release is None:
            return
        self.install_update.set_sensitive(False)
        self.update_status.set_text(i18n.t("Downloading package…"))

        def work() -> None:
            try:
                from .updater import download_deb
                path, error = download_deb(release), None
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
        for combo in (self.language, self.theme, self.transparency, self.dock_edge):
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
        self.app.config.data.update(
            language=self.language.get_active_id(),
            theme=self.theme.get_active_id(),
            panel_transparency=self.transparency.get_active_id() or "low",
            quiet_hours_enabled=self.quiet.get_active(),
            quiet_hours_start=self.quiet_start.get_text().strip(),
            quiet_hours_end=self.quiet_end.get_text().strip(),
            spoolbase_enabled=self.spoolbase.get_active(),
            card_show_spool_grams=self.spool_grams.get_active(),
            monochrome=self.monochrome.get_active(),
            developer_mode=self.developer.get_active(),
            allow_script_actions=self.allow_scripts.get_active(),
            auto_update_check=self.auto_update.get_active(),
        )
        self.app.config.data["web_dashboard_enabled"] = self.web_enabled.get_active()
        self.app.config.data["edge-dock-enabled"] = self.dock_enabled.get_active()
        self.app.config.data["edge-dock-edge"] = self.dock_edge.get_active_id() or "right"
        self.app.config.data["edge-dock-only-printing"] = self.dock_only_printing.get_active()
        hidden = sorted(serial for serial, widget in self.dock_printers.items() if not widget.get_active())
        self.app.config.data["edge-dock-hidden"] = "\n".join(hidden)
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
                                                              "card_show_spool_grams", "monochrome",
                                                              "spoolbase_enabled"))
        menu_changed = language_changed or before.get("spoolbase_enabled") != self.app.config.data.get("spoolbase_enabled")
        if language_changed:
            self.app.language = str(self.app.config.data.get("language", "pl"))
        if appearance_changed:
            self.app.apply_theme(animate=True)
        if card_changed or language_changed:
            self.app.rebuild_cards()
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
