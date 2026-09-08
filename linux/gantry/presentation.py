"""Native window mode, bounded panels and live-card onboarding shared by tray and desktop."""
from __future__ import annotations
from gi.repository import Gtk, Gdk, GLib
from . import edition
from . import i18n
from .core import PrinterState


class DesktopPresentation:
    def setup_desktop(self):
        self._panel_layer = None
        self._panel_cleanup = None
        self._panel_fit_id = None
        self._panel_position_id = None
        self._guide_refresh = None
        self._last_columns = None
        self._resize_idle = None
        self._startup_layer = Gtk.EventBox()
        self._startup_layer.get_style_context().add_class("maintenance-backdrop")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14, margin=24)
        box.set_halign(Gtk.Align.CENTER); box.set_valign(Gtk.Align.CENTER)
        box.get_style_context().add_class("maintenance-panel")
        self._spinner = Gtk.Spinner()
        self._spinner.set_size_request(28, 28)
        box.pack_start(self._spinner, False, False, 0)
        box.pack_start(Gtk.Label(label=i18n.t("Connecting to printers…")), False, False, 0)
        self._startup_count = Gtk.Label()
        box.pack_start(self._startup_count, False, False, 0)
        if edition.HAS_EXTRAS:   # LITE ships no guide
            guide = Gtk.Button(label=i18n.t("How to read Gantry"))
            guide.get_style_context().add_class("guide-action")
            guide.connect("clicked", lambda *_: self.show_onboarding())
            box.pack_start(guide, False, False, 0)
        skip = Gtk.Button(label=i18n.t("Show dashboard now"))
        skip.get_style_context().add_class("guide-action")
        skip.connect("clicked", lambda *_: self.app._finish_startup())
        box.pack_start(skip, False, False, 0)
        self._startup_layer.add(box)
        self.window_overlay.add_overlay(self._startup_layer)
        self._startup_layer.show_all()
        self._startup_layer.set_no_show_all(True)
        self.connect("size-allocate", self._desktop_resize)
        self.connect("key-press-event", self._panel_key)
        self.connect("map", lambda *_: GLib.idle_add(self.update_startup))
        self.apply_window_mode(rebuild=False)

    def _panel_key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape and self._panel_layer is not None:
            self.close_panel()
            return True
        return False

    def apply_window_mode(self, rebuild=True):
        previous = self.tray_mode
        self.tray_mode = bool(self.app.indicator_available and not self.app.config.data.get("floating-window-enabled", False))
        if self.tray_mode and not previous:
            self.unmaximize()
        self.set_decorated(not self.tray_mode)
        self.set_resizable(not self.tray_mode)
        self.set_size_request(-1, -1) if self.tray_mode else self.set_size_request(305, 290)
        self.set_skip_taskbar_hint(self.tray_mode)
        self.set_skip_pager_hint(self.tray_mode)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY if self.tray_mode else Gdk.WindowTypeHint.NORMAL)
        self.set_keep_above(self.tray_mode or bool(self.app.config.data.get("floating-window-always-on-top", True)))
        if not self.tray_mode and (previous or not rebuild):
            width = max(340, min(1800, int(self.app.config.data.get("floating-window-width", 700))))
            height = max(250, min(1200, int(self.app.config.data.get("floating-window-height", 650))))
            self.resize(width, height)
        if rebuild:
            self.app.rebuild_cards()

    def layout_columns(self):
        if self.tray_mode:
            return max(1, min(2, int(self.app.config.data.get("dashboard_columns", 2))))
        return max(1, round((self.get_size()[0] - 12) / 293))

    def _snapped_tile_size(self, proposed_width, proposed_height):
        """Nearest whole 285×174 card grid, including the dashboard's chrome and 8 px gaps."""
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() if display else None
        workarea = monitor.get_workarea() if monitor else None
        max_width = workarea.width if workarea else 1800
        max_height = workarea.height if workarea else 1200
        columns = max(1, min(int((max_width - 12) // 293),
                             round((proposed_width - 12) / 293)))
        screen_rows = max(1, int((max_height - 108) // 182))
        visible_rows = max(1, min(screen_rows,
                                  round((proposed_height - 108) / 182)))
        return 12 + columns * 293, 108 + visible_rows * 182

    def _desktop_resize(self, _widget, allocation):
        if self.tray_mode:
            return
        key = (self.layout_columns(), self.app.is_compact())
        if key != self._last_columns:
            self._last_columns = key
            GLib.idle_add(lambda: (self.app.rebuild_cards(), False)[1])
        if self._resize_idle:
            GLib.source_remove(self._resize_idle)
        width, height = allocation.width, allocation.height
        def remember():
            self._resize_idle = None
            window = self.get_window()
            if self.tray_mode or (window and window.get_state() & (Gdk.WindowState.MAXIMIZED | Gdk.WindowState.ICONIFIED)):
                return False
            snapped_width, snapped_height = self._snapped_tile_size(width, height)
            if self.get_size() != (snapped_width, snapped_height):
                self.resize(snapped_width, snapped_height)
            self.app.config.data.update({"floating-window-width": snapped_width,
                                         "floating-window-height": snapped_height})
            self.app.config.save()
            return False
        self._resize_idle = GLib.timeout_add(500, remember)

    def toggle_pinned(self, *_):
        value = not bool(self.app.config.data.get("floating-window-always-on-top", True))
        self.app.config.data["floating-window-always-on-top"] = value
        self.app.config.save()
        self.set_keep_above(self.tray_mode or value)

    def show_panel(self, content, width=470, height=560, cleanup=None):
        self.close_panel()
        layer = Gtk.EventBox()
        layer.get_style_context().add_class("maintenance-backdrop")
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.set_halign(Gtk.Align.CENTER); scroll.set_valign(Gtk.Align.CENTER)
        scroll.get_style_context().add_class("maintenance-panel")
        scroll.add(content)
        guard = Gtk.EventBox()
        guard.set_visible_window(False)
        guard.set_halign(Gtk.Align.CENTER); guard.set_valign(Gtk.Align.CENTER)
        guard.add(scroll)
        guard.connect("button-press-event", lambda *_: True)
        layer.add(guard)
        layer.connect("button-press-event", lambda *_: (self.close_panel(), True)[1])
        def fit(_widget, allocation):
            target = (max(1, min(width, allocation.width - 32)), max(1, min(height, allocation.height - 52)))
            if scroll.get_size_request() != target:
                scroll.set_size_request(*target)
                # size-allocate is emitted after child allocation; request a fresh pass outside it.
                GLib.idle_add(lambda: (layer.queue_resize(), False)[1] if layer is self._panel_layer else False)
        # Measure the viewport, not the overlay's requisition: using the latter prevents shrinking.
        self._panel_fit_id = self.window_overlay.connect("size-allocate", fit)
        def position(overlay, child, rect):
            if child is not layer:
                return False
            rect.x = rect.y = 0
            rect.width, rect.height = overlay.get_allocated_width(), overlay.get_allocated_height()
            fit(overlay, rect)
            return True
        self._panel_position_id = self.window_overlay.connect("get-child-position", position)
        fit(self.window_overlay, self.window_overlay.get_allocation())
        self._panel_layer, self._panel_cleanup = layer, cleanup
        self.window_overlay.add_overlay(layer)
        self._suppress_hide = True
        self.stack.set_sensitive(False)
        layer.show_all()

    def close_panel(self):
        layer, cleanup = self._panel_layer, self._panel_cleanup
        self._panel_layer = self._panel_cleanup = self._guide_refresh = None
        if self._panel_fit_id is not None:
            self.window_overlay.disconnect(self._panel_fit_id)
            self._panel_fit_id = None
        if self._panel_position_id is not None:
            self.window_overlay.disconnect(self._panel_position_id)
            self._panel_position_id = None
        if layer is not None:
            self.window_overlay.remove(layer)
        if cleanup:
            cleanup()
        self._suppress_hide = False
        self.stack.set_sensitive(True)

    def embed_dialog(self, dialog):
        """Retain the original dialog/controller, including its cleanup and response handlers."""
        dialog.hide()
        dialog.set_modal(False)
        child = dialog.get_child()
        if child is None:
            return
        dialog.remove(child)
        self.show_panel(child, 500, 600, cleanup=dialog.destroy)
        # Let each dialog validate/handle its response first. It closes the host only when destroyed.
        dialog.connect("destroy", lambda *_: self.close_panel() if self._panel_cleanup == dialog.destroy else None)

    def update_startup(self):
        if not hasattr(self, "_startup_layer"):
            return False
        state = self.app.startup
        loading = state.loading
        self._startup_count.set_text(i18n.t("{0} of {1} printers ready").format(state.ready, len(state.serials)))
        self._startup_layer.set_visible(loading)
        self.grid.set_opacity(.16 if loading else 1)
        if loading and self.get_visible(): self._spinner.start()
        else: self._spinner.stop()
        if self._guide_refresh:
            self._guide_refresh()
        waiting = [p.name for p in self.app.printers if p.serial not in state.received]
        self.footer.set_text(i18n.t("{0} printers awaiting data").format(len(waiting)) if waiting
                             else i18n.t("Print in peace — everything under control"))
        self.footer.set_tooltip_text(", ".join(waiting) if waiting else None)
        native = self.get_window()
        minimized = native is not None and bool(native.get_state() & Gdk.WindowState.ICONIFIED)
        if not loading and state.received and self.get_visible() and not minimized and self._panel_layer is None:
            if state.claim_guide(bool(self.app.config.data.get("gantry.onboarding.v1.seen", False))):
                self.show_onboarding()
        return False

    def show_onboarding(self):
        if edition.IS_LITE:
            return   # LITE ships no guide
        from .dashboard import PrinterCard
        self.app.startup.guide_claimed = True
        self.app.config.data["gantry.onboarding.v1.seen"] = True
        self.app.config.save()
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16, margin=18)
        title, description = Gtk.Label(xalign=0), Gtk.Label(xalign=0, wrap=True)
        title.get_style_context().add_class("title")
        description.set_max_width_chars(52)
        description.get_style_context().add_class("meta")
        source = Gtk.ComboBoxText()
        source.get_style_context().add_class("guide-source")
        preview = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        note = Gtk.Label(label=i18n.t("Read-only view · same widgets and settings as your dashboard"), wrap=True)
        note.set_max_width_chars(52); note.get_style_context().add_class("meta")
        nav = Gtk.Box(spacing=10)
        counter = Gtk.Label(xalign=0)
        back, next_button, close = [Gtk.Button(label=i18n.t(s)) for s in ("Previous step", "Next", "Close")]
        nav.pack_start(counter, True, True, 0)
        for button in (back, next_button, close):
            button.get_style_context().add_class("guide-action")
            nav.pack_start(button, False, False, 0)
        for widget in (title, description, source, preview, note, nav): body.pack_start(widget, False, False, 0)
        steps = [("Print progress", "The segmented bar and percentage show print progress. The clock shows remaining time and estimated finish; the layer icon shows current and total layers."),
                 ("Temperatures", "These are the same temperature fields as on your printer card. Values, targets and heating or cooling indicators come from the printer."),
                 ("Filament / AMS", "These are your actual AMS/EXT modules, slots and assigned rolls. Slot layout, material, colour and remaining amount follow the dashboard settings. This preview does not change assignments."),
                 ("Warnings and maintenance", "🔧 marks maintenance; ! marks an alert reported by the printer. They appear only when relevant. Open their details on the dashboard; offline means data is no longer arriving.")]
        state = {"step": 0, "serial": None, "card": None, "choices": [], "refreshing": False}
        def no_focus(widget):
            widget.set_can_focus(False)
            if isinstance(widget, Gtk.Container):
                for child in widget.get_children(): no_focus(child)
        def refresh():
            if state["refreshing"]:
                return
            state["refreshing"] = True
            step = state["step"]
            title.set_text(i18n.t(steps[step][0])); description.set_text(i18n.t(steps[step][1]))
            counter.set_text(f"{step + 1} / 4"); back.set_sensitive(step > 0)
            next_button.set_label(i18n.t("Done" if step == 3 else "Next"))
            available = [p for p in self.app.printers if p.serial in self.app.startup.received
                         and self.app.telemetry[p.serial].state != PrinterState.OFFLINE]
            choices = [(p.serial, p.name) for p in available]
            if choices != state["choices"]:
                state["choices"] = choices
                source.remove_all()
                for serial, name in choices: source.append(serial, i18n.t("Live data · {0}").format(name))
                selected = state["serial"] if state["serial"] in {s for s, _ in choices} else (choices[0][0] if choices else "")
                source.set_active_id(selected)
            serial = source.get_active_id()
            printer = next((p for p in available if p.serial == serial), None)
            if printer is None or state["serial"] != serial or state["card"] is None:
                for child in preview.get_children(): preview.remove(child)
                state["serial"], state["card"] = serial, None
                if printer:
                    card = PrinterCard(self.app, printer)
                    # An event shield prevents all assignments/menus; children cannot take keyboard focus.
                    shield = Gtk.EventBox(); shield.set_above_child(True); shield.set_visible_window(False)
                    shield.connect("button-press-event", lambda *_: True)
                    shield.add(card)
                    no_focus(card)
                    preview.pack_start(shield, False, False, 0)
                    state["card"] = card
                else:
                    waiting = Gtk.Label(label=i18n.t("Waiting for printer data. Your actual card will appear here after connecting."), wrap=True)
                    waiting.set_max_width_chars(48); preview.pack_start(waiting, False, False, 0)
            if state["card"] and printer:
                state["card"].update(self.app.telemetry[printer.serial])
                no_focus(state["card"])
            preview.show_all()
            state["refreshing"] = False
        source.connect("changed", lambda *_: refresh())
        def advance(delta):
            if state["step"] == 3 and delta > 0: self.close_panel(); return
            state["step"] = max(0, state["step"] + delta); refresh()
        back.connect("clicked", lambda *_: advance(-1))
        next_button.connect("clicked", lambda *_: advance(1))
        close.connect("clicked", lambda *_: self.close_panel())
        self.show_panel(body, 460, 590)
        self._guide_refresh = refresh
        refresh()
