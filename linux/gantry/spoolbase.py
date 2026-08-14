"""Spoolbase — embedded filament-stock inventory for the Linux Gantry app.

The GTK counterpart of the macOS Spoolbase popover: a window opened from the tray that lists the
user's filaments grouped by type, each with a coloured stock badge, plus add-from-catalog, edit,
delete and quick count changes. Data lives in ``$XDG_DATA_HOME/Spoolbase/inventory-v2.json`` so it
is independent of the printer config.

gi versions are pinned in app.py before this module is imported (see the GTK import-pinning note),
so importing gi.repository names here reuses the already-loaded GTK 3 bindings.
"""
from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from gi.repository import Gtk, Gdk  # type: ignore  # noqa: E402

TYPES = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "ESD", "PVA", "Support"]

_DATA_DIR = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "Spoolbase"
_INVENTORY = _DATA_DIR / "inventory-v2.json"
_CATALOG_EDIT = _DATA_DIR / "catalog.json"
_CATALOG_BUNDLED = Path(__file__).resolve().parent / "data" / "filament-catalog.json"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def normalized_hex(value: str) -> str:
    filtered = (value or "").strip().lstrip("#").upper()
    if len(filtered) == 6 and all(c in "0123456789ABCDEF" for c in filtered):
        return filtered
    return "8E8E93"


@dataclass
class Filament:
    brand: str
    name: str
    type: str
    colorName: str
    colorHex: str
    id: str = field(default_factory=lambda: str(uuid.uuid4()))
    catalogID: str | None = None
    manufacturerCode: str = ""
    spoolCount: int = 0
    notes: str = ""
    updatedAt: str = field(default_factory=_now)

    def __post_init__(self) -> None:
        self.colorHex = normalized_hex(self.colorHex)
        self.spoolCount = max(0, int(self.spoolCount))

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Filament":
        return cls(
            brand=data.get("brand", ""), name=data.get("name", ""), type=data.get("type", ""),
            colorName=data.get("colorName", ""), colorHex=data.get("colorHex", "8E8E93"),
            id=data.get("id", str(uuid.uuid4())), catalogID=data.get("catalogID"),
            manufacturerCode=data.get("manufacturerCode", ""), spoolCount=data.get("spoolCount", 0),
            notes=data.get("notes", ""), updatedAt=data.get("updatedAt", _now()),
        )


def load_catalog() -> list[dict[str, Any]]:
    for path in (_CATALOG_EDIT, _CATALOG_BUNDLED):
        try:
            if path.exists():
                items = json.loads(path.read_text())
                if isinstance(items, list):
                    return items
        except (OSError, ValueError):
            continue
    return []


def save_catalog(catalog: list[dict[str, Any]]) -> None:
    try:
        _DATA_DIR.mkdir(parents=True, exist_ok=True)
        _CATALOG_EDIT.write_text(json.dumps(catalog, indent=2, sort_keys=True))
    except OSError:
        pass


class FilamentStore:
    """Loads/saves the inventory and notifies on change."""

    def __init__(self) -> None:
        self.filaments: list[Filament] = []
        self.on_change: Callable[[], None] | None = None
        try:
            if _INVENTORY.exists():
                self.filaments = [Filament.from_dict(d) for d in json.loads(_INVENTORY.read_text())]
            else:
                self._save()
        except (OSError, ValueError):
            self.filaments = []

    def add(self, filament: Filament) -> None:
        if filament.catalogID is not None:
            for existing in self.filaments:
                if existing.catalogID == filament.catalogID:
                    existing.spoolCount += max(1, filament.spoolCount)
                    existing.updatedAt = _now()
                    self._changed()
                    return
        self.filaments.append(filament)
        self._changed()

    def update(self, filament: Filament) -> None:
        for index, existing in enumerate(self.filaments):
            if existing.id == filament.id:
                self.filaments[index] = filament
                self._changed()
                return

    def delete(self, filament_id: str) -> None:
        self.filaments = [f for f in self.filaments if f.id != filament_id]
        self._changed()

    def adjust(self, filament_id: str, spools: int) -> None:
        for existing in self.filaments:
            if existing.id == filament_id:
                existing.spoolCount = max(0, existing.spoolCount + spools)
                existing.updatedAt = _now()
                self._changed()
                return

    def _changed(self) -> None:
        self._save()
        if self.on_change:
            self.on_change()

    def _save(self) -> None:
        try:
            _DATA_DIR.mkdir(parents=True, exist_ok=True)
            data = [asdict(f) for f in self.filaments]
            _INVENTORY.write_text(json.dumps(data, indent=2, sort_keys=True))
        except OSError:
            pass


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


class SpoolbaseWindow(Gtk.Window):
    """Tray-anchored filament inventory, styled to match the Gantry dashboard."""

    def __init__(self, app: Any) -> None:
        super().__init__()
        self.app = app
        self.store = FilamentStore()
        self.store.on_change = self._render
        self._suppress_hide = False
        self._just_shown = False
        self._query = ""
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
        self.add(root)

        header = Gtk.Box(spacing=10)
        header.get_style_context().add_class("header")
        titles = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        title = Gtk.Label(label="Spoolbase", xalign=0)
        title.get_style_context().add_class("title")
        self.summary = Gtk.Label(xalign=0)
        self.summary.get_style_context().add_class("subtitle")
        titles.pack_start(title, False, False, 0)
        titles.pack_start(self.summary, False, False, 0)
        add = Gtk.Button(label="＋")
        add.connect("clicked", lambda _b: self._open_catalog())
        header.pack_start(titles, True, True, 0)
        header.pack_start(add, False, False, 0)
        root.pack_start(header, False, False, 0)

        self.search = Gtk.SearchEntry()
        self.search.set_placeholder_text(
            "Szukaj nazwy, koloru lub kodu…" if self._pl else "Search name, colour or code…")
        self.search.connect("search-changed", self._on_search)
        search_row = Gtk.Box(); search_row.set_margin_start(16); search_row.set_margin_end(16)
        search_row.set_margin_bottom(8)
        search_row.pack_start(self.search, True, True, 0)
        root.pack_start(search_row, False, False, 0)

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
        if not self._query:
            return list(self.store.filaments)
        result = []
        for item in self.store.filaments:
            text = " ".join([item.brand, item.name, item.type, item.colorName,
                             item.colorHex, item.manufacturerCode]).lower()
            if self._query in text:
                result.append(item)
        return result

    def _render(self) -> None:
        for child in self.list_box.get_children():
            self.list_box.remove(child)

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

    def _open_editor(self, item: Filament | None) -> None:
        self._suppress_hide = True
        try:
            dialog = EditorDialog(self, self.store, item)
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
        content.pack_start(self.search, False, False, 0)

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
        self.store.add(Filament(
            brand=entry.get("brand", ""), name=entry.get("name", ""), type=entry.get("type", ""),
            colorName=entry.get("colorName", ""), colorHex=entry.get("colorHex", "8E8E93"),
            catalogID=entry.get("id"), manufacturerCode=entry.get("manufacturerCode", ""), spoolCount=1))
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

    def __init__(self, parent: SpoolbaseWindow, store: FilamentStore, item: Filament | None) -> None:
        pl = parent._pl
        is_new = item is None
        super().__init__(
            title=("Nowy filament" if pl else "New filament") if is_new
            else ("Edytuj filament" if pl else "Edit filament"),
            transient_for=parent, modal=True)
        self.store = store
        self.original = item
        self.is_new = is_new
        self.set_default_size(360, 400)

        content = self.get_content_area()
        content.set_spacing(6)
        content.set_margin_top(12); content.set_margin_bottom(12)
        content.set_margin_start(14); content.set_margin_end(14)

        base = item or Filament(brand="", name="", type="PLA",
                                 colorName="Nowy" if pl else "New", colorHex="8E8E93")
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
            self.store.add(updated)
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
