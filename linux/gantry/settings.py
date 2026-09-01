from __future__ import annotations

"""GTK port of the current macOS Settings window (excluding web and device pairing)."""

import threading
import subprocess
from datetime import datetime
from typing import Any

from gi.repository import GLib, Gtk  # type: ignore

from . import __version__
from .storage import autostart_enabled, set_autostart


class SettingsDialog(Gtk.Dialog):
    def __init__(self, app: Any) -> None:
        super().__init__(title=app.text["settings"], transient_for=app.window, modal=True)
        self.app = app
        self.pl = app.language == "pl"
        self._ready = False
        self._original_transparency = str(app.config.data.get("panel_transparency", "low"))
        self.add_button("Gotowe" if self.pl else "Done", Gtk.ResponseType.OK)
        self.set_default_size(460, 640)
        self.set_size_request(440, 360)
        self.set_resizable(True)

        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        root.get_style_context().add_class("settings-root")
        self.scroll.add(root)
        self.get_content_area().pack_start(self.scroll, True, True, 0)

        root.pack_start(self._header(), False, False, 0)
        root.pack_start(self._appearance(), False, False, 0)
        root.pack_start(self._general(), False, False, 0)
        root.pack_start(self._cards(), False, False, 0)
        root.pack_start(self._notifications(), False, False, 0)
        root.pack_start(self._telegram(), False, False, 0)
        root.pack_start(self._diagnostics(), False, False, 0)
        root.pack_start(self._updates(), False, False, 0)
        root.pack_start(self._about(), False, False, 0)
        self.show_all()
        self.release_link.hide()
        self._connect_live_updates()
        self._ready = True

    def _header(self) -> Gtk.Widget:
        header = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        header.get_style_context().add_class("settings-header")
        title = Gtk.Label(label="Ustawienia" if self.pl else "Settings", xalign=0)
        title.get_style_context().add_class("settings-title")
        author = Gtk.Label(label="Kamil Grzegorczyk", xalign=0)
        author.get_style_context().add_class("settings-author")
        profiles = Gtk.Box(spacing=12)
        profiles.get_style_context().add_class("settings-links")
        for label, uri in (("@parametryczny on GitHub", "https://github.com/parametryczny"),
                           ("@parametryczny on X", "https://x.com/parametryczny")):
            link = Gtk.LinkButton.new_with_label(uri, label)
            link.set_relief(Gtk.ReliefStyle.NONE)
            profiles.pack_start(link, False, False, 0)
        header.pack_start(title, False, False, 0)
        header.pack_start(author, False, False, 0)
        header.pack_start(profiles, False, False, 0)
        return header

    def _appearance(self) -> Gtk.Widget:
        self.language = Gtk.ComboBoxText()
        self.language.append("pl", "Polski")
        self.language.append("en", "English")
        self.language.set_active_id(self.app.language)
        self.theme = Gtk.ComboBoxText()
        self.theme.append("light", self.app.text["light"])
        self.theme.append("dark", self.app.text["dark"])
        self.theme.set_active_id(str(self.app.config.data.get("theme", "dark")))
        self.transparency = Gtk.ComboBoxText()
        self.transparency.append("low", "Niska" if self.pl else "Low")
        self.transparency.append("medium", "Średnia" if self.pl else "Medium")
        self.transparency.append("high", "Wysoka" if self.pl else "High")
        self.transparency.set_active_id(self._original_transparency)
        self.transparency.connect("changed", self._preview_transparency)

        form = Gtk.Grid(column_spacing=14, row_spacing=10)
        rows = (("Język" if self.pl else "Language", self.language),
                ("Wygląd" if self.pl else "Appearance", self.theme),
                ("Przezroczystość" if self.pl else "Transparency", self.transparency))
        for row, (text, widget) in enumerate(rows):
            label = Gtk.Label(label=text, xalign=1)
            label.get_style_context().add_class("settings-label")
            widget.set_hexpand(True)
            form.attach(label, 0, row, 1, 1)
            form.attach(widget, 1, row, 1, 1)
        return self._section("WYGLĄD" if self.pl else "APPEARANCE", [form])

    def _preview_transparency(self, combo: Gtk.ComboBoxText) -> None:
        self.app.preview_panel_transparency(combo.get_active_id() or "low")

    def _general(self) -> Gtk.Widget:
        self.autostart = self._check(self.app.text["autostart"], autostart_enabled())
        self.spoolbase = self._check(
            "Spoolbase — magazyn filamentów" if self.pl else "Spoolbase — filament stock",
            bool(self.app.config.data.get("spoolbase_enabled", True)))
        self.developer = self._check(
            "Tryb deweloperski (sterowanie + automatyzacje)" if self.pl
            else "Developer mode (control + automations)",
            bool(self.app.config.data.get("developer_mode", False)))
        self.allow_scripts = self._check(
            "Zezwól automatyzacjom na skrypty i własne komendy" if self.pl
            else "Allow automations to run scripts and custom commands",
            bool(self.app.config.data.get("allow_script_actions", False)))
        hint = Gtk.Label(
            label=("Wyłączone domyślnie ze względów bezpieczeństwa. Każda reguła nadal pyta o zgodę "
                   "przy pierwszym uruchomieniu." if self.pl else
                   "Off by default for safety. Every rule still asks for confirmation the first time it runs."),
            xalign=0, wrap=True)
        hint.set_margin_start(24)
        hint.get_style_context().add_class("settings-hint")
        return self._section("OGÓLNE" if self.pl else "GENERAL",
                             [self.autostart, self.spoolbase, self.developer, self.allow_scripts, hint])

    def _cards(self) -> Gtk.Widget:
        self.card_options: dict[str, Gtk.CheckButton] = {}
        widgets: list[Gtk.Widget] = []
        for key, polish, english in (
            ("card_show_filename", "Nazwa pliku", "File name"),
            ("card_show_progress", "Postęp", "Progress"),
            ("card_show_temperatures", "Temperatury", "Temperatures"),
            ("card_show_filaments", "Filamenty / AMS", "Filaments / AMS"),
        ):
            check = self._check(polish if self.pl else english,
                                bool(self.app.config.data.get(key, True)))
            self.card_options[key] = check
            widgets.append(check)
        self.spool_grams = self._check(
            "Gramy na rolce (AMS NFC / Spoolbase)" if self.pl
            else "Grams on spool (AMS NFC / Spoolbase)",
            bool(self.app.config.data.get("card_show_spool_grams", False)))
        self.monochrome = self._check(
            "Kolorystyka monochromatyczna" if self.pl else "Monochrome colours",
            bool(self.app.config.data.get("monochrome", False)))
        self.monochrome.set_tooltip_text(
            "Temperatury na szaro, kolory AMS wyciszone" if self.pl
            else "Grey temperatures, calmer AMS colours")
        widgets.extend((self.spool_grams, self.monochrome))
        return self._section("KARTY DRUKAREK" if self.pl else "PRINTER CARDS", widgets)

    def _notifications(self) -> Gtk.Widget:
        self.notices: dict[str, Gtk.CheckButton] = {}
        widgets: list[Gtk.Widget] = []
        for key, config_key in (("finished_notice", "notify_finished"),
                                ("error_notice", "notify_error"),
                                ("paused_notice", "notify_paused"),
                                ("low_notice", "notify_low_filament"),
                                ("humidity_notice", "notify_humidity")):
            check = self._check(self.app.text[key], bool(self.app.config.data.get(config_key)))
            self.notices[config_key] = check
            widgets.append(check)
        separator = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
        separator.get_style_context().add_class("section-rule")
        self.quiet = self._check(
            "Godziny ciszy (bez powiadomień)" if self.pl else "Quiet hours (no notifications)",
            bool(self.app.config.data.get("quiet_hours_enabled", True)))
        quiet_row = Gtk.Box(spacing=7)
        quiet_row.set_margin_start(24)
        self.quiet_start = Gtk.Entry(text=str(self.app.config.data.get("quiet_hours_start", "22:00")))
        self.quiet_end = Gtk.Entry(text=str(self.app.config.data.get("quiet_hours_end", "07:00")))
        self.quiet_start.set_width_chars(5)
        self.quiet_end.set_width_chars(5)
        quiet_row.pack_start(Gtk.Label(label="od" if self.pl else "from"), False, False, 0)
        quiet_row.pack_start(self.quiet_start, False, False, 0)
        quiet_row.pack_start(Gtk.Label(label="do" if self.pl else "to"), False, False, 0)
        quiet_row.pack_start(self.quiet_end, False, False, 0)
        self.quiet.connect("toggled", lambda check: quiet_row.set_sensitive(check.get_active()))
        quiet_row.set_sensitive(self.quiet.get_active())
        widgets.extend((separator, self.quiet, quiet_row))
        return self._section("POWIADOMIENIA" if self.pl else "NOTIFICATIONS", widgets)

    def _telegram(self) -> Gtk.Widget:
        self.telegram_enabled = self._check(
            "Wysyłaj powiadomienia i sterowanie przez Telegram" if self.pl
            else "Send notifications and control over Telegram",
            bool(self.app.config.data.get("telegram-enabled", False)))
        form = Gtk.Grid(column_spacing=14, row_spacing=10)
        self.telegram_token = Gtk.Entry(text=str(self.app.config.data.get("telegram-bot-token", "")))
        self.telegram_token.set_placeholder_text("123456:ABC…")
        self.telegram_token.set_hexpand(True)
        self.telegram_chat = Gtk.Entry(text=str(self.app.config.data.get("telegram-chat-id", "")))
        self.telegram_chat.set_placeholder_text("np. 8849748842")
        self.telegram_chat.set_hexpand(True)
        rows = (("Token bota" if self.pl else "Bot token", self.telegram_token),
                ("Chat ID", self.telegram_chat))
        for row, (text, widget) in enumerate(rows):
            label = Gtk.Label(label=text, xalign=1)
            label.get_style_context().add_class("settings-label")
            form.attach(label, 0, row, 1, 1)
            form.attach(widget, 1, row, 1, 1)
        test_row = Gtk.Box(spacing=10)
        self.telegram_test = Gtk.Button(label="Wyślij test" if self.pl else "Send test")
        self.telegram_test.connect("clicked", self._telegram_test)
        self.telegram_status = Gtk.Label(label="", xalign=0, wrap=True)
        self.telegram_status.get_style_context().add_class("settings-hint")
        test_row.pack_start(self.telegram_test, False, False, 0)
        test_row.pack_start(self.telegram_status, True, True, 0)
        hint = Gtk.Label(
            label=("Utwórz własnego bota u @BotFather, wklej token i swój chat ID (z @userinfobot). "
                   "Token zostaje tylko na tym komputerze. Instrukcja: docs/telegram-setup.md" if self.pl else
                   "Create your own bot with @BotFather, paste the token and your chat ID (from @userinfobot). "
                   "The token stays only on this computer. Guide: docs/telegram-setup.md"),
            xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        return self._section("TELEGRAM", [self.telegram_enabled, form, test_row, hint])

    def _telegram_test(self, *_args: object) -> None:
        self.save()
        token = self.telegram_token.get_text().strip()
        chat = self.telegram_chat.get_text().strip()
        if not token or not chat:
            self.telegram_status.set_text(
                "Podaj token i chat ID." if self.pl else "Enter a token and chat ID.")
            return
        self.telegram_test.set_sensitive(False)
        self.telegram_status.set_text("Wysyłam…" if self.pl else "Sending…")

        def work() -> None:
            from .telegram import send_test
            ok = send_test(token, chat,
                           "Test" if self.pl else "Test",
                           "Połączenie działa." if self.pl else "Connection works.")
            GLib.idle_add(self._telegram_test_done, ok)

        threading.Thread(target=work, daemon=True).start()

    def _telegram_test_done(self, ok: bool) -> bool:
        self.telegram_test.set_sensitive(True)
        self.telegram_status.set_text(
            ("Wysłano — sprawdź Telegram." if self.pl else "Sent — check Telegram.") if ok
            else ("Nie udało się. Sprawdź token i chat ID." if self.pl else "Failed. Check token and chat ID."))
        return False

    def _updates(self) -> Gtk.Widget:
        row = Gtk.Box(spacing=10)
        self.update_status = Gtk.Label(
            label=f"Wersja {__version__}" if self.pl else f"Version {__version__}",
            xalign=0, wrap=True)
        self.update_status.get_style_context().add_class("settings-hint")
        self.update_button = Gtk.Button(
            label="Sprawdź aktualizacje" if self.pl else "Check for updates")
        self.update_button.connect("clicked", self._check_updates)
        row.pack_start(self.update_status, True, True, 0)
        row.pack_start(self.update_button, False, False, 0)
        self.release_link = Gtk.LinkButton.new_with_label(
            "https://github.com/parametryczny/gantrybar/releases",
            "Otwórz wydanie" if self.pl else "Open release")
        self.release_link.set_halign(Gtk.Align.START)
        self.release_link.set_no_show_all(True)
        self.install_update = Gtk.Button(
            label="Pobierz i otwórz instalator" if self.pl else "Download and open installer")
        self.install_update.set_halign(Gtk.Align.START)
        self.install_update.set_no_show_all(True)
        self.install_update.connect("clicked", self._install_update)
        self._available_release: object | None = None
        self.auto_update = self._check(
            "Automatycznie sprawdzaj dostępność aktualizacji" if self.pl
            else "Automatically check for updates",
            bool(self.app.config.data.get("auto_update_check", False)))
        hint = Gtk.Label(
            label=("Instalację pakietu .deb zatwierdza systemowy menedżer pakietów." if self.pl
                   else "The system package manager confirms installation of the .deb package."),
            xalign=0, wrap=True)
        hint.get_style_context().add_class("settings-hint")
        return self._section("AKTUALIZACJE" if self.pl else "UPDATES",
                             [row, self.release_link, self.install_update, self.auto_update, hint])

    def _diagnostics(self) -> Gtk.Widget:
        text = Gtk.Label(label=("Test sieci, MQTT, kamery i magazynu sekretów. Pokazuje również powód offline, "
                                "opóźnienie i ocenę jakości połączenia." if self.pl else
                                "Tests network, MQTT, camera and secret storage. Also shows offline reason, "
                                "latency and connection quality."), xalign=0, wrap=True)
        text.get_style_context().add_class("settings-hint")
        button = Gtk.Button(label="Otwórz centrum diagnostyczne…" if self.pl else "Open Diagnostic Center…")
        button.set_halign(Gtk.Align.START)
        button.connect("clicked", lambda *_: self._open_diagnostics())
        return self._section("CENTRUM DIAGNOSTYCZNE" if self.pl else "DIAGNOSTIC CENTER", [text, button])

    def _open_diagnostics(self) -> None:
        from .diagnostics import DiagnosticsDialog
        DiagnosticsDialog(self.app).present()

    def _about(self) -> Gtk.Widget:
        wrapper = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        version = Gtk.Label(
            label=f"Gantry • {self.app.text['version']} {__version__} • Secret Service", xalign=0)
        version.get_style_context().add_class("settings-version")
        support = Gtk.LinkButton.new_with_label(
            "https://buycoffee.to/parametryczny",
            "☕  Wesprzyj projekt" if self.pl else "☕  Support the project")
        support.get_style_context().add_class("settings-support")
        support.set_halign(Gtk.Align.CENTER)
        note = Gtk.Label(
            label=("Wirtualna kawa daje mi kofeinowego kopa do pracy nad kolejnymi wersjami Gantry. 🚀"
                   if self.pl else
                   "A virtual coffee gives me a caffeine kick to keep improving Gantry. 🚀"),
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
        self.update_status.set_text("Sprawdzam…" if self.pl else "Checking…")
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
            self.update_status.set_text(
                "Nie udało się sprawdzić aktualizacji." if self.pl else
                "Could not check for updates.")
            return False
        if is_newer(release.version, __version__):
            self._available_release = release
            self.update_status.set_text(
                f"Dostępna wersja {release.version}." if self.pl else
                f"Version {release.version} is available.")
            self.release_link.set_uri(release.deb_url or release.page_url)
            self.release_link.show()
            if release.deb_url:
                self.install_update.show()
        else:
            self.update_status.set_text(
                f"Masz najnowszą wersję ({__version__})." if self.pl else
                f"You have the latest version ({__version__}).")
        return False

    def _install_update(self, *_args: object) -> None:
        release = self._available_release
        if release is None:
            return
        self.install_update.set_sensitive(False)
        self.update_status.set_text("Pobieram pakiet…" if self.pl else "Downloading package…")

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
            self.update_status.set_text("Nie udało się pobrać pakietu." if self.pl else "Could not download package.")
            return False
        self.update_status.set_text(
            "Pakiet pobrany — potwierdź instalację w systemie."
            if self.pl else "Package downloaded — confirm installation in the system dialog.")
        try:
            subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            self.release_link.show()
        return False

    def _connect_live_updates(self) -> None:
        """macOS applies settings as controls change; GTK now follows the same Done-only flow."""
        for combo in (self.language, self.theme, self.transparency):
            combo.connect("changed", self._live_changed)
        checks = [self.autostart, self.spoolbase, self.developer, self.allow_scripts,
                  self.spool_grams, self.monochrome, self.quiet, self.auto_update,
                  self.telegram_enabled]
        checks.extend(self.card_options.values())
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
        card_changed = appearance_changed or any(before.get(key) != self.app.config.data.get(key)
                                                  for key in (*self.card_options.keys(),
                                                              "card_show_spool_grams", "monochrome"))
        menu_changed = language_changed or before.get("spoolbase_enabled") != self.app.config.data.get("spoolbase_enabled")
        if language_changed:
            self.app.language = str(self.app.config.data.get("language", "pl"))
            from .app import TEXT
            self.app.text = TEXT.get(self.app.language, TEXT["pl"])
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
        sync = getattr(self.app, "sync_service", None)
        if sync is not None:
            sync.note_settings_changed()
        bot = getattr(self.app, "telegram_bot", None)
        if bot is not None:
            bot.sync()
        return True
