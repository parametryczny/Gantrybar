"""Assign-a-roll panel for the Linux dashboard, the GTK counterpart of the macOS SpoolAssignPopover
and the Windows slot panel: click an AMS/EXT slot on a card and pick which physical Spoolbase roll
sits there, set its remaining grams, move an existing roll in, or detach it back to storage.

gi is already pinned in app.py before this module is imported (see the import-pinning note).
"""
from __future__ import annotations

from typing import Any

from gi.repository import Gtk, GLib  # type: ignore  # noqa: E402

from .physicalspool import location_for


def _pl(app: Any) -> bool:
    return getattr(app, "language", "pl") == "pl"


def _filament_label(app: Any, definition_id: str | None) -> str:
    if not definition_id:
        return "bez katalogu" if _pl(app) else "no catalogue"
    store = getattr(app, "filament_store", None)
    if store is not None:
        for f in store.filaments:
            if f.id == definition_id:
                return f"{f.brand} {f.name} · {f.colorName}".strip(" ·")
    return definition_id


def open_assign_dialog(app: Any, serial: str, group: Any, group_index: int, slot: Any, slot_index: int) -> None:
    store = getattr(app, "physical_spools", None)
    inventory = getattr(app, "filament_store", None)
    if store is None:
        return
    pl = _pl(app)
    location = location_for(serial, getattr(group, "external", False), group_index, slot_index)
    printer_name = next((p.name for p in app.printers if p.serial == serial), serial)
    slot_label = group.display_name if getattr(group, "external", False) else f"{group.display_name} {slot.label}"

    dialog = Gtk.Dialog(title=("Przypisz rolkę" if pl else "Assign roll"),
                        transient_for=getattr(app, "window", None), modal=True)
    dialog.set_default_size(360, -1)
    content = dialog.get_content_area()
    content.set_spacing(8)
    content.set_border_width(14)

    head = Gtk.Label(xalign=0)
    head.set_markup(f"<b>{GLib.markup_escape_text(printer_name)}</b>  ·  {GLib.markup_escape_text(slot_label)}")
    content.pack_start(head, False, False, 0)

    assigned = store.spool_at(location)
    if assigned is not None:
        percent = store.percent(assigned)
        info = Gtk.Label(xalign=0)
        info.set_markup(
            (f"Przypisano: <b>{assigned.get('id')}</b> ({_filament_label(app, assigned.get('filamentDefinitionID'))})"
             if pl else
             f"Assigned: <b>{assigned.get('id')}</b> ({_filament_label(app, assigned.get('filamentDefinitionID'))})"))
        content.pack_start(info, False, False, 0)

        grams_row = Gtk.Box(spacing=8)
        grams_row.pack_start(Gtk.Label(label=("Pozostało (g):" if pl else "Remaining (g):"), xalign=0), False, False, 0)
        nominal = float(assigned.get("nominalWeightGrams", 1000) or 1000)
        spin = Gtk.SpinButton.new_with_range(0, max(nominal, 1), 5)
        spin.set_value(float(assigned.get("remainingWeightGrams", 0) or 0))
        grams_row.pack_start(spin, True, True, 0)
        save = Gtk.Button(label=("Zapisz" if pl else "Save"))
        grams_row.pack_start(save, False, False, 0)
        content.pack_start(grams_row, False, False, 0)

        pct = Gtk.Label(xalign=0)
        pct.get_style_context().add_class("subtitle")
        pct.set_text(f"{percent}% · {int(nominal)} g nominał" if pl else f"{percent}% · {int(nominal)} g nominal")
        content.pack_start(pct, False, False, 0)

        detach = Gtk.Button(label=("Odłącz (do magazynu)" if pl else "Detach (to storage)"))
        content.pack_start(detach, False, False, 0)

        def do_save(_b: Gtk.Button) -> None:
            store.set_remaining(assigned["id"], spin.get_value())
            _refresh(app, serial)
            dialog.destroy()

        def do_detach(_b: Gtk.Button) -> None:
            store.clear_slot(location)
            _refresh(app, serial)
            dialog.destroy()

        save.connect("clicked", do_save)
        detach.connect("clicked", do_detach)
        content.pack_start(Gtk.Separator(), False, False, 4)

    # --- assign a new / existing roll ----------------------------------------
    picker_label = Gtk.Label(xalign=0)
    picker_label.set_text(("Przypisz rolkę:" if pl else "Assign a roll:"))
    content.pack_start(picker_label, False, False, 0)

    combo = Gtk.ComboBoxText()
    combo.append("__new__", ("Nowa rolka" if pl else "New roll"))
    # Existing rolls that are in storage (or elsewhere) can be moved into this slot.
    for spool in store.spools:
        if spool is assigned:
            continue
        loc = spool.get("location") or {}
        where = "magazyn" if loc.get("printerSerial") is None else str(loc.get("printerSerial"))
        if not pl and loc.get("printerSerial") is None:
            where = "storage"
        combo.append(f"spool:{spool.get('id')}",
                     f"{spool.get('id')} · {_filament_label(app, spool.get('filamentDefinitionID'))} · {where}")
    # The user's Spoolbase inventory: creating a roll from a known filament links it for consumption.
    if inventory is not None:
        for f in inventory.filaments:
            combo.append(f"def:{f.id}", f"{f.brand} {f.name} · {f.colorName} ({f.type})")
    combo.set_active_id("__new__")
    content.pack_start(combo, False, False, 0)

    nom_row = Gtk.Box(spacing=8)
    nom_row.pack_start(Gtk.Label(label=("Nominał (g):" if pl else "Nominal (g):"), xalign=0), False, False, 0)
    nominal_spin = Gtk.SpinButton.new_with_range(100, 5000, 50)
    nominal_spin.set_value(1000)
    nom_row.pack_start(nominal_spin, True, True, 0)
    content.pack_start(nom_row, False, False, 0)

    dialog.add_button(("Anuluj" if pl else "Cancel"), Gtk.ResponseType.CANCEL)
    dialog.add_button(("Przypisz" if pl else "Assign"), Gtk.ResponseType.OK)

    def on_response(_d: Gtk.Dialog, response: int) -> None:
        if response == Gtk.ResponseType.OK:
            choice = combo.get_active_id() or "__new__"
            if choice.startswith("spool:"):
                store.assign(choice.split(":", 1)[1], location)
            elif choice.startswith("def:"):
                nominal = nominal_spin.get_value()
                store.create_spool(choice.split(":", 1)[1], nominal, nominal, location)
            else:
                nominal = nominal_spin.get_value()
                store.create_spool(None, nominal, nominal, location)
            _refresh(app, serial)
        dialog.destroy()

    dialog.connect("response", on_response)
    dialog.show_all()


def _refresh(app: Any, serial: str) -> None:
    try:
        app.rebuild_cards()
    except Exception:
        pass
