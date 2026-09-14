"""One auxiliary panel in a window of its own, centred on the screen, and the header every panel wears.

The panels used to be overlays inside the fleet window: a dimmed layer with the card floating in the
middle of it. That cost more than it bought. A panel could never be larger than its host, it dimmed
the cards the user had just come to read, and the fleet window had to be kept awake by hand so it did
not hide from under the thing it had opened.

Every panel window follows the `panelWindow` contract in design/gantry-card-layout.impl.json, the
same one macOS PanelWindowController and Windows PanelWindow follow: a header bar carrying the fleet
panel's own identity, GANTRY · name, at the leading edge, the panel's own controls at the trailing
edge, the system close button, and a window title of "Gantry · name". The panels no longer draw a
title or a close button of their own.
"""
from __future__ import annotations

from typing import Any, Callable, Iterable

from gi.repository import Gtk, Gdk  # type: ignore


def window_title(name: str) -> str:
    """ "Gantry · Spoolbase". A middle dot, as in the fleet header. """
    return f"Gantry · {name}"


def panel_header(window: Gtk.Window, name: str, accessories: Iterable[Gtk.Widget] = ()) -> Gtk.HeaderBar:
    """Installs the shared header on `window` and returns it.

    Works on a Gtk.Dialog as well as a Gtk.Window: a dialog keeps its own action buttons at the bottom
    and only its title bar is replaced.
    """
    header = Gtk.HeaderBar()
    header.set_show_close_button(True)
    # Leading, not the header bar's centred title: the wordmark sits where it sits in the fleet
    # header, and where macOS puts it beside the traffic lights. An empty custom title keeps GTK from
    # drawing the plain title text in the middle as well.
    header.set_custom_title(Gtk.Box())
    identity = Gtk.Box(spacing=7)
    wordmark = Gtk.Label(label="GANTRY")
    wordmark.get_style_context().add_class("panel-wordmark")
    dot = Gtk.Label(label="·")
    dot.get_style_context().add_class("panel-dot")
    title = Gtk.Label(label=name, xalign=0)
    title.set_ellipsize(3)  # Pango.EllipsizeMode.END, without importing Pango for one constant
    title.get_style_context().add_class("panel-name")
    for widget in (wordmark, dot, title):
        identity.pack_start(widget, False, False, 0)
    header.pack_start(identity)
    # pack_end fills from the right edge inwards, so reverse to keep the caller's left-to-right order.
    for widget in reversed(list(accessories)):
        header.pack_end(widget)
    header.show_all()
    window.set_titlebar(header)
    # After set_titlebar, not before: installing a header bar takes the window's title over, and a
    # title set earlier reads back empty (measured: None). The custom title keeps it from being drawn.
    header.set_title(window_title(name))
    window.set_title(window_title(name))
    return header


class PanelWindow(Gtk.Window):
    """A bordered, resizable window holding one panel widget, centred on the screen."""

    def __init__(self, app: Any, content: Gtk.Widget, name: str,
                 width: int = 470, height: int = 560,
                 cleanup: Callable[[], None] | None = None,
                 accessories: Iterable[Gtk.Widget] = ()) -> None:
        super().__init__()
        self.app = app
        self._cleanup = cleanup
        self.set_transient_for(app.window)
        # Centred on the screen, not on the parent: a panel centred on the fleet window opens on top
        # of the cards, which is the thing the overlay did wrong.
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_default_size(width, height)
        self.set_size_request(min(360, width), min(240, height))
        panel_header(self, name, accessories)
        # The panel drew its own centred card because it had a whole window's worth of dimmed space
        # around it. In a window of this size it is the content, so it fills it.
        content.set_halign(Gtk.Align.FILL)
        content.set_valign(Gtk.Align.FILL)
        content.set_size_request(-1, -1)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(content)
        self.add(scroll)
        self.connect("key-press-event", self._on_key)
        self.connect("destroy", self._on_destroy)
        # The fleet window stays on screen for as long as this one does.
        app.window.hold_fleet_panel(self)

    def _on_key(self, _widget: Gtk.Widget, event: Gdk.EventKey) -> bool:
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        return False

    def _on_destroy(self, *_args: object) -> None:
        cleanup, self._cleanup = self._cleanup, None
        if cleanup:
            cleanup()

    def present_centered(self) -> None:
        self.show_all()
        self.present()
