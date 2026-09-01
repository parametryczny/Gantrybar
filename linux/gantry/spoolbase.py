"""Spoolbase — embedded filament-stock inventory for the Linux Gantry app.

The GTK counterpart of the macOS Spoolbase popover: a window opened from the tray that lists the
user's filaments grouped by type, each with a coloured stock badge, plus add-from-catalog, edit,
delete and quick count changes. Data lives in ``$XDG_DATA_HOME/Spoolbase/inventory-v2.json`` so it
is independent of the printer config.

gi versions are pinned in app.py before this module is imported (see the GTK import-pinning note),
so importing gi.repository names here reuses the already-loaded GTK 3 bindings.
"""
from __future__ import annotations

import uuid
from typing import Any

from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # type: ignore  # noqa: E402

try:
    import gi
    gi.require_version("Gst", "1.0")
    from gi.repository import Gst  # type: ignore  # noqa: E402
    Gst.init(None)
except (ImportError, ValueError):
    Gst = None  # type: ignore[assignment]

from .filamentstore import Filament, FilamentStore, TYPES, load_catalog, normalized_hex, save_catalog


def _badge_class(count: int, red_max: int, blue_max: int) -> str:
    if count == 0:
        return "zero"
    if count <= red_max:
        return "red"
    if count <= blue_max:
        return "blue"
    return "green"


def _variant_word(n: int, pl: bool) -> str:
    if not pl:
        return "variant" if n == 1 else "variants"
    if n == 1:
        return "wariant"
    if n % 10 in (2, 3, 4) and n % 100 not in (12, 13, 14):
        return "warianty"
    return "wariantów"


class FilamentIcon(Gtk.DrawingArea):
    """Cairo port of the code-drawn filament mark used by the macOS Spoolbase header."""

    def __init__(self, size: int = 28) -> None:
        super().__init__()
        self.set_size_request(size, size)
        self.get_style_context().add_class("sb-icon")
        self.connect("draw", self._draw)

    def _draw(self, _widget: Gtk.Widget, context: Any) -> bool:
        width = float(self.get_allocated_width())
        height = float(self.get_allocated_height())
        color = self.get_style_context().get_color(Gtk.StateFlags.NORMAL)
        context.set_source_rgba(color.red, color.green, color.blue, color.alpha)
        context.set_line_width(max(1.4, min(width, height) * 0.075))
        context.set_line_cap(1)
        context.set_line_join(1)
        context.move_to(width * 0.71, height * 0.07)
        context.curve_to(width * 0.39, height * 0.10, width * 0.17, height * 0.24,
                         width * 0.19, height * 0.47)
        context.curve_to(width * 0.20, height * 0.74, width * 0.32, height * 0.88,
                         width * 0.51, height * 0.88)
        context.curve_to(width * 0.73, height * 0.89, width * 0.85, height * 0.76,
                         width * 0.83, height * 0.57)
        context.curve_to(width * 0.81, height * 0.39, width * 0.70, height * 0.29,
                         width * 0.60, height * 0.28)
        context.stroke()
        context.arc(width * 0.535, height * 0.545, width * 0.235, 0, 6.2832)
        context.stroke()
        context.arc(width * 0.535, height * 0.545, width * 0.165, 0, 6.2832)
        context.stroke()
        return False


class SpoolbaseWindow(Gtk.Window):
    """Tray-anchored filament inventory, styled to match the Gantry dashboard."""

    def __init__(self, app: Any) -> None:
        super().__init__()
        self.app = app
        self.store = getattr(app, "filament_store", None) or FilamentStore()
        self.store.on_change = self._render
        self._suppress_hide = False
        self._just_shown = False
        self._query = ""
        self._selected_type: str | None = None
        self._selected_brand: str | None = None
        self._low_only = False
        self.red_max = int(app.config.data.get("stock_red_max", 1))
        self.blue_max = int(app.config.data.get("stock_blue_max", 5))

        rgba = self.get_screen().get_rgba_visual()
        if rgba is not None:
            self.set_visual(rgba)
        self.tray_mode = getattr(app.window, "tray_mode", False)
        if self.tray_mode:
            self.set_default_size(500, 600)
            self.set_decorated(False)
            self.set_skip_taskbar_hint(True)
            self.set_skip_pager_hint(True)
            self.set_resizable(False)
            self.set_keep_above(True)
            try:
                self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
            except Exception:
                pass
            self.get_style_context().add_class("popover-window")
            self.connect("focus-out-event", self._on_focus_out)
        else:
            self.set_title("Spoolbase")
            self.set_default_size(500, 640)
            self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("delete-event", self._hide)

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.get_style_context().add_class("sb-root")
        self.add(root)

        header = Gtk.Box(spacing=10)
        header.get_style_context().add_class("sb-header")
        identity = Gtk.Box(spacing=9)
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        title = Gtk.Label(label="Spoolbase", xalign=0)
        title.get_style_context().add_class("sb-title")
        self.summary = Gtk.Label(xalign=0)
        self.summary.get_style_context().add_class("sb-summary")
        titles.pack_start(title, False, False, 0)
        titles.pack_start(self.summary, False, False, 0)
        identity.pack_start(FilamentIcon(), False, False, 0)
        identity.pack_start(titles, False, False, 0)
        add = Gtk.Button(label="＋")
        add.set_tooltip_text("Dodaj filament" if self._pl else "Add filament")
        add.connect("clicked", lambda _b: self._open_catalog())
        header.pack_start(identity, True, True, 0)
        header.pack_start(add, False, False, 0)
        root.pack_start(header, False, False, 0)

        self.search = Gtk.SearchEntry()
        self.search.get_style_context().add_class("sb-search")
        self.search.set_placeholder_text(
            "Szukaj nazwy, koloru lub kodu…" if self._pl else "Search name, colour or code…")
        self.search.connect("search-changed", self._on_search)
        toolbar = Gtk.Box(spacing=8)
        toolbar.get_style_context().add_class("sb-toolbar")
        toolbar.pack_start(self.search, True, True, 0)
        filters = Gtk.Button(label=("☷  Filtry" if self._pl else "☷  Filters"))
        filters.get_style_context().add_class("sb-filter")
        filters.connect("clicked", self._show_filters)
        toolbar.pack_start(filters, False, False, 0)
        root.pack_start(toolbar, False, False, 0)
        self.chips = Gtk.Box(spacing=6)
        self.chips.get_style_context().add_class("sb-chips")
        root.pack_start(self.chips, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.list_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.list_box.set_margin_start(14); self.list_box.set_margin_end(14)
        self.list_box.set_margin_bottom(10)
        scroll.add(self.list_box)
        root.pack_start(scroll, True, True, 0)

        self._render()

    @property
    def _pl(self) -> bool:
        return self.app.language == "pl"

    # ---- rendering ------------------------------------------------------------------------

    def _on_search(self, entry: Gtk.SearchEntry) -> None:
        self._query = entry.get_text().strip().lower()
        self._render()

    def _filtered(self) -> list[Filament]:
        result = []
        for item in self.store.filaments:
            if self._selected_type and item.type != self._selected_type:
                continue
            if self._selected_brand and item.brand != self._selected_brand:
                continue
            if self._low_only and item.spoolCount > self.red_max:
                continue
            text = " ".join([item.brand, item.name, item.type, item.colorName,
                             item.colorHex, item.manufacturerCode]).lower()
            if not self._query or self._query in text:
                result.append(item)
        return result

    def _render(self) -> None:
        for child in self.list_box.get_children():
            self.list_box.remove(child)
        self._render_chips()

        spools = sum(f.spoolCount for f in self.store.filaments)
        variants = len(self.store.filaments)
        if self._pl:
            self.summary.set_text(f"{spools} szpul · {variants} {_variant_word(variants, True)}")
        else:
            spool_word = "spool" if spools == 1 else "spools"
            self.summary.set_text(f"{spools} {spool_word} · {variants} {_variant_word(variants, False)}")

        items = self._filtered()
        if not items:
            empty = Gtk.Label(
                label=("Brak filamentów dla wybranych filtrów" if self._pl else "No filaments match"))
            empty.get_style_context().add_class("sb-empty")
            empty.set_margin_top(40)
            self.list_box.pack_start(empty, False, False, 0)
            self.list_box.show_all()
            return

        grouped: dict[str, list[Filament]] = {}
        for item in items:
            grouped.setdefault(item.type, []).append(item)
        ordered = [t for t in TYPES if t in grouped] + sorted(t for t in grouped if t not in TYPES)

        for index, type_name in enumerate(ordered):
            self.list_box.pack_start(self._section(type_name, grouped[type_name], index > 0), False, False, 0)
        self.list_box.show_all()

    def _show_filters(self, button: Gtk.Button) -> None:
        menu = Gtk.Menu()
        types = [value for value in TYPES if any(item.type == value for item in self.store.filaments)]
        brands = sorted({item.brand for item in self.store.filaments if item.brand})

        type_title = Gtk.MenuItem(label="Typ" if self._pl else "Type")
        type_title.set_sensitive(False)
        menu.append(type_title)
        for value in types:
            item = Gtk.CheckMenuItem(label=value)
            item.set_active(value == self._selected_type)
            item.connect("activate", lambda _item, selected=value: self._set_filter("type", selected))
            menu.append(item)
        menu.append(Gtk.SeparatorMenuItem())
        low = Gtk.CheckMenuItem(label="Niski stan" if self._pl else "Low stock")
        low.set_active(self._low_only)
        low.connect("activate", lambda *_: self._set_filter("low", "1"))
        menu.append(low)
        menu.append(Gtk.SeparatorMenuItem())
        brand_title = Gtk.MenuItem(label="Marka" if self._pl else "Brand")
        brand_title.set_sensitive(False)
        menu.append(brand_title)
        for value in brands:
            item = Gtk.CheckMenuItem(label=value)
            item.set_active(value == self._selected_brand)
            item.connect("activate", lambda _item, selected=value: self._set_filter("brand", selected))
            menu.append(item)
        menu.show_all()
        menu.popup_at_widget(button, Gdk.Gravity.SOUTH_EAST, Gdk.Gravity.NORTH_EAST, None)

    def _set_filter(self, kind: str, value: str | None) -> None:
        if kind == "type":
            self._selected_type = None if self._selected_type == value else value
        elif kind == "brand":
            self._selected_brand = None if self._selected_brand == value else value
        elif kind == "low":
            self._low_only = not self._low_only
        self._render()

    def _render_chips(self) -> None:
        for child in self.chips.get_children():
            self.chips.remove(child)
        values = (("type", self._selected_type), ("brand", self._selected_brand),
                  ("low", "Niski stan" if self._pl else "Low stock") if self._low_only else ("low", None))
        for kind, value in values:
            if not value:
                continue
            chip = Gtk.Button(label=f"{value}  ×")
            chip.get_style_context().add_class("sb-chip")
            chip.connect("clicked", lambda _button, selected=kind: self._clear_filter(selected))
            self.chips.pack_start(chip, False, False, 0)
        self.chips.show_all()

    def _clear_filter(self, kind: str) -> None:
        if kind == "type": self._selected_type = None
        elif kind == "brand": self._selected_brand = None
        elif kind == "low": self._low_only = False
        self._render()

    def _section(self, type_name: str, items: list[Filament], separator: bool) -> Gtk.Widget:
        section = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        section.set_margin_top(13 if separator else 8)
        section.set_margin_bottom(9)
        if separator:
            section.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 0)

        head = Gtk.Box()
        type_label = Gtk.Label(label=type_name, xalign=0)
        type_label.get_style_context().add_class("sb-type")
        count = len(items)
        noun = ("filament" if count == 1 else "filamentów") if self._pl else ("filament" if count == 1 else "filaments")
        count_label = Gtk.Label(label=f"{count} {noun}", xalign=1)
        count_label.get_style_context().add_class("sb-count")
        head.pack_start(type_label, True, True, 0)
        head.pack_start(count_label, False, False, 0)
        section.pack_start(head, False, False, 0)

        grid = Gtk.Grid(column_spacing=5, row_spacing=4, column_homogeneous=True)
        for i, item in enumerate(items):
            grid.attach(self._tile(item), i % 2, i // 2, 1, 1)
        section.pack_start(grid, False, False, 0)
        return section

    def _tile(self, item: Filament) -> Gtk.Widget:
        event = Gtk.EventBox()
        event.get_style_context().add_class("sb-tile")
        event.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        event.connect("button-press-event", self._tile_clicked, item)

        row = Gtk.Box(spacing=8)
        row.pack_start(self._swatch(item.colorHex), False, False, 0)

        labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        color = Gtk.Label(label=item.colorName, xalign=0)
        color.get_style_context().add_class("sb-color")
        color.set_ellipsize(3)  # Pango.EllipsizeMode.END
        product = Gtk.Label(label=f"{item.brand} · {item.name}", xalign=0)
        product.get_style_context().add_class("sb-product")
        product.set_ellipsize(3)
        labels.pack_start(color, False, False, 0)
        labels.pack_start(product, False, False, 0)
        row.pack_start(labels, True, True, 0)

        badge = Gtk.Label(label=str(item.spoolCount))
        ctx = badge.get_style_context(); ctx.add_class("sb-badge")
        ctx.add_class(_badge_class(item.spoolCount, self.red_max, self.blue_max))
        badge.set_valign(Gtk.Align.CENTER)
        row.pack_start(badge, False, False, 0)

        event.add(row)
        return event

    @staticmethod
    def _swatch(hexcolor: str, size: int = 30) -> Gtk.Widget:
        box = Gtk.Box()
        box.set_size_request(size, size)
        box.set_valign(Gtk.Align.CENTER)
        ctx = box.get_style_context(); ctx.add_class("sb-swatch")
        provider = Gtk.CssProvider()
        provider.load_from_data((".sb-swatch { background-color: #%s; }" % normalized_hex(hexcolor)).encode())
        ctx.add_provider(provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        return box

    # ---- interactions ---------------------------------------------------------------------

    def _tile_clicked(self, widget: Gtk.Widget, event: Gdk.EventButton, item: Filament) -> bool:
        if event.button == 3:
            self._tile_menu(widget, event, item)
            return True
        self._quick_stock(widget, item)
        return True

    def _quick_stock(self, anchor: Gtk.Widget, item: Filament) -> None:
        popover = Gtk.Popover(); popover.set_relative_to(anchor)
        popover.set_position(Gtk.PositionType.BOTTOM)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_margin_top(11); box.set_margin_bottom(11); box.set_margin_start(11); box.set_margin_end(11)
        title = Gtk.Label(label=f"{item.colorName} · {item.brand}", xalign=0)
        title.get_style_context().add_class("subtitle")
        title.set_ellipsize(3)
        box.pack_start(title, False, False, 0)
        stepper = Gtk.Box(spacing=6)
        value = Gtk.Label(label=str(item.spoolCount))
        value.set_width_chars(3)

        def refresh() -> None:
            fresh = next((f for f in self.store.filaments if f.id == item.id), None)
            value.set_text(str(fresh.spoolCount if fresh else 0))

        minus = Gtk.Button(label="−"); plus = Gtk.Button(label="＋")
        minus.connect("clicked", lambda _b: (self.store.adjust(item.id, -1), refresh()))
        plus.connect("clicked", lambda _b: (self.store.adjust(item.id, +1), refresh()))
        stepper.pack_start(minus, True, True, 0)
        stepper.pack_start(value, False, False, 0)
        stepper.pack_start(plus, True, True, 0)
        box.pack_start(stepper, False, False, 0)
        popover.add(box)
        popover.show_all()
        popover.popup()

    def _tile_menu(self, widget: Gtk.Widget, event: Gdk.EventButton, item: Filament) -> None:
        menu = Gtk.Menu()
        change = Gtk.MenuItem(label="Zmień liczbę szpul…" if self._pl else "Change spool count…")
        change.connect("activate", lambda _m: self._quick_stock(widget, item))
        menu.append(change)
        edit = Gtk.MenuItem(label="Edytuj…" if self._pl else "Edit…")
        edit.connect("activate", lambda _m: self._open_editor(item))
        menu.append(edit)
        menu.append(Gtk.SeparatorMenuItem())
        delete = Gtk.MenuItem(label="Usuń z moich filamentów" if self._pl else "Remove from my filaments")
        delete.connect("activate", lambda _m: self._confirm_delete(item))
        menu.append(delete)
        menu.show_all()
        menu.popup_at_pointer(event)

    def _confirm_delete(self, item: Filament) -> None:
        self._suppress_hide = True
        dialog = Gtk.MessageDialog(
            transient_for=self, modal=True, message_type=Gtk.MessageType.WARNING,
            buttons=Gtk.ButtonsType.OK_CANCEL,
            text=("Usunąć z moich filamentów?" if self._pl else "Remove from my filaments?"))
        dialog.format_secondary_text(f"{item.brand} • {item.name} • {item.colorName}")
        response = dialog.run()
        dialog.destroy()
        self._suppress_hide = False
        if response == Gtk.ResponseType.OK:
            self.store.delete(item.id)

    def _open_catalog(self) -> None:
        self._suppress_hide = True
        try:
            dialog = CatalogDialog(self, self.store)
            dialog.run()
            dialog.destroy()
        finally:
            self._suppress_hide = False

    def _open_editor(self, item: Filament | None, prefilled_code: str | None = None) -> None:
        self._suppress_hide = True
        try:
            dialog = EditorDialog(self, self.store, item, prefilled_code)
            dialog.run()
            dialog.destroy()
        finally:
            self._suppress_hide = False

    # ---- show / hide ----------------------------------------------------------------------

    def present_panel(self) -> None:
        self.show_all()
        if self.tray_mode:
            self._position_top_right()
        self.present()
        self._just_shown = True
        from gi.repository import GLib  # local import; GLib is loaded via app.py's pinned gi
        GLib.timeout_add(300, self._clear_just_shown)

    def _clear_just_shown(self) -> bool:
        self._just_shown = False
        return False

    def _position_top_right(self) -> None:
        display = Gdk.Display.get_default()
        if display is None:
            return
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        if monitor is None:
            return
        area = monitor.get_workarea()
        width, _height = self.get_size()
        self.move(area.x + area.width - width - 8, area.y + 8)

    def _hide(self, *_args: object) -> bool:
        self.hide()
        return True

    def _on_focus_out(self, *_args: object) -> bool:
        if not self._just_shown and not self._suppress_hide:
            self.hide()
        return False


class BarcodeScannerDialog(Gtk.Dialog):
    """Webcam barcode reader using GStreamer's zbar element, with an in-window live preview."""

    def __init__(self, parent: Gtk.Window, on_code: Any, pl: bool) -> None:
        super().__init__(title="Skanuj kod filamentu" if pl else "Scan filament code",
                         transient_for=parent, modal=True)
        self.on_code = on_code
        self.pl = pl
        self.pipeline: Any | None = None
        self.handled = False
        self.set_default_size(520, 380)
        content = self.get_content_area()
        content.set_spacing(8)
        content.set_margin_top(12); content.set_margin_bottom(8)
        content.set_margin_start(14); content.set_margin_end(14)
        title = Gtk.Label(label=("Skanuj kod z etykiety szpuli" if pl else "Scan the code on the spool label"), xalign=0)
        title.get_style_context().add_class("title")
        content.pack_start(title, False, False, 0)
        self.status = Gtk.Label(label=("Wypełnij kodem ramkę i przytrzymaj etykietę nieruchomo"
                                       if pl else "Fill the frame with the code and hold the label still"), xalign=0)
        self.status.get_style_context().add_class("subtitle")
        content.pack_start(self.status, False, False, 0)
        frame = Gtk.Overlay()
        frame.set_size_request(480, 270)
        frame.get_style_context().add_class("card")
        self.preview = Gtk.Image()
        frame.add(self.preview)
        guide = Gtk.Frame()
        guide.set_size_request(280, 105)
        guide.set_halign(Gtk.Align.CENTER); guide.set_valign(Gtk.Align.CENTER)
        guide.set_shadow_type(Gtk.ShadowType.IN)
        frame.add_overlay(guide)
        content.pack_start(frame, True, True, 0)
        self.add_button("Anuluj" if pl else "Cancel", Gtk.ResponseType.CANCEL)
        self.connect("destroy", self._stop)
        self.show_all()
        GLib.idle_add(self._start)

    def _start(self) -> bool:
        if Gst is None:
            self._error("Brak obsługi GStreamer." if self.pl else "GStreamer support is unavailable.")
            return False
        if Gst.ElementFactory.find("zbar") is None:
            self._error(("Brak dekodera kodów. Zainstaluj pakiet gstreamer1.0-plugins-bad."
                         if self.pl else "Barcode decoder missing. Install gstreamer1.0-plugins-bad."))
            return False
        try:
            self.pipeline = Gst.parse_launch(
                "autovideosrc ! videoconvert ! tee name=t "
                "t. ! queue ! videoconvert ! video/x-raw,format=RGB ! "
                "appsink name=preview emit-signals=true max-buffers=1 drop=true sync=false "
                "t. ! queue ! videoconvert ! zbar message=true ! fakesink sync=false")
            sink = self.pipeline.get_by_name("preview")
            sink.connect("new-sample", self._new_sample)
            bus = self.pipeline.get_bus(); bus.add_signal_watch(); bus.connect("message", self._message)
            if self.pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
                self._error("Nie można uruchomić kamery." if self.pl else "Could not start the camera.")
        except Exception as exc:
            self._error(str(exc))
        return False

    def _new_sample(self, sink: Any) -> Any:
        sample = sink.emit("pull-sample")
        if sample is None: return Gst.FlowReturn.ERROR
        caps = sample.get_caps().get_structure(0)
        width, height = caps.get_value("width"), caps.get_value("height")
        buffer = sample.get_buffer()
        data = buffer.extract_dup(0, buffer.get_size())
        pixels = GLib.Bytes.new(data)
        pixbuf = GdkPixbuf.Pixbuf.new_from_bytes(pixels, GdkPixbuf.Colorspace.RGB, False, 8,
                                                  width, height, width * 3)
        scaled = pixbuf.scale_simple(480, 270, GdkPixbuf.InterpType.BILINEAR)
        GLib.idle_add(self.preview.set_from_pixbuf, scaled)
        return Gst.FlowReturn.OK

    def _message(self, _bus: Any, message: Any) -> None:
        if message.type == Gst.MessageType.ELEMENT:
            structure = message.get_structure()
            if structure is not None and structure.get_name() == "barcode":
                code = str(structure.get_value("symbol") or "").strip()
                if code and not self.handled:
                    self.handled = True
                    self.response(Gtk.ResponseType.OK)
                    GLib.idle_add(self.on_code, code)
        elif message.type == Gst.MessageType.ERROR:
            error, _debug = message.parse_error()
            self._error(str(error))

    def _error(self, message: str) -> None:
        self.status.set_text(("Nie można uruchomić skanera: " if self.pl else "Could not start scanner: ") + message)

    def _stop(self, *_args: Any) -> None:
        if self.pipeline is not None and Gst is not None:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline = None


class CatalogDialog(Gtk.Dialog):
    """Searchable catalog picker — add a filament from the bundled catalog."""

    def __init__(self, parent: SpoolbaseWindow, store: FilamentStore) -> None:
        pl = parent._pl
        super().__init__(title="Dodaj filament" if pl else "Add filament",
                         transient_for=parent, modal=True)
        self.store = store
        self.parent_window = parent
        self.set_default_size(440, 540)
        self.catalog = load_catalog()

        content = self.get_content_area()
        content.set_spacing(8)
        content.set_margin_top(12); content.set_margin_bottom(12)
        content.set_margin_start(12); content.set_margin_end(12)

        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text("Szukaj…" if pl else "Search…")
        self.search.connect("search-changed", lambda _e: self.filter.refilter())
        search_row = Gtk.Box(spacing=8)
        search_row.pack_start(self.search, True, True, 0)
        scan = Gtk.Button(label="▣  Skanuj kod…" if pl else "▣  Scan code…")
        scan.connect("clicked", self._scan_code)
        search_row.pack_start(scan, False, False, 0)
        content.pack_start(search_row, False, False, 0)

        options = Gtk.Box(spacing=8)
        options.pack_start(Gtk.Label(label="Liczba szpul" if pl else "Spools"), False, False, 0)
        self.quantity = Gtk.SpinButton.new_with_range(1, 999, 1)
        self.quantity.set_value(1)
        self.quantity.set_width_chars(4)
        options.pack_start(self.quantity, False, False, 0)
        options.pack_start(Gtk.Label(label="Waga (g)" if pl else "Weight (g)"), False, False, 0)
        self.weight = Gtk.SpinButton.new_with_range(100, 5000, 50)
        self.weight.set_value(1000)
        self.weight.set_width_chars(6)
        options.pack_start(self.weight, False, False, 0)
        content.pack_start(options, False, False, 0)

        # id, hexcolor, display, sub, haystack
        self.model = Gtk.ListStore(str, str, str, str, str)
        for entry in self.catalog:
            hexcolor = normalized_hex(entry.get("colorHex", ""))
            display = f"{entry.get('brand', '')} · {entry.get('name', '')}"
            sub = f"{entry.get('colorName', '')} · {entry.get('type', '')}"
            haystack = " ".join([entry.get("brand", ""), entry.get("name", ""), entry.get("type", ""),
                                 entry.get("colorName", ""), entry.get("manufacturerCode", "")]).lower()
            self.model.append([entry.get("id", ""), f"#{hexcolor}", display, sub, haystack])

        self.filter = self.model.filter_new()
        self.filter.set_visible_func(self._visible)
        tree = Gtk.TreeView(model=self.filter)
        tree.set_headers_visible(False)
        tree.connect("row-activated", self._row_activated)
        self.tree = tree

        swatch = Gtk.CellRendererText(); swatch.set_property("xpad", 10)
        col_swatch = Gtk.TreeViewColumn("", swatch, cell_background=1)
        col_swatch.set_min_width(26)
        tree.append_column(col_swatch)
        text = Gtk.CellRendererText()
        col_text = Gtk.TreeViewColumn("", text)
        col_text.set_cell_data_func(text, self._render_text)
        tree.append_column(col_text)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.add(tree)
        content.pack_start(scroll, True, True, 0)

        self.add_button("Dodaj ręcznie…" if pl else "Add manually…", 100)
        self.add_button(parent.app.text.get("cancel", "Anuluj"), Gtk.ResponseType.CANCEL)
        add_btn = self.add_button(parent.app.text.get("add", "Dodaj"), Gtk.ResponseType.OK)
        add_btn.get_style_context().add_class("suggested-action")
        self.connect("response", self._on_response)
        self.show_all()

    def _scan_code(self, _button: Gtk.Button) -> None:
        scanner = BarcodeScannerDialog(self, self._handle_code, self.parent_window._pl)
        scanner.run()
        scanner.destroy()

    @staticmethod
    def _normalize_code(value: str) -> str:
        return "".join(ch for ch in value.upper() if ch.isalnum())

    def _handle_code(self, code: str) -> None:
        normalized = self._normalize_code(code)
        match = next((entry for entry in self.catalog
                      if self._normalize_code(entry.get("manufacturerCode", "")) == normalized), None)
        self.search.set_text(match.get("manufacturerCode", code) if match else code)
        self.filter.refilter()
        if match is not None:
            target_id = match.get("id")
            it = self.filter.get_iter_first()
            while it is not None:
                if self.filter[it][0] == target_id:
                    path = self.filter.get_path(it)
                    self.tree.get_selection().select_path(path)
                    self.tree.scroll_to_cell(path, None, True, 0.5, 0.0)
                    return
                if not self.filter.iter_next(it):
                    break
        prompt = Gtk.MessageDialog(
            transient_for=self, modal=True, message_type=Gtk.MessageType.INFO,
            buttons=Gtk.ButtonsType.NONE,
            text="Nie znaleziono kodu w bazie" if self.parent_window._pl else "Code not found in catalog")
        prompt.format_secondary_text((f"Odczytany kod: {code}\nMożesz dodać własny filament z tym kodem."
                                      if self.parent_window._pl else
                                      f"Scanned code: {code}\nYou can add a custom filament with this code."))
        prompt.add_button("OK", Gtk.ResponseType.CANCEL)
        prompt.add_button("Dodaj własny" if self.parent_window._pl else "Add custom", Gtk.ResponseType.OK)
        add_custom = prompt.run() == Gtk.ResponseType.OK
        prompt.destroy()
        if add_custom:
            self.destroy()
            self.parent_window._open_editor(None, code)

    def _visible(self, model: Gtk.TreeModel, it: Gtk.TreeIter, _data: Any) -> bool:
        query = self.search.get_text().strip().lower()
        if not query:
            return True
        return query in (model[it][4] or "")

    @staticmethod
    def _render_text(_col: Gtk.TreeViewColumn, cell: Gtk.CellRendererText,
                     model: Gtk.TreeModel, it: Gtk.TreeIter, _data: Any) -> None:
        display = GLib_escape(model[it][2])
        sub = GLib_escape(model[it][3])
        cell.set_property("markup", f"<b>{display}</b>\n<small>{sub}</small>")

    def _row_activated(self, _tree: Gtk.TreeView, path: Gtk.TreePath, _col: Gtk.TreeViewColumn) -> None:
        self._add_path(path)

    def _add_path(self, path: Gtk.TreePath) -> None:
        catalog_id = self.filter[path][0]
        entry = next((c for c in self.catalog if c.get("id") == catalog_id), None)
        if entry is None:
            return
        quantity = int(self.quantity.get_value())
        definition = self.store.add(Filament(
            brand=entry.get("brand", ""), name=entry.get("name", ""), type=entry.get("type", ""),
            colorName=entry.get("colorName", ""), colorHex=entry.get("colorHex", "8E8E93"),
            catalogID=entry.get("id"), manufacturerCode=entry.get("manufacturerCode", ""),
            spoolCount=quantity))
        physical = getattr(self.parent_window.app, "physical_spools", None)
        if physical is not None:
            physical.create_rolls(definition.id, quantity, self.weight.get_value())
        self.destroy()

    def _on_response(self, _dialog: Gtk.Dialog, response: int) -> None:
        if response == Gtk.ResponseType.OK:
            selection = self.tree.get_selection()
            model, it = selection.get_selected()
            if it is not None:
                self._add_path(model.get_path(it))
        elif response == 100:  # add manually
            self.destroy()
            self.parent_window._open_editor(None)


class EditorDialog(Gtk.Dialog):
    """Add or edit a single filament (all fields + spool count)."""

    def __init__(self, parent: SpoolbaseWindow, store: FilamentStore, item: Filament | None,
                 prefilled_code: str | None = None) -> None:
        pl = parent._pl
        is_new = item is None
        super().__init__(
            title=("Nowy filament" if pl else "New filament") if is_new
            else ("Edytuj filament" if pl else "Edit filament"),
            transient_for=parent, modal=True)
        self.store = store
        self.parent_window = parent
        self.original = item
        self.is_new = is_new
        self.set_default_size(360, 400)

        content = self.get_content_area()
        content.set_spacing(6)
        content.set_margin_top(12); content.set_margin_bottom(12)
        content.set_margin_start(14); content.set_margin_end(14)

        base = item or Filament(brand="", name="", type="PLA",
                                 colorName="Nowy" if pl else "New", colorHex="8E8E93",
                                 manufacturerCode=prefilled_code or "")
        self.brand = self._field(content, "Marka" if pl else "Brand", base.brand)
        self.name = self._field(content, "Nazwa" if pl else "Name", base.name)

        content.pack_start(self._label("Typ" if pl else "Type"), False, False, 0)
        self.type = Gtk.ComboBoxText()
        for t in TYPES:
            self.type.append(t, t)
        self.type.set_active_id(base.type if base.type in TYPES else "PLA")
        content.pack_start(self.type, False, False, 0)

        self.color_name = self._field(content, "Kolor" if pl else "Colour", base.colorName)
        self.color_hex = self._field(content, "Hex", base.colorHex)
        self.code = self._field(content, "Kod producenta" if pl else "Manufacturer code", base.manufacturerCode)

        content.pack_start(self._label("Liczba szpul" if pl else "Spool count"), False, False, 0)
        self.count = Gtk.SpinButton.new_with_range(0, 9999, 1)
        self.count.set_value(base.spoolCount)
        content.pack_start(self.count, False, False, 0)

        self.weight: Gtk.SpinButton | None = None
        if is_new:
            content.pack_start(self._label("Waga pełnej szpuli (g)" if pl else "Full spool weight (g)"),
                               False, False, 0)
            self.weight = Gtk.SpinButton.new_with_range(100, 5000, 50)
            self.weight.set_value(1000)
            content.pack_start(self.weight, False, False, 0)

        self.add_button(parent.app.text.get("cancel", "Anuluj"), Gtk.ResponseType.CANCEL)
        save = self.add_button(parent.app.text.get("save", "Zapisz"), Gtk.ResponseType.OK)
        save.get_style_context().add_class("suggested-action")
        self.connect("response", self._on_response)
        self.show_all()

    def _label(self, text: str) -> Gtk.Label:
        label = Gtk.Label(label=text, xalign=0)
        label.get_style_context().add_class("subtitle")
        return label

    def _field(self, content: Gtk.Box, label: str, value: str) -> Gtk.Entry:
        content.pack_start(self._label(label), False, False, 0)
        entry = Gtk.Entry(text=value or "")
        content.pack_start(entry, False, False, 0)
        return entry

    def _on_response(self, _dialog: Gtk.Dialog, response: int) -> None:
        if response != Gtk.ResponseType.OK:
            return
        base = self.original
        updated = Filament(
            brand=self.brand.get_text().strip(),
            name=self.name.get_text().strip(),
            type=self.type.get_active_id() or "PLA",
            colorName=self.color_name.get_text().strip(),
            colorHex=self.color_hex.get_text().strip(),
            id=base.id if base else str(uuid.uuid4()),
            catalogID=base.catalogID if base else None,
            manufacturerCode=self.code.get_text().strip(),
            spoolCount=int(self.count.get_value()),
            notes=base.notes if base else "",
        )
        if self.is_new:
            updated.catalogID = updated.catalogID or f"custom-{uuid.uuid4().hex}"
            definition = self.store.add(updated)
            physical = getattr(self.parent_window.app, "physical_spools", None)
            if physical is not None and self.weight is not None:
                physical.create_rolls(definition.id, updated.spoolCount, self.weight.get_value())
        else:
            self._upsert_catalog(updated)
            self.store.update(updated)

    @staticmethod
    def _upsert_catalog(f: Filament) -> None:
        catalog = load_catalog()
        catalog_id = f.catalogID or f"custom-{uuid.uuid4().hex}"
        f.catalogID = catalog_id
        entry = {"id": catalog_id, "brand": f.brand, "name": f.name, "type": f.type,
                 "colorName": f.colorName, "colorHex": f.colorHex, "manufacturerCode": f.manufacturerCode}
        for index, existing in enumerate(catalog):
            if existing.get("id") == catalog_id:
                catalog[index] = entry
                break
        else:
            catalog.append(entry)
        save_catalog(catalog)


def GLib_escape(text: str) -> str:
    from gi.repository import GLib  # loaded via app.py's pinned gi
    return GLib.markup_escape_text(text or "")
