"""Assign-a-roll panel for the Linux dashboard, the GTK counterpart of the macOS SpoolAssignPopover
and the Windows slot panel: click an AMS/EXT slot on a card and pick which physical Spoolbase roll
sits there, set its remaining grams, move an existing roll in, or detach it back to storage.

gi is already pinned in app.py before this module is imported (see the import-pinning note).
"""
from __future__ import annotations

from typing import Any

from gi.repository import Gtk, GLib  # type: ignore  # noqa: E402

from . import i18n
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


def _location_label(app: Any, location: dict[str, Any]) -> str:
    if not location or location.get("printerSerial") is None:
        return "magazyn" if _pl(app) else "storage"
    serial = str(location.get("printerSerial"))
    printer = next((p for p in app.printers if p.serial == serial), None)
    printer_name = printer.name if printer is not None else serial
    if location.get("feeder") == "ext":
        slot = "EXT"
    else:
        slot = f"AMS {int(location.get('amsIndex', 0)) + 1} · A{int(location.get('slot', 0)) + 1}"
    return f"{printer_name} · {slot}"


def _definition(app: Any, definition_id: str | None) -> Any | None:
    inventory = getattr(app, "filament_store", None)
    if inventory is None:
        return None
    return next((item for item in inventory.filaments if item.id == definition_id), None)


def _normal_color(value: str | None) -> str:
    text = (value or "").replace("#", "").upper()
    return text[:6] if len(text) >= 6 else text


def _matches_slot(app: Any, spool: dict[str, Any], slot: Any) -> bool:
    definition = _definition(app, spool.get("filamentDefinitionID"))
    material = (getattr(slot, "material", "") or "").upper()
    color = _normal_color(getattr(slot, "color", ""))
    if definition is None or not material:
        return False
    return (definition.type or "").upper() == material and (not color or _normal_color(definition.colorHex) == color)


def _confirm(parent: Gtk.Window, title: str, detail: str) -> bool:
    prompt = Gtk.MessageDialog(
        transient_for=parent, modal=True, message_type=Gtk.MessageType.QUESTION,
        buttons=Gtk.ButtonsType.YES_NO, text=title)
    prompt.format_secondary_text(detail)
    result = prompt.run() == Gtk.ResponseType.YES
    prompt.destroy()
    return result


def _correct_weight(parent: Gtk.Window, app: Any, store: Any, spool: dict[str, Any]) -> bool:
    pl = _pl(app)
    sheet = Gtk.Dialog(title=i18n.t("Correct weight"), transient_for=parent, modal=True)
    sheet.set_default_size(330, -1)
    box = sheet.get_content_area()
    box.set_spacing(7); box.set_border_width(12)
    fields: dict[str, Gtk.Entry] = {}
    values = {
        "net": str(int(float(spool.get("remainingWeightGrams", 0) or 0))),
        "gross": "",
        "tare": str(int(float(spool.get("tareGrams", 0) or 0))) if spool.get("tareGrams") is not None else "",
    }
    labels = {
        "net":i18n.t("Net (g)"),
        "gross":i18n.t("Gross (g)"),
        "tare":i18n.t("Empty-spool tare (g)"),
    }
    for key in ("net", "gross", "tare"):
        row = Gtk.Box(spacing=8)
        row.pack_start(Gtk.Label(label=labels[key], xalign=0), True, True, 0)
        entry = Gtk.Entry(text=values[key]); entry.set_width_chars(9)
        fields[key] = entry
        row.pack_start(entry, False, False, 0)
        box.pack_start(row, False, False, 0)
    hint = Gtk.Label(
        label=(i18n.t("Enter net, or gross and tare — tare will be subtracted.")),
        xalign=0, wrap=True)
    hint.get_style_context().add_class("subtitle")
    box.pack_start(hint, False, False, 0)
    sheet.add_button(i18n.t("Cancel"), Gtk.ResponseType.CANCEL)
    sheet.add_button(i18n.t("Save"), Gtk.ResponseType.OK)
    sheet.show_all()
    saved = False
    if sheet.run() == Gtk.ResponseType.OK:
        def number(entry: Gtk.Entry) -> float | None:
            try:
                return float(entry.get_text().strip().replace(",", "."))
            except ValueError:
                return None
        gross, tare, net = number(fields["gross"]), number(fields["tare"]), number(fields["net"])
        result = max(0.0, gross - tare) if gross is not None and tare is not None else net
        if result is not None:
            store.correct_weight(spool["id"], result, tare)
            saved = True
    sheet.destroy()
    return saved


def open_assign_dialog(app: Any, serial: str, group: Any, group_index: int, slot: Any, slot_index: int) -> None:
    store = getattr(app, "physical_spools", None)
    inventory = getattr(app, "filament_store", None)
    if store is None:
        return
    pl = _pl(app)
    location = location_for(serial, getattr(group, "external", False), group_index, slot_index)
    printer_name = next((p.name for p in app.printers if p.serial == serial), serial)
    slot_label = group.display_name if getattr(group, "external", False) else f"{group.display_name} {slot.label}"

    dialog = Gtk.Dialog(title=(i18n.t("Assign roll")),
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
            i18n.t("Assigned: <b>{0}</b> ({1})").format(
                assigned.get("id"), _filament_label(app, assigned.get("filamentDefinitionID"))))
        content.pack_start(info, False, False, 0)

        grams_row = Gtk.Box(spacing=8)
        grams_row.pack_start(Gtk.Label(label=(i18n.t("Remaining (g):")), xalign=0), False, False, 0)
        nominal = float(assigned.get("nominalWeightGrams", 1000) or 1000)
        spin = Gtk.SpinButton.new_with_range(0, max(nominal, 1), 5)
        spin.set_value(float(assigned.get("remainingWeightGrams", 0) or 0))
        grams_row.pack_start(spin, True, True, 0)
        save = Gtk.Button(label=(i18n.t("Save")))
        grams_row.pack_start(save, False, False, 0)
        content.pack_start(grams_row, False, False, 0)

        pct = Gtk.Label(xalign=0)
        pct.get_style_context().add_class("subtitle")
        pct.set_text(i18n.t("{0}% · {1} g nominal").format(percent, int(nominal)))
        content.pack_start(pct, False, False, 0)

        actions = Gtk.Box(spacing=6)
        weigh = Gtk.Button(label=(i18n.t("Weigh")))
        reset = Gtk.Button(label=(i18n.t("Reset")))
        detach = Gtk.Button(label=(i18n.t("Unassign")))
        for button in (weigh, reset, detach):
            actions.pack_start(button, True, True, 0)
        content.pack_start(actions, False, False, 0)

        def do_save(_b: Gtk.Button) -> None:
            store.set_remaining(assigned["id"], spin.get_value())
            _refresh(app, serial)
            dialog.destroy()

        def do_detach(_b: Gtk.Button) -> None:
            store.clear_slot(location)
            _refresh(app, serial)
            dialog.destroy()

        def do_weigh(_b: Gtk.Button) -> None:
            if _correct_weight(dialog, app, store, assigned):
                spin.set_value(float(assigned.get("remainingWeightGrams", 0) or 0))
                pct.set_text(
                    f"{store.percent(assigned)}% · {int(nominal)} g nominał" if pl
                    else f"{store.percent(assigned)}% · {int(nominal)} g nominal")
                _refresh(app, serial)

        def do_reset(_b: Gtk.Button) -> None:
            if not _confirm(
                    dialog,i18n.t("Reset roll?"),
                    i18n.t("{0} · set a full {1} g.").format(assigned.get("id"), int(nominal))):
                return
            store.reset_to_full(assigned["id"])
            spin.set_value(nominal)
            pct.set_text(i18n.t("100% · {0} g nominal").format(int(nominal)))
            _refresh(app, serial)

        save.connect("clicked", do_save)
        weigh.connect("clicked", do_weigh)
        reset.connect("clicked", do_reset)
        detach.connect("clicked", do_detach)
        content.pack_start(Gtk.Separator(), False, False, 4)

    # --- assign a new / existing roll ----------------------------------------
    picker_label = Gtk.Label(xalign=0)
    picker_label.set_text((i18n.t("Assign a roll:")))
    content.pack_start(picker_label, False, False, 0)

    combo = Gtk.ComboBoxText()
    combo.append("__new__", (i18n.t("New roll")))
    # Existing rolls that are in storage (or elsewhere) can be moved into this slot.
    available = [spool for spool in store.spools
                 if spool is not assigned and spool.get("status") != "archived"]
    available.sort(key=lambda spool: (
        not _matches_slot(app, spool, slot),
        (spool.get("location") or {}).get("printerSerial") is not None,
        str(spool.get("id", ""))))
    for spool in available:
        if spool is assigned:
            continue
        loc = spool.get("location") or {}
        where = _location_label(app, loc)
        match = "★ " if _matches_slot(app, spool, slot) else ""
        combo.append(f"spool:{spool.get('id')}",
                     f"{match}{spool.get('id')} · {_filament_label(app, spool.get('filamentDefinitionID'))} · "
                     f"{int(float(spool.get('remainingWeightGrams', 0) or 0))} g · {where}")
    # The user's Spoolbase inventory: creating a roll from a known filament links it for consumption.
    if inventory is not None:
        for f in inventory.filaments:
            combo.append(f"def:{f.id}", f"{f.brand} {f.name} · {f.colorName} ({f.type})")
    combo.set_active_id("__new__")
    content.pack_start(combo, False, False, 0)

    delete_row = Gtk.Box()
    delete_selected = Gtk.Button(label=(i18n.t("Delete selected roll")))
    delete_row.pack_end(delete_selected, False, False, 0)
    content.pack_start(delete_row, False, False, 0)

    nom_row = Gtk.Box(spacing=8)
    nom_row.pack_start(Gtk.Label(label=(i18n.t("Nominal (g):")), xalign=0), False, False, 0)
    nominal_spin = Gtk.SpinButton.new_with_range(100, 5000, 50)
    nominal_spin.set_value(1000)
    nom_row.pack_start(nominal_spin, True, True, 0)
    content.pack_start(nom_row, False, False, 0)

    presets = Gtk.Box(spacing=6)
    for grams in (1000, 750, 500):
        button = Gtk.Button(label=f"{grams} g")
        button.connect("clicked", lambda _button, value=grams: nominal_spin.set_value(value))
        presets.pack_start(button, True, True, 0)
    content.pack_start(presets, False, False, 0)

    dialog.add_button((i18n.t("Cancel")), Gtk.ResponseType.CANCEL)
    dialog.add_button((i18n.t("Assign")), Gtk.ResponseType.OK)

    def delete_choice(_button: Gtk.Button) -> None:
        choice = combo.get_active_id() or ""
        if not choice.startswith("spool:"):
            return
        spool_id = choice.split(":", 1)[1]
        if not _confirm(dialog,i18n.t("Delete roll?"), spool_id):
            return
        store.delete(spool_id)
        dialog.destroy()
        GLib.idle_add(lambda: (open_assign_dialog(app, serial, group, group_index, slot, slot_index), False)[1])

    delete_selected.connect("clicked", delete_choice)

    def on_response(_d: Gtk.Dialog, response: int) -> None:
        if response == Gtk.ResponseType.OK:
            choice = combo.get_active_id() or "__new__"
            if choice.startswith("spool:"):
                spool = store.spool(choice.split(":", 1)[1])
                if spool is not None:
                    old_location = spool.get("location") or {}
                    if old_location.get("printerSerial") is not None:
                        if not _confirm(
                                dialog,i18n.t("Move roll?"),
                                i18n.t("{0} is currently at {1}").format(
                                    spool.get("id"), _location_label(app, old_location))):
                            return
                    store.assign(spool["id"], location)
            elif choice.startswith("def:"):
                nominal = nominal_spin.get_value()
                store.create_spool(choice.split(":", 1)[1], nominal, nominal, location)
            else:
                nominal = nominal_spin.get_value()
                matched = None
                if inventory is not None:
                    matched = next((definition for definition in inventory.filaments
                                    if (definition.type or "").upper() == (getattr(slot, "material", "") or "").upper()
                                    and (not _normal_color(getattr(slot, "color", ""))
                                         or _normal_color(definition.colorHex) == _normal_color(getattr(slot, "color", "")))), None)
                store.create_spool(matched.id if matched is not None else None, nominal, nominal, location)
            _refresh(app, serial)
        dialog.destroy()

    dialog.connect("response", on_response)
    dialog.show_all()


def _refresh(app: Any, serial: str) -> None:
    try:
        app.rebuild_cards()
    except Exception:
        pass
